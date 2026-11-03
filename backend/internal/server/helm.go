package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"helm.sh/helm/v3/pkg/action"
	"k8s.io/client-go/restmapper"

	"github.com/bargrove/k8sman/backend/internal/cluster"
	"github.com/bargrove/k8sman/backend/internal/helm"
)

func (s *Server) helmRoutes() {
	s.mux.HandleFunc("GET /api/helm/releases", s.handleHelmReleases)
	s.mux.HandleFunc("GET /api/helm/release", s.handleHelmRelease)
	s.mux.HandleFunc("GET /api/helm/history", s.handleHelmHistory)
	s.mux.HandleFunc("GET /api/helm/diff", s.handleHelmDiff)
	s.mux.HandleFunc("POST /api/helm/rollback", s.handleHelmRollback)
	s.mux.HandleFunc("POST /api/helm/uninstall", s.handleHelmUninstall)
	s.mux.HandleFunc("POST /api/helm/upgrade", s.handleHelmUpgrade)
	s.mux.HandleFunc("POST /api/helm/install", s.handleHelmInstall)
	s.mux.HandleFunc("GET /api/helm/chart-versions", s.handleHelmChartVersions)
}

// helmConfig builds a Helm action configuration on the active context.
func (s *Server) helmConfig(namespace string) (*cluster.Clients, *action.Configuration, error) {
	c := s.mgr.Clients()
	cfg, err := helm.NewConfig(c, namespace)
	return c, cfg, err
}

// helmTarget reads the required namespace/name query params.
func helmTarget(r *http.Request) (ns, name string, err error) {
	q := r.URL.Query()
	ns, name = q.Get("namespace"), q.Get("name")
	if ns == "" || name == "" {
		return "", "", badRequest("namespace and name are required")
	}
	return ns, name, nil
}

func intParam(r *http.Request, key string) (int, error) {
	v := r.URL.Query().Get(key)
	if v == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return 0, badRequest("%s must be a non-negative integer", key)
	}
	return n, nil
}

func writeHelmErr(w http.ResponseWriter, err error) {
	var stuck *helm.StuckError
	switch {
	case errors.As(err, &stuck):
		writeJSON(w, http.StatusConflict, map[string]any{
			"error": stuck.Error(), "code": http.StatusConflict, "reason": "ReleasePending", "stuck": stuck,
		})
	case errors.Is(err, helm.ErrNotFound):
		writeJSON(w, http.StatusNotFound, apiError{Error: err.Error(), Code: http.StatusNotFound, Reason: "NotFound"})
	case errors.Is(err, helm.ErrInvalid):
		msg := strings.TrimPrefix(err.Error(), helm.ErrInvalid.Error()+": ")
		writeJSON(w, http.StatusUnprocessableEntity, apiError{Error: msg, Code: http.StatusUnprocessableEntity, Reason: "Invalid"})
	case strings.Contains(err.Error(), "cannot re-use a name that is still in use"):
		writeJSON(w, http.StatusConflict, apiError{Error: err.Error(), Code: http.StatusConflict, Reason: "AlreadyExists"})
	case strings.Contains(err.Error(), "another operation (install/upgrade/rollback) is in progress"):
		writeJSON(w, http.StatusConflict, apiError{Error: err.Error(), Code: http.StatusConflict, Reason: "ReleasePending"})
	default:
		writeErr(w, err)
	}
}

func (s *Server) handleHelmInstall(w http.ResponseWriter, r *http.Request) {
	if s.readOnlyRefused(w) {
		return
	}
	var req helm.InstallRequest
	if err := decodeHelmBody(r, &req, &req.Namespace, &req.ReleaseName); err != nil {
		writeErr(w, err)
		return
	}
	c, cfg, err := s.helmConfig(req.Namespace)
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := helm.Install(context.WithoutCancel(r.Context()), cfg, req)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, helmResult(c, res))
}

func (s *Server) handleHelmChartVersions(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("repo") == "" || q.Get("chart") == "" {
		writeErr(w, badRequest("repo and chart are required"))
		return
	}
	v, err := helm.ChartVersions(q.Get("repo"), q.Get("chart"))
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"versions": v})
}

