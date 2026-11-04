package metrics

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
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
	mux.HandleFunc("GET /api/metrics/custom/discover", h.customDiscover)
	mux.HandleFunc("GET /api/metrics/custom", h.custom)
	mux.HandleFunc("GET /api/metrics/external/discover", h.externalDiscover)
	mux.HandleFunc("GET /api/metrics/external", h.external)
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
	items, err := h.svc().PodsSelected(r.Context(), q.Get("namespace"), q.Get("labelSelector"))
	if err != nil {
		writeErr(w, err)
		return
	}
	if items == nil {
		items = []PodUsage{}
	}
	httpx.WriteJSON(w, 200, map[string]any{"items": items})
}

func (h *handlers) customDiscover(w http.ResponseWriter, r *http.Request) {
	d, err := h.svc().DiscoverCustom(r.Context())
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, d)
}

func (h *handlers) custom(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	cq := CustomQuery{
		Group:          q.Get("group"),
		Resource:       q.Get("resource"),
		Namespace:      q.Get("namespace"),
		Name:           q.Get("name"),
		Selector:       q.Get("selector"),
		Metric:         q.Get("metric"),
		MetricSelector: q.Get("metricSelector"),
	}
	if cq.Resource == "" || cq.Metric == "" {
		writeErr(w, errors.Join(httpx.ErrBadRequest, errors.New("resource and metric are required")))
		return
	}
	items, err := h.svc().Custom(r.Context(), cq)
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"items": items})
}

func (h *handlers) externalDiscover(w http.ResponseWriter, r *http.Request) {
	d, err := h.svc().DiscoverExternal(r.Context(), r.URL.Query().Get("namespace"))
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, d)
}

func (h *handlers) external(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	eq := ExternalQuery{Namespace: q.Get("namespace"), Metric: q.Get("metric"), Selector: q.Get("labelSelector")}
	if eq.Namespace == "" || eq.Metric == "" {
		writeErr(w, errors.Join(httpx.ErrBadRequest, errors.New("namespace and metric are required")))
		return
	}
	items, err := h.svc().External(r.Context(), eq)
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"items": items})
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
	httpx.WriteJSON(w, 200, h.svc().Summary(r.Context(), q.Get("namespace"), nodes))
}

// volumes serves per-claim usage merged from Prometheus and the kubelets.
func (h *handlers) volumes(w http.ResponseWriter, r *http.Request) {
	var q PromQuery
	if h.prom != nil {
		q = h.prom()
	}
	httpx.WriteJSON(w, 200, h.svc().Volumes(r.Context(), r.URL.Query().Get("namespace"), q))
}
