package server

import (
	"context"
	"encoding/json"
	"maps"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"sync"

	authzv1 "k8s.io/api/authorization/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Namespaces the user added by hand, per kube context, for clusters where
// Namespaces can't be listed. Local settings only, so they work in
// read-only mode.
func (s *Server) namespaceRoutes() {
	s.mux.HandleFunc("GET /api/settings/namespaces", s.handleGetNamespaces)
	s.mux.HandleFunc("PUT /api/settings/namespaces", s.handlePutNamespaces)
	s.mux.HandleFunc("GET /api/settings/favourite-namespaces", s.handleGetFavouriteNamespaces)
	s.mux.HandleFunc("PUT /api/settings/favourite-namespaces", s.handlePutFavouriteNamespaces)
	s.mux.HandleFunc("GET /api/settings/allowed-namespaces", s.handleGetAllowedNamespaces)
	s.mux.HandleFunc("PUT /api/settings/allowed-namespaces", s.handlePutAllowedNamespaces)
	s.mux.HandleFunc("GET /api/settings/allowed-namespaces/suggest", s.handleSuggestAllowedNamespaces)
	s.mux.HandleFunc("GET /api/settings/default-namespace", s.handleGetDefaultNamespace)
	s.mux.HandleFunc("PUT /api/settings/default-namespace", s.handlePutDefaultNamespace)
}

var dns1123Label = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)

const maxRememberedNamespaces = 200

// handleGetNamespaces returns {context, namespaces}. ?context= defaults to
// the current context.
func (s *Server) handleGetNamespaces(w http.ResponseWriter, r *http.Request) {
	s.getNamespaceList(w, r, func(st settings.Settings) map[string][]string { return st.Namespaces })
}

// handleGetFavouriteNamespaces is the same for starred namespaces.
func (s *Server) handleGetFavouriteNamespaces(w http.ResponseWriter, r *http.Request) {
	s.getNamespaceList(w, r, func(st settings.Settings) map[string][]string { return st.FavouriteNamespaces })
}

func (s *Server) getNamespaceList(w http.ResponseWriter, r *http.Request, pick func(settings.Settings) map[string][]string) {
	ctx := s.settingsContext(r)
	list := []string{}
	if s.settings != nil {
		list = append(list, pick(s.settings.Get())[ctx]...)
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"context": ctx, "namespaces": list})
}

// handlePutNamespaces replaces a context's list.
// Body: {"context"?: "<name>", "namespaces": ["a", "b"]}.
func (s *Server) handlePutNamespaces(w http.ResponseWriter, r *http.Request) {
	s.putNamespaceList(w, r, func(c string, l []string) error { return s.settings.SetNamespaces(c, l) })
}

// handlePutFavouriteNamespaces replaces a context's starred namespaces; same body.
func (s *Server) handlePutFavouriteNamespaces(w http.ResponseWriter, r *http.Request) {
	s.putNamespaceList(w, r, func(c string, l []string) error { return s.settings.SetFavouriteNamespaces(c, l) })
}