func (s *Server) readOnlyRefused(w http.ResponseWriter) bool {
	if s.readOnly {
		writeJSON(w, http.StatusForbidden, apiError{Error: errReadOnly.Error(), Code: http.StatusForbidden})
		return true
	}
	return false
}

func (s *Server) handleHelmReleases(w http.ResponseWriter, r *http.Request) {
	_, cfg, err := s.helmConfig(r.URL.Query().Get("namespace"))
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := helm.List(cfg)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleHelmRelease(w http.ResponseWriter, r *http.Request) {
	ns, name, err := helmTarget(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	rev, err := intParam(r, "revision")
	if err != nil {
		writeErr(w, err)
		return
	}
	c, cfg, err := s.helmConfig(ns)
	if err != nil {
		writeErr(w, err)
		return
	}
	d, err := helm.Get(cfg, name, rev, restmapper.NewDeferredDiscoveryRESTMapper(c.Discovery))
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *Server) handleHelmHistory(w http.ResponseWriter, r *http.Request) {
	ns, name, err := helmTarget(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	_, cfg, err := s.helmConfig(ns)
	if err != nil {
		writeErr(w, err)
		return
	}
	h, err := helm.History(cfg, name)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"history": h})
}

func (s *Server) handleHelmDiff(w http.ResponseWriter, r *http.Request) {
	ns, name, err := helmTarget(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	from, err := intParam(r, "from")
	if err != nil {
		writeErr(w, err)
		return
	}
	to, err := intParam(r, "to")
	if err != nil {
		writeErr(w, err)
		return
	}
	_, cfg, err := s.helmConfig(ns)
	if err != nil {
		writeErr(w, err)
		return
	}
	d, err := helm.Diff(cfg, name, from, to)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

// decodeHelmBody decodes a mutation body and checks namespace/name.
func decodeHelmBody(r *http.Request, v any, ns, name *string) error {
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		return badRequest("invalid body: %v", err)
	}
	if *ns == "" || *name == "" {
		return badRequest("namespace and name are required")
	}
	return nil
}

// helmResult adds the kube context to a mutation result.
func helmResult(c *cluster.Clients, res *helm.Result) map[string]any {
	return map[string]any{
		"message": res.Message, "dryRun": res.DryRun, "context": c.Context, "release": res.Release,
		"manifest": res.Manifest, "currentManifest": res.CurrentManifest, "notes": res.Notes,
	}
}

func (s *Server) handleHelmRollback(w http.ResponseWriter, r *http.Request) {
	if s.readOnlyRefused(w) {
		return
	}
	var req helm.RollbackRequest
	if err := decodeHelmBody(r, &req, &req.Namespace, &req.Name); err != nil {
		writeErr(w, err)
		return
	}
	c, cfg, err := s.helmConfig(req.Namespace)
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := helm.Rollback(cfg, req)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, helmResult(c, res))
}

func (s *Server) handleHelmUninstall(w http.ResponseWriter, r *http.Request) {
	if s.readOnlyRefused(w) {
		return
	}
	var req helm.UninstallRequest
	if err := decodeHelmBody(r, &req, &req.Namespace, &req.Name); err != nil {
		writeErr(w, err)
		return
	}
	c, cfg, err := s.helmConfig(req.Namespace)
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := helm.Uninstall(cfg, req)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, helmResult(c, res))
}

func (s *Server) handleHelmUpgrade(w http.ResponseWriter, r *http.Request) {
	if s.readOnlyRefused(w) {
		return
	}
	var req helm.UpgradeRequest
	if err := decodeHelmBody(r, &req, &req.Namespace, &req.Name); err != nil {
		writeErr(w, err)
		return
	}
	c, cfg, err := s.helmConfig(req.Namespace)
	if err != nil {
		writeErr(w, err)
		return
	}
	// Never let a closed connection cancel an upgrade halfway: that is
	// exactly how releases end up stuck in pending-upgrade.
	res, err := helm.Upgrade(context.WithoutCancel(r.Context()), cfg, req)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, helmResult(c, res))
}
