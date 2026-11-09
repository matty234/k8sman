package metrics

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/prom"
)

// Register adds the /api/metrics/* routes. Each request uses the active kube
// context's Service.
func Register(mux *http.ServeMux, mgr *cluster.Manager) {
	h := &handlers{
		svc:  func() *Service { return For(mgr.Clients()) },
		prom: func() PromQuery { return PromQueryFor(mgr.Clients()) },
	}
	h.register(mux)
}

// PromQueryFor runs instant queries against the cluster's Prometheus (found
// and cached by package prom); queries error when there is none.
func PromQueryFor(c *cluster.Clients) PromQuery {
	return func(ctx context.Context, q string) ([]PromSample, error) {
		res, _, err := prom.QueryVector(ctx, c, q)
		out := make([]PromSample, len(res))
		for i, r := range res {
			out[i] = PromSample{Metric: r.Metric, Value: r.Value}
		}
		return out, err
	}
}

type handlers struct {
	svc  func() *Service
	prom func() PromQuery
}

func (h *handlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/metrics/status", h.status)
	mux.HandleFunc("GET /api/metrics/nodes", h.nodes)
	mux.HandleFunc("GET /api/metrics/pods", h.pods)
	mux.HandleFunc("GET /api/metrics/hpa", h.hpa)
	mux.HandleFunc("GET /api/metrics/summary", h.summary)
	mux.HandleFunc("GET /api/metrics/volumes", h.volumes)
}

type apiError struct {
	Error string `json:"error"`
	Code  int    `json:"code"`
	// State is set when a metrics API is unusable: notInstalled or notReady.
	State string `json:"state,omitempty"`
	Group string `json:"group,omitempty"`
}

func writeErr(w http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	body := apiError{Error: err.Error()}
	var ue *UnavailableError
	switch {
	case errors.As(err, &ue):
		body.State, body.Group = ue.Status.State, ue.Status.Group
		status = http.StatusServiceUnavailable
		if ue.Status.State == StateNotInstalled {
			status = http.StatusNotFound
		}
	case errors.Is(err, httpx.ErrBadRequest):
		status = http.StatusBadRequest
	default:
		status, _, _ = httpx.KubeStatus(err, status)
	}
	body.Code = status
	httpx.WriteJSON(w, status, body)
}

func (h *handlers) status(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, 200, h.svc().Status(r.Context(), r.URL.Query().Get("refresh") == "true"))
}

func (h *handlers) nodes(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc().Nodes(r.Context())
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"items": items})
}

func (h *handlers) pods(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	scope, err := kube.ParseNamespaces(q)
	if err != nil {
		writeErr(w, errors.Join(httpx.ErrBadRequest, err))
		return
	}
	var items []PodUsage
	if len(scope) > 1 {
		items, err = h.podsIn(r.Context(), scope, q.Get("labelSelector"))
	} else {
		items, err = h.svc().PodsSelected(r.Context(), scope.Single(), q.Get("labelSelector"))
	}
	if err != nil {
		writeErr(w, err)
		return
	}
	if items == nil {
		items = []PodUsage{}
	}
	httpx.WriteJSON(w, 200, map[string]any{"items": items})
}

// podsIn reads a namespace set namespace by namespace (works with RBAC
// limited to those namespaces). Namespaces that fail are left out unless
// all of them fail.
func (h *handlers) podsIn(ctx context.Context, scope kube.Namespaces, labelSelector string) ([]PodUsage, error) {
	var (
		out      []PodUsage
		firstErr error
		ok       bool
	)
	for _, ns := range scope {
		items, err := h.svc().PodsSelected(ctx, ns, labelSelector)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		ok = true
		out = append(out, items...)
	}
	if !ok {
		return nil, firstErr
	}
	return out, nil
}

func (h *handlers) hpa(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("namespace") == "" || q.Get("name") == "" {
		writeErr(w, errors.Join(httpx.ErrBadRequest, errors.New("namespace and name are required")))
		return
	}
	a, err := h.svc().AnalyzeHPA(r.Context(), q.Get("namespace"), q.Get("name"))
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, a)
}

// summary serves kubelet Summary API data: PVC usage and network rates for
// the given nodes (repeated or comma-separated `node`; all when absent).
// Always 200: an unusable source is reported in the body's state.
func (h *handlers) summary(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var nodes []string
	for _, v := range q["node"] {
		for _, n := range strings.Split(v, ",") {
			if n = strings.TrimSpace(n); n != "" {
				nodes = append(nodes, n)
			}
		}
	}
	scope, err := kube.ParseNamespaces(q)
	if err != nil {
		writeErr(w, errors.Join(httpx.ErrBadRequest, err))
		return
	}
	httpx.WriteJSON(w, 200, h.svc().Summary(r.Context(), scope.String(), nodes))
}

// volumes serves per-claim usage merged from Prometheus and the kubelets.
func (h *handlers) volumes(w http.ResponseWriter, r *http.Request) {
	var q PromQuery
	if h.prom != nil {
		q = h.prom()
	}
	scope, err := kube.ParseNamespaces(r.URL.Query())
	if err != nil {
		writeErr(w, errors.Join(httpx.ErrBadRequest, err))
		return
	}
	httpx.WriteJSON(w, 200, h.svc().Volumes(r.Context(), scope.String(), q))
}
