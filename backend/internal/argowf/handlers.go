package argowf

import (
	"context"
	"net/http"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
)

// Handler serves /api/argowf/* and runs the argo-server-only actions.
type Handler struct {
	env  func() env
	disc *discoverer
	// crd reports whether the Workflow CRD is served (nil = assume so).
	crd func(ctx context.Context) bool
}

// Register mounts GET /api/argowf/status. It only reads (discovery and a
// userinfo probe), so it is allowed in --read-only mode.
func Register(mux httpx.Router, mgr *cluster.Manager) *Handler {
	h := &Handler{
		env: func() env {
			c := mgr.Clients()
			return clientsEnv(c)
		},
		disc: newDiscoverer(),
		crd: func(ctx context.Context) bool {
			_, err := mgr.Clients().Find(ctx, "argoproj.io", "", "workflows")
			return err == nil
		},
	}
	mux.HandleFunc("GET /api/argowf/status", h.handleStatus)
	return h
}

// clientsEnv is the env for one kube context's clients.
func clientsEnv(c *cluster.Clients) env {
	return newEnv(c.Context, c.Typed, c.RESTConfig)
}

func (h *Handler) handleStatus(w http.ResponseWriter, r *http.Request) {
	e := h.env()
	if h.crd != nil && !h.crd(r.Context()) {
		httpx.WriteJSON(w, http.StatusOK, Status{Context: e.context})
		return
	}
	d := h.disc.get(r.Context(), e, r.URL.Query().Get("refresh") != "")
	st := d.status
	st.CRD = true
	httpx.WriteJSON(w, http.StatusOK, st)
}

// Retry retries ns/name through argo-server for the clients' context.
func (h *Handler) Retry(ctx context.Context, c *cluster.Clients, ns, name string, restartSuccessful bool) error {
	return h.retry(ctx, clientsEnv(c), ns, name, restartSuccessful)
}

// ResubmitMemoized resubmits ns/name (memoized) through argo-server.
func (h *Handler) ResubmitMemoized(ctx context.Context, c *cluster.Clients, ns, name string) (string, error) {
	return h.resubmitMemoized(ctx, clientsEnv(c), ns, name)
}