func (s *Server) putNamespaceList(w http.ResponseWriter, r *http.Request, save func(string, []string) error) {
	var body struct {
		Context    string   `json:"context"`
		Namespaces []string `json:"namespaces"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("body must be {context?, namespaces}"))
		return
	}
	s.saveNamespaceSetting(w, r, body.Context, body.Namespaces, func(ctx string) error { return save(ctx, body.Namespaces) })
}

// saveNamespaceSetting checks names and the context, then saves.
func (s *Server) saveNamespaceSetting(w http.ResponseWriter, r *http.Request, context string, names []string, save func(ctx string) error) {
	bad := func(msg string) {
		httpx.WriteJSON(w, http.StatusBadRequest, apiError{Error: msg, Code: http.StatusBadRequest})
	}
	if len(names) > maxRememberedNamespaces {
		bad("too many namespaces")
		return
	}
	for _, n := range names {
		if len(n) > 63 || !dns1123Label.MatchString(n) {
			bad("not a namespace name: " + n)
			return
		}
	}
	ctx := context
	if ctx == "" {
		ctx = s.settingsContext(r)
	}
	if ctx == "" {
		bad("no context")
		return
	}
	if s.settings == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, apiError{Error: "settings are not available", Code: http.StatusServiceUnavailable})
		return
	}
	if err := save(ctx); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- allowlist and default namespace ----------------------------------------

// handleGetAllowedNamespaces returns {context, namespaces}: the only
// namespaces the context shows (empty = every namespace).
func (s *Server) handleGetAllowedNamespaces(w http.ResponseWriter, r *http.Request) {
	s.getNamespaceList(w, r, func(st settings.Settings) map[string][]string { return st.AllowedNamespaces })
}

// handlePutAllowedNamespaces replaces a context's allowlist; same body as
// /api/settings/namespaces. An empty list removes the restriction.
func (s *Server) handlePutAllowedNamespaces(w http.ResponseWriter, r *http.Request) {
	s.putNamespaceList(w, r, func(c string, l []string) error {
		return s.settings.SetAllowedNamespaces(c, kube.SplitNamespaces(strings.Join(l, ",")))
	})
}

// allowedNamespaces is the current context's allowlist (nil = every
// namespace), sorted.
func (s *Server) allowedNamespaces() kube.Namespaces {
	if s.settings == nil || s.mgr == nil {
		return nil
	}
	c := s.mgr.Clients()
	if c == nil {
		return nil
	}
	return kube.SplitNamespaces(strings.Join(s.settings.AllowedNamespaces(c.Context), ","))
}

// parseScope is kube.ParseNamespaces with "all namespaces" narrowed to the
// context's allowlist when it has one, so pages fan out over the allowed
// namespaces instead of listing cluster-wide (which a tenant may not do).
func (s *Server) parseScope(q url.Values) (kube.Namespaces, error) {
	scope, err := kube.ParseNamespaces(q)
	if err != nil || !scope.All() {
		return scope, err
	}
	return s.allowedNamespaces(), nil
}

// handleGetDefaultNamespace returns {context, mode, namespaces}: where the
// context opens. mode is "all" (the default), "kubeconfig" or "namespaces".
func (s *Server) handleGetDefaultNamespace(w http.ResponseWriter, r *http.Request) {
	ctx := s.settingsContext(r)
	var d settings.DefaultNamespace
	if s.settings != nil {
		d = s.settings.Get().DefaultNamespace[ctx]
	}
	mode := "all"
	switch {
	case d.FromKubeconfig:
		mode = "kubeconfig"
	case len(d.Namespaces) > 0:
		mode = "namespaces"
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"context": ctx, "mode": mode, "namespaces": append([]string{}, d.Namespaces...)})
}

// handlePutDefaultNamespace saves where a context opens.
// Body: {"context"?: "<name>", "mode": "all"|"kubeconfig"|"namespaces", "namespaces"?: [...]}.
func (s *Server) handlePutDefaultNamespace(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Context    string   `json:"context"`
		Mode       string   `json:"mode"`
		Namespaces []string `json:"namespaces"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("body must be {context?, mode, namespaces?}"))
		return
	}
	var d *settings.DefaultNamespace
	switch body.Mode {
	case "", "all":
		body.Namespaces = nil
	case "kubeconfig":
		body.Namespaces = nil
		d = &settings.DefaultNamespace{FromKubeconfig: true}
	case "namespaces":
		if len(body.Namespaces) == 0 {
			writeErr(w, httpx.BadRequest("mode namespaces needs namespaces"))
			return
		}
		d = &settings.DefaultNamespace{Namespaces: kube.SplitNamespaces(strings.Join(body.Namespaces, ","))}
	default:
		writeErr(w, httpx.BadRequest("mode must be all, kubeconfig or namespaces"))
		return
	}
	s.saveNamespaceSetting(w, r, body.Context, body.Namespaces, func(ctx string) error { return s.settings.SetDefaultNamespace(ctx, d) })
}

// maxSuggestChecks caps the access reviews one suggestion runs.
const maxSuggestChecks = 500

// handleSuggestAllowedNamespaces returns {namespaces, checked}: of the
// namespaces k8sman knows for the current context (the cluster's list when
// it may be read, plus the ones added by hand, starred, allowed and the
// kubeconfig's), those where the current credentials may list pods, asked
// with SelfSubjectAccessReview. Reads only; nothing is saved.
func (s *Server) handleSuggestAllowedNamespaces(w http.ResponseWriter, r *http.Request) {
	c := s.mgr.Clients()
	ctx, cancel := context.WithTimeout(r.Context(), namespacesTimeout)
	defer cancel()
	known := map[string]bool{}
	if c.Namespace != "" {
		known[c.Namespace] = true
	}
	if s.settings != nil {
		st := s.settings.Get()
		for _, l := range [][]string{st.Namespaces[c.Context], st.FavouriteNamespaces[c.Context], st.AllowedNamespaces[c.Context]} {
			for _, n := range l {
				known[n] = true
			}
		}
	}
	listed := false
	if list, err := c.Typed.CoreV1().Namespaces().List(ctx, metav1.ListOptions{}); err == nil {
		listed = true
		for _, n := range list.Items {
			known[n.Name] = true
		}
	}
	names := slices.Sorted(maps.Keys(known))
	if len(names) > maxSuggestChecks {
		names = names[:maxSuggestChecks]
	}
	ok := make([]bool, len(names))
	errs := make([]error, len(names))
	sem := make(chan struct{}, 8)
	var wg sync.WaitGroup
	for i, ns := range names {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			res, err := c.Typed.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx, &authzv1.SelfSubjectAccessReview{
				Spec: authzv1.SelfSubjectAccessReviewSpec{ResourceAttributes: &authzv1.ResourceAttributes{Namespace: ns, Verb: "list", Resource: "pods"}},
			}, metav1.CreateOptions{})
			if err != nil {
				errs[i] = err
				return
			}
			ok[i] = res.Status.Allowed
		}()
	}
	wg.Wait()
	out := []string{}
	for i, ns := range names {
		if ok[i] {
			out = append(out, ns)
		}
	}
	if len(out) == 0 {
		for _, err := range errs {
			if err != nil {
				writeErr(w, err)
				return
			}
		}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"namespaces": out, "checked": len(names), "listed": listed})
}
