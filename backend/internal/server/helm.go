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

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/helm"
	"github.com/matty234/k8sman/backend/internal/httpx"
)

// helmModule is the Helm integration: releases, history, diffs,
// rollback, upgrade, uninstall and install (/api/helm/*), through the Helm
// SDK on the active context.
type helmModule struct{ d Deps }

func (m *helmModule) Name() string { return "helm" }

func (m *helmModule) Routes(r httpx.Router, d Deps) {
	m.d = d
	r.HandleFunc("GET /api/helm/releases", m.handleHelmReleases)
	r.HandleFunc("GET /api/helm/release", m.handleHelmRelease)
	r.HandleFunc("GET /api/helm/history", m.handleHelmHistory)
	r.HandleFunc("GET /api/helm/diff", m.handleHelmDiff)
	r.HandleFunc("POST /api/helm/rollback", m.handleHelmRollback)
	r.HandleFunc("POST /api/helm/uninstall", m.handleHelmUninstall)
	r.HandleFunc("POST /api/helm/upgrade", m.handleHelmUpgrade)
	r.HandleFunc("POST /api/helm/install", m.handleHelmInstall)
	r.HandleFunc("GET /api/helm/chart-versions", m.handleHelmChartVersions)
}

// config builds a Helm action configuration on the active context.
func (m *helmModule) config(namespace string) (*cluster.Clients, *action.Configuration, error) {
	c := m.d.Mgr.Clients()
	cfg, err := helm.NewConfig(c, namespace)
	return c, cfg, err
}

// helmTarget reads the required namespace/name query params.
func helmTarget(r *http.Request) (ns, name string, err error) {
	q := r.URL.Query()
	ns, name = q.Get("namespace"), q.Get("name")
	if ns == "" || name == "" {
		return "", "", httpx.BadRequest("namespace and name are required")
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
		return 0, httpx.BadRequest("%s must be a non-negative integer", key)
	}
	return n, nil
}

func writeHelmErr(w http.ResponseWriter, err error) {
	var stuck *helm.StuckError
	switch {
	case errors.As(err, &stuck):
		httpx.WriteJSON(w, http.StatusConflict, map[string]any{
			"error": stuck.Error(), "code": http.StatusConflict, "reason": "ReleasePending", "stuck": stuck,
		})
	case errors.Is(err, helm.ErrNotFound):
		httpx.WriteJSON(w, http.StatusNotFound, apiError{Error: err.Error(), Code: http.StatusNotFound, Reason: "NotFound"})
	case errors.Is(err, helm.ErrInvalid):
		msg := strings.TrimPrefix(err.Error(), helm.ErrInvalid.Error()+": ")
		httpx.WriteJSON(w, http.StatusUnprocessableEntity, apiError{Error: msg, Code: http.StatusUnprocessableEntity, Reason: "Invalid"})
	case strings.Contains(err.Error(), "cannot re-use a name that is still in use"):
		httpx.WriteJSON(w, http.StatusConflict, apiError{Error: err.Error(), Code: http.StatusConflict, Reason: "AlreadyExists"})
	case strings.Contains(err.Error(), "another operation (install/upgrade/rollback) is in progress"):
		httpx.WriteJSON(w, http.StatusConflict, apiError{Error: err.Error(), Code: http.StatusConflict, Reason: "ReleasePending"})
	default:
		writeErr(w, err)
	}
}

func (m *helmModule) handleHelmInstall(w http.ResponseWriter, r *http.Request) {
	if m.d.RefuseReadOnly(w) {
		return
	}
	var req helm.InstallRequest
	if err := decodeHelmBody(r, &req, &req.Namespace, &req.ReleaseName); err != nil {
		writeErr(w, err)
		return
	}
	c, cfg, err := m.config(req.Namespace)
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := helm.Install(context.WithoutCancel(r.Context()), cfg, req)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, helmResult(c, res))
}

func (m *helmModule) handleHelmChartVersions(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("repo") == "" || q.Get("chart") == "" {
		writeErr(w, httpx.BadRequest("repo and chart are required"))
		return
	}
	v, err := helm.ChartVersions(q.Get("repo"), q.Get("chart"))
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"versions": v})
}

func (m *helmModule) handleHelmReleases(w http.ResponseWriter, r *http.Request) {
	_, cfg, err := m.config(r.URL.Query().Get("namespace"))
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := helm.List(cfg)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (m *helmModule) handleHelmRelease(w http.ResponseWriter, r *http.Request) {
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
	c, cfg, err := m.config(ns)
	if err != nil {
		writeErr(w, err)
		return
	}
	d, err := helm.Get(cfg, name, rev, restmapper.NewDeferredDiscoveryRESTMapper(c.Discovery))
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, d)
}

func (m *helmModule) handleHelmHistory(w http.ResponseWriter, r *http.Request) {
	ns, name, err := helmTarget(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	_, cfg, err := m.config(ns)
	if err != nil {
		writeErr(w, err)
		return
	}
	h, err := helm.History(cfg, name)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"history": h})
}

func (m *helmModule) handleHelmDiff(w http.ResponseWriter, r *http.Request) {
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
	_, cfg, err := m.config(ns)
	if err != nil {
		writeErr(w, err)
		return
	}
	d, err := helm.Diff(cfg, name, from, to)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, d)
}

// decodeHelmBody decodes a mutation body and checks namespace/name.
func decodeHelmBody(r *http.Request, v any, ns, name *string) error {
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		return httpx.BadRequest("invalid body: %v", err)
	}
	if *ns == "" || *name == "" {
		return httpx.BadRequest("namespace and name are required")
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

func (m *helmModule) handleHelmRollback(w http.ResponseWriter, r *http.Request) {
	if m.d.RefuseReadOnly(w) {
		return
	}
	var req helm.RollbackRequest
	if err := decodeHelmBody(r, &req, &req.Namespace, &req.Name); err != nil {
		writeErr(w, err)
		return
	}
	c, cfg, err := m.config(req.Namespace)
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := helm.Rollback(cfg, req)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, helmResult(c, res))
}

func (m *helmModule) handleHelmUninstall(w http.ResponseWriter, r *http.Request) {
	if m.d.RefuseReadOnly(w) {
		return
	}
	var req helm.UninstallRequest
	if err := decodeHelmBody(r, &req, &req.Namespace, &req.Name); err != nil {
		writeErr(w, err)
		return
	}
	c, cfg, err := m.config(req.Namespace)
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := helm.Uninstall(cfg, req)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, helmResult(c, res))
}

func (m *helmModule) handleHelmUpgrade(w http.ResponseWriter, r *http.Request) {
	if m.d.RefuseReadOnly(w) {
		return
	}
	var req helm.UpgradeRequest
	if err := decodeHelmBody(r, &req, &req.Namespace, &req.Name); err != nil {
		writeErr(w, err)
		return
	}
	c, cfg, err := m.config(req.Namespace)
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
	httpx.WriteJSON(w, http.StatusOK, helmResult(c, res))
}
