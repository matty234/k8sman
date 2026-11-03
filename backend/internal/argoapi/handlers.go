package argoapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Auth states.
const (
	AuthNone       = "none"
	AuthConfigured = "configured" // a token saved in settings
	AuthSession    = "session"    // an in-memory session from the initial admin password
)

// tokenStore is where the per-context token is persisted. *settings.Store
// implements it.
type tokenStore interface {
	ArgoCDToken(context string) string
	SetArgoCDToken(context, token string) error
	ArgoCDUseCLI(context string) bool
	SetArgoCDUseCLI(context string, on bool) error
}

// Handler serves /api/argocd/*.
type Handler struct {
	env    func() env
	disc   *discoverer
	tokens tokenStore
	// cliPath locates the argocd CLI config (overridable in tests).
	cliPath func() string

	mu sync.Mutex
	// sessions holds session tokens from the initial-admin flow, per kube
	// context. Memory only: never written to disk.
	sessions map[string]string
}

// Register mounts the endpoints. None of them writes to the cluster: the
// diff is a read, and auth only touches local settings (or memory), so
// they are all allowed in --read-only mode.
func Register(mux *http.ServeMux, mgr *cluster.Manager, st *settings.Store) *Handler {
	h := &Handler{
		env: func() env {
			c := mgr.Clients()
			return env{context: c.Context, typed: c.Typed, req: restRequester{rc: c.Typed.CoreV1().RESTClient()}}
		},
		disc:     newDiscoverer(),
		tokens:   st,
		cliPath:  cliConfigPath,
		sessions: map[string]string{},
	}
	h.register(mux)
	return h
}

func (h *Handler) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/argocd/status", h.handleStatus)
	mux.HandleFunc("POST /api/argocd/auth", h.handleSetToken)
	mux.HandleFunc("DELETE /api/argocd/auth", h.handleClearToken)
	mux.HandleFunc("POST /api/argocd/auth/initial-admin", h.handleInitialAdmin)
	mux.HandleFunc("POST /api/argocd/auth/cli", h.handleUseCLI)
	mux.HandleFunc("GET /api/argocd/diff", h.handleDiff)
}

// token returns the token to use for a context: the session from the
// initial-admin flow if there is one, else the configured token, else the
// argocd CLI's login when the user chose that (read fresh from the CLI
// config, matched strictly to this cluster's Argo CD URL).
func (h *Handler) token(ctx context.Context, e env, srv *Server) (string, string) {
	contextName := e.context
	h.mu.Lock()
	s := h.sessions[contextName]
	h.mu.Unlock()
	if s != "" {
		return s, AuthSession
	}
	if t := h.tokens.ArgoCDToken(contextName); t != "" {
		return t, AuthConfigured
	}
	if h.tokens.ArgoCDUseCLI(contextName) {
		if l, ok := h.cliLoginFor(ctx, e, srv); ok {
			return l.token, AuthCLI
		}
		return "", AuthCLI
	}
	return "", AuthNone
}

func (h *Handler) setSession(contextName, tok string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if tok == "" {
		delete(h.sessions, contextName)
	} else {
		h.sessions[contextName] = tok
	}
}

// Status is the GET /api/argocd/status payload.
type Status struct {
	Context string `json:"context"`
	// Found: an argocd-server Service exists.
	Found     bool    `json:"found"`
	Reachable bool    `json:"reachable"`
	Server    *Server `json:"server,omitempty"`
	// Auth is none, configured or session.
	Auth string `json:"auth"`
	// AuthValid is whether Argo accepted the token (absent when unknown).
	AuthValid *bool  `json:"authValid,omitempty"`
	Username  string `json:"username,omitempty"`
	// InitialAdminAvailable: argocd-initial-admin-secret exists and kube
	// RBAC lets us read it, so the initial-admin flow can be offered.
	InitialAdminAvailable bool `json:"initialAdminAvailable"`
	// ArgoURL is the host from argocd-cm `url` (for the CLI login command).
	ArgoURL string `json:"argoUrl,omitempty"`
	// CLILogin: the argocd CLI config has a login for ArgoURL (its CLI
	// context name), so "Use argocd CLI login" can be offered.
	CLILogin string `json:"cliLogin,omitempty"`
	Error    string `json:"error,omitempty"`
}

