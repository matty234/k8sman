package argowf

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/matty234/k8sman/backend/internal/ttlcache"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/transport"

	"github.com/matty234/k8sman/backend/internal/svcproxy"
)

// argo-server is reached through the Kubernetes API server's service proxy
// with the active kube credentials (like internal/argoapi for Argo CD):
//
//	/api/v1/namespaces/<ns>/services/<scheme>:argo-server:2746/proxy/api/v1/...
//
// Auth modes (argo-server --auth-mode):
//
//   - server: argo-server uses its own service account; no token is needed.
//   - client: argo-server uses the caller's kube bearer token. The API server
//     strips the Authorization header once it has authenticated the proxy
//     request, so the token is sent as argo-server's `authorization` cookie,
//     which it accepts too. Exec-plugin and auth-provider credentials work
//     (the token is taken from client-go's transport); client certificates
//     carry no token, so client mode is unavailable with them.
//   - sso: needs an Argo SSO session; not supported.

const (
	defaultServerNs   = "argo"
	defaultServerName = "argo-server"
	helmServerLabel   = "app.kubernetes.io/part-of=argo-workflows,app.kubernetes.io/component=server"
	probeTimeout      = 5 * time.Second
	requestTimeout    = 60 * time.Second
	discoveryTTL      = 30 * time.Second
	failedTTL         = 10 * time.Second
)

// Auth modes we can use.
const (
	AuthServer = "server" // argo-server's own service account
	AuthClient = "client" // the user's kube bearer token
	AuthNone   = ""       // argo-server rejects us
)

// Server is a discovered argo-server Service.
type Server struct {
	Namespace string `json:"namespace"`
	Service   string `json:"service"`
	Port      int32  `json:"port"`
	Scheme    string `json:"scheme"`
	Version   string `json:"version,omitempty"`
}

// ProxyPath is the API server path that reaches p on argo-server.
func (s *Server) ProxyPath(p string) string {
	return fmt.Sprintf("/api/v1/namespaces/%s/services/%s:%s:%d/proxy%s", s.Namespace, s.Scheme, s.Service, s.Port, p)
}

// Status is the GET /api/argowf/status payload.
type Status struct {
	Context string `json:"context"`
	// CRD: the Workflow CRD is served, so Argo Workflows is on this
	// cluster. When it isn't, argo-server isn't looked for.
	CRD       bool    `json:"crd"`
	Found     bool    `json:"found"`
	Reachable bool    `json:"reachable"`
	Server    *Server `json:"server,omitempty"`
	// Auth is "server", "client" or "" (argo-server refused us).
	Auth string `json:"auth"`
	// Subject is who argo-server acts as (its service account in server
	// mode, the user in client mode), from /api/v1/userinfo.
	Subject string `json:"subject,omitempty"`
	// Available: argo-server-only actions (retry, memoized resubmit) work.
	Available bool   `json:"available"`
	Error     string `json:"error,omitempty"`
}

// requester performs one proxied request. Tests replace it.
type requester interface {
	do(ctx context.Context, method string, s *Server, p string, body []byte, token string) ([]byte, int, error)
}

type restRequester struct{ rc rest.Interface }

func (r restRequester) do(ctx context.Context, method string, s *Server, p string, body []byte, token string) ([]byte, int, error) {
	var header map[string]string
	if token != "" {
		// The value has a space, as the Argo UI's own cookie does; Go's
		// cookie parser (which argo-server uses) accepts it.
		header = map[string]string{"Cookie": "authorization=Bearer " + token}
	}
	raw, code, err := svcproxy.Do(ctx, r.rc, method, s.ProxyPath(p), nil, header, body)
	if err != nil {
		if svcproxy.TimedOut(ctx, err) {
			return nil, 504, statusErr(http.StatusGatewayTimeout, "argo-server did not answer in time")
		}
		return raw, svcproxy.StatusCode(code, err), upstreamErr(svcproxy.StatusCode(code, err), raw, err)
	}
	return raw, code, nil
}

// upstreamErr turns an argo-server ({"code","message"}) or API server
// (v1 Status) error body into a readable error.
func upstreamErr(code int, raw []byte, err error) error {
	var kube metav1.Status
	if json.Unmarshal(raw, &kube) == nil && kube.Kind == "Status" {
		return statusErr(code, "Kubernetes API: "+cmp.Or(kube.Message, string(kube.Reason)))
	}
	var argo struct {
		Message string `json:"message"`
		Error   string `json:"error"`
	}
	msg := ""
	if json.Unmarshal(raw, &argo) == nil {
		msg = cmp.Or(argo.Message, argo.Error)
	}
	if msg == "" {
		msg = svcproxy.PlainText(raw)
	}
	if msg == "" {
		if body, ok := svcproxy.UnexpectedResponse(err); ok {
			return upstreamErr(code, []byte(body), nil)
		}
		if err != nil {
			msg = err.Error()
		}
	}
	return statusErr(code, "argo-server: "+cmp.Or(msg, "request failed"))
}

