package server

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/matty234/k8sman/backend/internal/helm"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// marketRoutes are the Helm charts browser: the user's repositories
// (/api/helm/repos*), Artifact Hub (/api/helm/artifacthub/*, opt-in) and
// "upgrade available" lookups (/api/helm/updates).
func (m *helmModule) marketRoutes(r httpx.Router) {
	r.HandleFunc("GET /api/helm/repos", m.handleRepos)
	r.HandleFunc("POST /api/helm/repos/update", m.handleRepoUpdate)
	r.HandleFunc("POST /api/helm/repos/add", m.handleRepoAdd)
	r.HandleFunc("POST /api/helm/repos/remove", m.handleRepoRemove)
	r.HandleFunc("GET /api/helm/repos/charts", m.handleRepoCharts)
	r.HandleFunc("GET /api/helm/repos/chart", m.handleRepoChart)
	r.HandleFunc("GET /api/helm/repos/chart/files", m.handleRepoChartFiles)
	r.HandleFunc("GET /api/helm/artifacthub/settings", m.handleAHSettings)
	r.HandleFunc("PUT /api/helm/artifacthub/settings", m.handlePutAHSettings)
	r.HandleFunc("GET /api/helm/artifacthub/search", m.handleAHSearch)
	r.HandleFunc("GET /api/helm/artifacthub/package", m.handleAHPackage)
	r.HandleFunc("GET /api/helm/artifacthub/values", m.handleAHValues)
	r.HandleFunc("GET /api/helm/updates", m.handleHelmUpdates)
}

func (m *helmModule) artifactHubEnabled() bool {
	return m.d.Settings != nil && m.d.Settings.Get().ArtifactHub
}

// refuseArtifactHub answers 403 ArtifactHubDisabled unless the user opted in.
func (m *helmModule) refuseArtifactHub(w http.ResponseWriter) bool {
	if m.artifactHubEnabled() {
		return false
	}
	httpx.WriteError(w, http.StatusForbidden, "ArtifactHubDisabled", "Artifact Hub is turned off: enable it in Settings to search artifacthub.io")
	return true
}

func (m *helmModule) handleRepos(w http.ResponseWriter, r *http.Request) {
	l, err := helm.ListRepos()
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, l)
}

type repoName struct {
	Name string `json:"name"`
}

func (m *helmModule) handleRepoUpdate(w http.ResponseWriter, r *http.Request) {
	body, ok := httpx.DecodeJSON[repoName](w, r, 1<<12)
	if !ok {
		return
	}
	if body.Name == "" {
		writeErr(w, httpx.BadRequest("name is required"))
		return
	}
	res, err := helm.UpdateRepo(body.Name)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

// handleRepoAdd writes the user's repositories.yaml: refused when read-only.
func (m *helmModule) handleRepoAdd(w http.ResponseWriter, r *http.Request) {
	if m.d.RefuseReadOnly(w) {
		return
	}
	body, ok := httpx.DecodeJSON[helm.AddRepoRequest](w, r, 1<<14)
	if !ok {
		return
	}
	res, err := helm.AddRepo(body)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (m *helmModule) handleRepoRemove(w http.ResponseWriter, r *http.Request) {
	if m.d.RefuseReadOnly(w) {
		return
	}
	body, ok := httpx.DecodeJSON[repoName](w, r, 1<<12)
	if !ok {
		return
	}
	if body.Name == "" {
		writeErr(w, httpx.BadRequest("name is required"))
		return
	}
	if err := helm.RemoveRepo(body.Name); err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"message": "Removed repository " + body.Name})
}

func (m *helmModule) handleRepoCharts(w http.ResponseWriter, r *http.Request) {
	res, err := helm.ListRepoCharts(r.URL.Query().Get("repo"))
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func repoChartParams(r *http.Request) (repo, chart, version string, err error) {
	q := r.URL.Query()
	repo, chart, version = q.Get("repo"), q.Get("chart"), q.Get("version")
	if repo == "" || chart == "" {
		return "", "", "", httpx.BadRequest("repo and chart are required")
	}
	return repo, chart, version, nil
}

func (m *helmModule) handleRepoChart(w http.ResponseWriter, r *http.Request) {
	repo, chart, version, err := repoChartParams(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	d, err := helm.RepoChartDetail(repo, chart, version)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, d)
}

func (m *helmModule) handleRepoChartFiles(w http.ResponseWriter, r *http.Request) {
	repo, chart, version, err := repoChartParams(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	f, err := helm.RepoChartFiles(repo, chart, version)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, f)
}

func (m *helmModule) handleAHSettings(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"enabled": m.artifactHubEnabled()})
}

// handlePutAHSettings saves the global Artifact Hub opt-in. Body: {"enabled": bool}.
func (m *helmModule) handlePutAHSettings(w http.ResponseWriter, r *http.Request) {
	body, ok := httpx.DecodeJSON[struct {
		Enabled bool `json:"enabled"`
	}](w, r, 1<<12)
	if !ok {
		return
	}
	if m.d.Settings == nil {
		writeErr(w, httpx.BadRequest("settings are not available"))
		return
	}
	if err := m.d.Settings.Update(func(s *settings.Settings) { s.ArtifactHub = body.Enabled }); err != nil {
		writeErr(w, err)
		return
	}
	m.handleAHSettings(w, r)
}

func (m *helmModule) handleAHSearch(w http.ResponseWriter, r *http.Request) {
	if m.refuseArtifactHub(w) {
		return
	}
	q := r.URL.Query()
	offset, _ := strconv.Atoi(q.Get("offset"))
	limit, _ := strconv.Atoi(q.Get("limit"))
	res, err := helm.SearchArtifactHub(r.Context(), strings.TrimSpace(q.Get("q")), offset, limit)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (m *helmModule) handleAHPackage(w http.ResponseWriter, r *http.Request) {
	if m.refuseArtifactHub(w) {
		return
	}
	repo, chart, version, err := repoChartParams(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	d, err := helm.ArtifactHubPackage(r.Context(), repo, chart, version)
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, d)
}

func (m *helmModule) handleAHValues(w http.ResponseWriter, r *http.Request) {
	if m.refuseArtifactHub(w) {
		return
	}
	q := r.URL.Query()
	v, err := helm.ArtifactHubValues(r.Context(), q.Get("packageId"), q.Get("version"))
	if err != nil {
		writeHelmErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"values": v, "version": q.Get("version")})
}

// handleHelmUpdates answers ?chart=<name>@<version> (repeated) with the
// newer versions found, keyed the same way.
func (m *helmModule) handleHelmUpdates(w http.ResponseWriter, r *http.Request) {
	var qs []helm.ChartQuery
	for _, c := range r.URL.Query()["chart"] {
		i := strings.LastIndex(c, "@")
		if i <= 0 || i == len(c)-1 {
			writeErr(w, httpx.BadRequest("chart must be <name>@<version>"))
			return
		}
		qs = append(qs, helm.ChartQuery{Chart: c[:i], Version: c[i+1:]})
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"updates": helm.FindUpdates(ctx, qs, m.artifactHubEnabled())})
}
