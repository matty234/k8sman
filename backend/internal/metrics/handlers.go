package metrics

import (
	"encoding/json"
	"errors"
	"net/http"

	apierrors "k8s.io/apimachinery/pkg/api/errors"

	"github.com/bargrove/k8sman/backend/internal/cluster"
)

// Register adds the /api/metrics/* routes. Each request uses the active kube
// context's Service.
func Register(mux *http.ServeMux, mgr *cluster.Manager) {
	h := &handlers{svc: func() *Service { return For(mgr.Clients()) }}
	h.register(mux)
}

type handlers struct {
	svc func() *Service
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
}

type apiError struct {
	Error string `json:"error"`
	Code  int    `json:"code"`
	// State is set when a metrics API is unusable: notInstalled or notReady.
	State string `json:"state,omitempty"`
	Group string `json:"group,omitempty"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

var errBadRequest = errors.New("bad request")

func writeErr(w http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	body := apiError{Error: err.Error()}
	var ue *UnavailableError
	var se apierrors.APIStatus
	switch {
	case errors.As(err, &ue):
		body.State, body.Group = ue.Status.State, ue.Status.Group
		status = http.StatusServiceUnavailable
		if ue.Status.State == StateNotInstalled {
			status = http.StatusNotFound
		}
	case errors.Is(err, errBadRequest):
		status = http.StatusBadRequest
	case errors.As(err, &se):
		if c := int(se.Status().Code); c >= 400 {
			status = c
		}
	}
	body.Code = status
	writeJSON(w, status, body)
}

func (h *handlers) status(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, h.svc().Status(r.Context(), r.URL.Query().Get("refresh") == "true"))
}

func (h *handlers) nodes(w http.ResponseWriter, r *http.Request) {
	items, err := h.svc().Nodes(r.Context())
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
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
	writeJSON(w, 200, map[string]any{"items": items})
}

func (h *handlers) customDiscover(w http.ResponseWriter, r *http.Request) {
	d, err := h.svc().DiscoverCustom(r.Context())
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, 200, d)
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
		writeErr(w, errors.Join(errBadRequest, errors.New("resource and metric are required")))
		return
	}
	items, err := h.svc().Custom(r.Context(), cq)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

func (h *handlers) externalDiscover(w http.ResponseWriter, r *http.Request) {
	d, err := h.svc().DiscoverExternal(r.Context(), r.URL.Query().Get("namespace"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, 200, d)
}

func (h *handlers) external(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	eq := ExternalQuery{Namespace: q.Get("namespace"), Metric: q.Get("metric"), Selector: q.Get("labelSelector")}
	if eq.Namespace == "" || eq.Metric == "" {
		writeErr(w, errors.Join(errBadRequest, errors.New("namespace and metric are required")))
		return
	}
	items, err := h.svc().External(r.Context(), eq)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

func (h *handlers) hpa(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("namespace") == "" || q.Get("name") == "" {
		writeErr(w, errors.Join(errBadRequest, errors.New("namespace and name are required")))
		return
	}
	a, err := h.svc().AnalyzeHPA(r.Context(), q.Get("namespace"), q.Get("name"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, 200, a)
}