// statusErr is a kube-style error, so the HTTP layer reports code.
func statusErr(code int, msg string) error {
	if code < 400 {
		code = http.StatusBadGateway
	}
	return &apierrors.StatusError{ErrStatus: metav1.Status{Status: metav1.StatusFailure, Code: int32(code), Message: msg}}
}

// env is what one call needs from the active kube context.
type env struct {
	context string
	typed   kubernetes.Interface
	req     requester
	// token returns the user's kube bearer token ("" when the credentials
	// carry none, e.g. client certificates).
	token func() (string, error)
}

// Env builds an env from a kube context's clients.
func newEnv(contextName string, typed kubernetes.Interface, cfg *rest.Config) env {
	return env{
		context: contextName,
		typed:   typed,
		req:     restRequester{rc: typed.CoreV1().RESTClient()},
		token:   func() (string, error) { return BearerToken(cfg) },
	}
}

// BearerToken returns the bearer token client-go would send with cfg:
// a static token or token file, or one from an exec plugin or auth
// provider. It is "" for client-certificate and basic auth.
func BearerToken(cfg *rest.Config) (string, error) {
	if cfg == nil {
		return "", nil
	}
	if cfg.BearerToken != "" && cfg.ExecProvider == nil && cfg.AuthProvider == nil {
		return cfg.BearerToken, nil
	}
	tc, err := cfg.TransportConfig()
	if err != nil {
		return "", err
	}
	var got string
	capture := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		got = r.Header.Get("Authorization")
		return &http.Response{StatusCode: http.StatusOK, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})
	rt, err := transport.HTTPWrappersForConfig(tc, capture)
	if err != nil {
		return "", err
	}
	req, _ := http.NewRequest(http.MethodGet, cmp.Or(cfg.Host, "https://localhost"), nil)
	resp, err := rt.RoundTrip(req)
	if err != nil {
		return "", err
	}
	_ = resp.Body.Close()
	if t, ok := strings.CutPrefix(got, "Bearer "); ok {
		return t, nil
	}
	return "", nil
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// ---- discovery ----------------------------------------------------------------

type discovery struct {
	status Status
	server *Server
	token  string // client mode only; never serialised
}

type discoverer struct {
	cache ttlcache.Cache[string, *discovery]
}

func newDiscoverer() *discoverer {
	return &discoverer{cache: ttlcache.Cache[string, *discovery]{OK: discoveryTTL, Fail: failedTTL, Timeout: 15 * time.Second}}
}

func (d *discoverer) get(ctx context.Context, e env, refresh bool) *discovery {
	c, err := d.cache.Get(ctx, e.context, refresh, func(ctx context.Context) (*discovery, bool) {
		c := discover(ctx, e)
		return c, c.status.Available
	})
	if err != nil {
		return &discovery{status: Status{Error: err.Error()}}
	}
	return c
}

// findService looks for argo-server: a Service named argo-server anywhere,
// then the Helm chart's labelled server Service, then argo/argo-server
// when listing all namespaces is forbidden.
func findService(ctx context.Context, typed kubernetes.Interface) (*corev1.Service, error) {
	var firstErr error
	pick := func(items []corev1.Service) *corev1.Service {
		for i := range items {
			if items[i].Namespace == defaultServerNs {
				return &items[i]
			}
		}
		if len(items) > 0 {
			return &items[0]
		}
		return nil
	}
	for _, opts := range []metav1.ListOptions{
		{FieldSelector: "metadata.name=" + defaultServerName},
		{LabelSelector: helmServerLabel},
	} {
		l, err := typed.CoreV1().Services("").List(ctx, opts)
		if err != nil {
			if firstErr == nil && !apierrors.IsForbidden(err) {
				firstErr = err
			}
			continue
		}
		if s := pick(l.Items); s != nil {
			return s, nil
		}
	}
	s, err := typed.CoreV1().Services(defaultServerNs).Get(ctx, defaultServerName, metav1.GetOptions{})
	if err == nil {
		return s, nil
	}
	return nil, firstErr
}

func pickPort(svc *corev1.Service) int32 {
	for _, p := range svc.Spec.Ports {
		if p.Port == 2746 || p.Name == "web" || p.Name == "http" || p.Name == "https" {
			return p.Port
		}
	}
	if len(svc.Spec.Ports) > 0 {
		return svc.Spec.Ports[0].Port
	}
	return 2746
}