// userInfo checks a token with GET /api/v1/session/userinfo.
func userInfo(ctx context.Context, e env, s *Server, tok string) (bool, string, error) {
	raw, err := e.req.do(ctx, "GET", s, "/api/v1/session/userinfo", nil, nil, tok)
	if err != nil {
		return false, "", err
	}
	var u struct {
		LoggedIn bool   `json:"loggedIn"`
		Username string `json:"username"`
	}
	if err := json.Unmarshal(raw, &u); err != nil {
		return false, "", &Error{Status: 502, Reason: ReasonUnreachable, Message: "Argo CD: unexpected userinfo response"}
	}
	return u.LoggedIn, u.Username, nil
}

func (h *Handler) status(ctx context.Context, e env, appNs string, refresh bool) Status {
	d := h.disc.get(ctx, e, appNs, refresh)
	tok, auth := h.token(ctx, e, d.server)
	st := Status{
		Context: e.context, Found: d.server != nil, Reachable: d.reachable, Server: d.server,
		Auth: auth, InitialAdminAvailable: d.initialAdmin, Error: d.err,
	}
	if d.server != nil {
		st.ArgoURL = argoURLHost(ctx, e, d.server)
		if l, ok := findCLILogin(h.cliFile(), st.ArgoURL); ok {
			st.CLILogin = l.Context
		}
		if auth == AuthCLI && tok == "" {
			st.Error = "No argocd CLI login for " + firstNonEmpty(st.ArgoURL, "this Argo CD") + ". Run: argocd login " + firstNonEmpty(st.ArgoURL, "<server>") + " --sso --grpc-web"
		}
	}
	if d.reachable && tok != "" {
		cctx, cancel := context.WithTimeout(ctx, probeTimeout)
		defer cancel()
		ok, user, err := userInfo(cctx, e, d.server, tok)
		if err == nil || isArgoAuthErr(err) {
			st.AuthValid = &ok
			st.Username = user
			if !ok {
				st.Error = "Argo CD rejected the " + authNoun(auth)
				if auth == AuthSession {
					h.setSession(e.context, "")
				}
			}
		} else {
			st.Error = err.Error()
		}
	}
	return st
}

func authNoun(auth string) string {
	if auth == AuthSession {
		return "session (it may have expired)"
	}
	if auth == AuthCLI {
		return "argocd CLI login (it may have expired; run argocd login again)"
	}
	return "token (it may be expired or revoked)"
}

func isArgoAuthErr(err error) bool {
	var ae *Error
	return errors.As(err, &ae) && ae.Status == 401 && !ae.Kube
}

func (h *Handler) handleStatus(w http.ResponseWriter, r *http.Request) {
	e := h.env()
	httpx.WriteJSON(w, http.StatusOK, h.status(r.Context(), e, r.URL.Query().Get("namespace"), r.URL.Query().Get("refresh") != ""))
}

// cleanToken trims whitespace and a pasted "Bearer " prefix.
func cleanToken(t string) string {
	t = strings.TrimSpace(t)
	if len(t) > 7 && strings.EqualFold(t[:7], "bearer ") {
		t = strings.TrimSpace(t[7:])
	}
	return t
}