func discover(ctx context.Context, e env) *discovery {
	d := &discovery{status: Status{Context: e.context}}
	svc, err := findService(ctx, e.typed)
	if svc == nil {
		msg := "argo-server was not found"
		if err != nil {
			msg += ": " + err.Error()
		}
		d.status.Error = msg
		return d
	}
	d.status.Found = true
	// argo-server serves TLS (self-signed) unless --secure=false; the API
	// server's proxy does not verify the certificate.
	// In client/SSO mode even /api/v1/version needs a token: argo-server's
	// own 401/403 (not the API server's) still proves it is there.
	var lastErr error
	for _, scheme := range []string{"https", "http"} {
		s := &Server{Namespace: svc.Namespace, Service: svc.Name, Port: pickPort(svc), Scheme: scheme}
		v, code, raw, err := version(ctx, e, s, "")
		if err != nil && !((code == 401 || code == 403) && !isKubeStatus(raw)) {
			lastErr = err
			continue
		}
		s.Version = v
		d.server, d.status.Server, d.status.Reachable = s, s, true
		break
	}
	if d.server == nil {
		d.status.Server = &Server{Namespace: svc.Namespace, Service: svc.Name, Port: pickPort(svc)}
		d.status.Error = fmt.Sprintf("argo-server is not reachable: %v", lastErr)
		return d
	}
	// Auth: no token first (server mode), then the user's token (client mode).
	if subj, err := userInfo(ctx, e, d.server, ""); err == nil {
		d.status.Auth, d.status.Subject, d.status.Available = AuthServer, subj, true
		return d
	}
	tok, terr := e.token()
	if terr != nil || tok == "" {
		d.status.Error = "argo-server needs a token (client or SSO auth mode) and the kube credentials carry none"
		if terr != nil {
			d.status.Error += ": " + terr.Error()
		}
		return d
	}
	subj, err := userInfo(ctx, e, d.server, tok)
	if err != nil {
		d.status.Error = "argo-server rejected the kube credentials (SSO-only auth mode?): " + err.Error()
		return d
	}
	d.status.Auth, d.status.Subject, d.status.Available = AuthClient, subj, true
	d.token = tok
	if d.server.Version == "" {
		d.server.Version, _, _, _ = version(ctx, e, d.server, tok)
	}
	return d
}

// version asks argo-server for its version, returning the status code and
// body too so callers can tell an auth refusal from an unreachable server.
func version(ctx context.Context, e env, s *Server, tok string) (string, int, []byte, error) {
	pctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	raw, code, err := e.req.do(pctx, "GET", s, "/api/v1/version", nil, tok)
	if err != nil {
		return "", code, raw, err
	}
	var v struct {
		Version string `json:"version"`
	}
	if json.Unmarshal(raw, &v) != nil || v.Version == "" {
		return "", code, raw, errors.New("argo-server answered /api/v1/version unexpectedly")
	}
	return v.Version, code, raw, nil
}

// isKubeStatus reports whether raw is a Kubernetes v1 Status (an error from
// the API server itself rather than from argo-server).
func isKubeStatus(raw []byte) bool {
	var st metav1.Status
	return json.Unmarshal(raw, &st) == nil && st.Kind == "Status"
}

func userInfo(ctx context.Context, e env, s *Server, tok string) (string, error) {
	pctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	raw, _, err := e.req.do(pctx, "GET", s, "/api/v1/userinfo", nil, tok)
	if err != nil {
		return "", err
	}
	var u struct {
		Subject string `json:"subject"`
		Email   string `json:"email"`
		Name    string `json:"name"`
	}
	_ = json.Unmarshal(raw, &u)
	return cmp.Or(u.Email, u.Subject, u.Name, "(anonymous)"), nil
}

// ---- operations ---------------------------------------------------------------

func (h *Handler) call(ctx context.Context, e env, method, p string, body any) ([]byte, error) {
	d := h.disc.get(ctx, e, false)
	if !d.status.Available {
		// Re-probe once: argo-server may have come up since.
		d = h.disc.get(ctx, e, true)
	}
	if !d.status.Available {
		return nil, apierrors.NewServiceUnavailable("this action needs argo-server, which is unavailable: " + cmp.Or(d.status.Error, "unknown error"))
	}
	b, _ := json.Marshal(body)
	rctx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()
	raw, _, err := e.req.do(rctx, method, d.server, p, b, d.token)
	return raw, err
}

// retry retries a failed workflow through argo-server
// (PUT /api/v1/workflows/{ns}/{name}/retry).
func (h *Handler) retry(ctx context.Context, e env, ns, name string, restartSuccessful bool) error {
	_, err := h.call(ctx, e, "PUT", fmt.Sprintf("/api/v1/workflows/%s/%s/retry", url.PathEscape(ns), url.PathEscape(name)),
		map[string]any{"name": name, "namespace": ns, "restartSuccessful": restartSuccessful})
	return err
}

// resubmitMemoized resubmits through argo-server with memoized=true (only
// for Failed/Error workflows), returning the new workflow's name.
func (h *Handler) resubmitMemoized(ctx context.Context, e env, ns, name string) (string, error) {
	raw, err := h.call(ctx, e, "PUT", fmt.Sprintf("/api/v1/workflows/%s/%s/resubmit", url.PathEscape(ns), url.PathEscape(name)),
		map[string]any{"name": name, "namespace": ns, "memoized": true})
	if err != nil {
		return "", err
	}
	var wf struct {
		Metadata struct {
			Name string `json:"name"`
		} `json:"metadata"`
	}
	_ = json.Unmarshal(raw, &wf)
	return wf.Metadata.Name, nil
}