func (h *Handler) handleSetToken(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Context   string `json:"context"`
		Token     string `json:"token"`
		Namespace string `json:"namespace"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, &Error{Status: 400, Message: "invalid JSON body"})
		return
	}
	tok := cleanToken(body.Token)
	if tok == "" {
		writeErr(w, &Error{Status: 400, Message: "token is required"})
		return
	}
	e := h.env()
	ctxName := firstNonEmpty(body.Context, e.context)
	// Check the token first when it is for the current context and Argo is
	// reachable; a rejected token isn't saved.
	if ctxName == e.context {
		if d := h.disc.get(r.Context(), e, body.Namespace, false); d.reachable {
			ok, _, err := userInfo(r.Context(), e, d.server, tok)
			if (err == nil && !ok) || isArgoAuthErr(err) {
				writeErr(w, &Error{Status: 401, Reason: ReasonUnauthorized, Message: "Argo CD rejected the token, so it wasn't saved"})
				return
			}
		}
	}
	if err := h.tokens.SetArgoCDToken(ctxName, tok); err != nil {
		writeErr(w, &Error{Status: 500, Message: "save settings: " + err.Error()})
		return
	}
	// The newest explicit choice wins: drop any session for this context.
	h.setSession(ctxName, "")
	httpx.WriteJSON(w, http.StatusOK, h.status(r.Context(), e, body.Namespace, false))
}

func (h *Handler) handleClearToken(w http.ResponseWriter, r *http.Request) {
	e := h.env()
	ctxName := firstNonEmpty(r.URL.Query().Get("context"), e.context)
	h.setSession(ctxName, "")
	if err := h.tokens.SetArgoCDUseCLI(ctxName, false); err != nil {
		writeErr(w, &Error{Status: 500, Message: "save settings: " + err.Error()})
		return
	}
	if err := h.tokens.SetArgoCDToken(ctxName, ""); err != nil {
		writeErr(w, &Error{Status: 500, Message: "save settings: " + err.Error()})
		return
	}
	httpx.WriteJSON(w, http.StatusOK, h.status(r.Context(), e, r.URL.Query().Get("namespace"), false))
}

// handleInitialAdmin logs in as admin with the password from
// argocd-initial-admin-secret (the user opted in from the UI) and keeps the
// session token in memory. The password is never stored or returned.
func (h *Handler) handleInitialAdmin(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Namespace string `json:"namespace"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	e := h.env()
	d := h.disc.get(r.Context(), e, body.Namespace, false)
	if d.server == nil {
		writeErr(w, &Error{Status: 404, Reason: ReasonNotFound, Message: d.err})
		return
	}
	if !d.reachable {
		writeErr(w, &Error{Status: 502, Reason: ReasonUnreachable, Message: firstNonEmpty(d.err, "argocd-server is not reachable")})
		return
	}
	sec, err := e.typed.CoreV1().Secrets(d.server.Namespace).Get(r.Context(), initialAdminName, metav1.GetOptions{})
	if err != nil {
		switch {
		case apierrors.IsNotFound(err):
			writeErr(w, &Error{Status: 404, Reason: ReasonNoAdmin, Message: d.server.Namespace + "/" + initialAdminName + " doesn't exist (it is usually deleted after setup)"})
		case apierrors.IsForbidden(err):
			writeErr(w, &Error{Status: 403, Reason: ReasonNoAdmin, Message: "your kube RBAC can't read " + d.server.Namespace + "/" + initialAdminName})
		default:
			writeErr(w, err)
		}
		return
	}
	password := string(sec.Data["password"])
	if password == "" {
		writeErr(w, &Error{Status: 404, Reason: ReasonNoAdmin, Message: initialAdminName + " has no password"})
		return
	}
	req, _ := json.Marshal(map[string]string{"username": "admin", "password": password})
	ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
	defer cancel()
	raw, err := e.req.do(ctx, "POST", d.server, "/api/v1/session", nil, req, "")
	if err != nil {
		if isArgoAuthErr(err) {
			err = &Error{Status: 401, Reason: ReasonUnauthorized, Message: "Argo CD refused the initial admin password (it was probably changed)"}
		}
		writeErr(w, err)
		return
	}
	var sess struct {
		Token string `json:"token"`
	}
	if json.Unmarshal(raw, &sess) != nil || sess.Token == "" {
		writeErr(w, &Error{Status: 502, Message: "Argo CD: no token in the session response"})
		return
	}
	h.setSession(e.context, sess.Token)
	httpx.WriteJSON(w, http.StatusOK, h.status(r.Context(), e, body.Namespace, false))
}

func (h *Handler) handleDiff(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	name, appNs := q.Get("name"), q.Get("namespace")
	if name == "" {
		writeErr(w, &Error{Status: 400, Message: "name is required"})
		return
	}
	e := h.env()
	d := h.disc.get(r.Context(), e, appNs, false)
	if d.server == nil {
		writeErr(w, &Error{Status: 404, Reason: ReasonNotFound, Message: d.err})
		return
	}
	if !d.reachable {
		// Maybe it came back: rediscover once.
		if d = h.disc.get(r.Context(), e, appNs, true); !d.reachable {
			writeErr(w, &Error{Status: 502, Reason: ReasonUnreachable, Message: firstNonEmpty(d.err, "argocd-server is not reachable")})
			return
		}
	}
	tok, auth := h.token(r.Context(), e, d.server)
	if tok == "" {
		writeErr(w, &Error{Status: 401, Reason: ReasonNoToken, Message: "Connect to the Argo CD API to see diffs"})
		return
	}
	query := url.Values{}
	if appNs != "" {
		query.Set("appNamespace", appNs)
	}
	ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
	defer cancel()
	raw, err := e.req.do(ctx, "GET", d.server, "/api/v1/applications/"+url.PathEscape(name)+"/managed-resources", query, nil, tok)
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) && !ae.Kube {
			switch ae.Status {
			case 401:
				if auth == AuthSession {
					h.setSession(e.context, "")
				}
				err = &Error{Status: 401, Reason: ReasonUnauthorized, Message: "Argo CD rejected the " + authNoun(auth)}
			case 403:
				err = &Error{Status: 403, Reason: ReasonForbidden, Message: "Argo CD denied access to " + name + ": " + strings.TrimPrefix(ae.Message, "Argo CD: ") + " (Argo RBAC needs applications, get)"}
			}
		}
		writeErr(w, err)
		return
	}
	var mr struct {
		Items []managedResource `json:"items"`
	}
	if err := json.Unmarshal(raw, &mr); err != nil {
		writeErr(w, &Error{Status: 502, Message: "Argo CD: decode managed resources: " + err.Error()})
		return
	}
	httpx.WriteJSON(w, http.StatusOK, DiffResponse{Resources: convert(mr.Items), Server: d.server, Auth: auth})
}

// ---- helpers -----------------------------------------------------------------

type apiError struct {
	Error  string `json:"error"`
	Code   int    `json:"code"`
	Reason string `json:"reason,omitempty"`
}

func writeErr(w http.ResponseWriter, err error) {
	status, reason := http.StatusBadGateway, ""
	var ae *Error
	if errors.As(err, &ae) {
		if ae.Status >= 400 {
			status = ae.Status
		}
		reason = ae.Reason
	} else {
		status, reason, _ = httpx.KubeStatus(err, status)
	}
	httpx.WriteJSON(w, status, apiError{Error: err.Error(), Code: status, Reason: reason})
}

// handleUseCLI switches a context to the argocd CLI's login. It requires a
// CLI login for this cluster's Argo CD URL and checks that Argo accepts it.
// Only the choice is saved; the token stays in the CLI's config.
func (h *Handler) handleUseCLI(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Namespace string `json:"namespace"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	e := h.env()
	d := h.disc.get(r.Context(), e, body.Namespace, false)
	if d.server == nil {
		writeErr(w, &Error{Status: 404, Reason: ReasonNotFound, Message: firstNonEmpty(d.err, "argocd-server not found")})
		return
	}
	host := argoURLHost(r.Context(), e, d.server)
	l, ok := findCLILogin(h.cliFile(), host)
	if !ok {
		msg := "No argocd CLI login found"
		if host != "" {
			msg += " for " + host + ". Run: argocd login " + host + " --sso --grpc-web"
		} else {
			msg += ": this Argo CD has no url in argocd-cm, so the CLI login can't be matched safely"
		}
		writeErr(w, &Error{Status: 404, Reason: ReasonNoToken, Message: msg})
		return
	}
	if d.reachable {
		okUser, _, err := userInfo(r.Context(), e, d.server, l.token)
		if (err == nil && !okUser) || isArgoAuthErr(err) {
			writeErr(w, &Error{Status: 401, Reason: ReasonUnauthorized, Message: "Argo CD rejected the argocd CLI login (expired?). Run: argocd login " + host + " --sso --grpc-web"})
			return
		}
	}
	// The newest explicit choice wins.
	h.setSession(e.context, "")
	if err := h.tokens.SetArgoCDToken(e.context, ""); err != nil {
		writeErr(w, &Error{Status: 500, Message: "save settings: " + err.Error()})
		return
	}
	if err := h.tokens.SetArgoCDUseCLI(e.context, true); err != nil {
		writeErr(w, &Error{Status: 500, Message: "save settings: " + err.Error()})
		return
	}
	httpx.WriteJSON(w, http.StatusOK, h.status(r.Context(), e, body.Namespace, false))
}
