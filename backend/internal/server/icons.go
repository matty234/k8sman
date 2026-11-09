package server

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/icons"
	"github.com/matty234/k8sman/backend/internal/settings"
)

func (s *Server) iconRoutes(opts Options) {
	s.icons = icons.NewResolver(opts.IconCacheDir, func() bool { return s.remoteIcons(opts.NoRemoteIcons) })
	s.mux.HandleFunc("GET /api/icons", s.handleIconIndex)
	s.mux.HandleFunc("GET /api/icons/{group}", s.handleIcon)
	s.mux.HandleFunc("GET /api/settings/icons", func(w http.ResponseWriter, r *http.Request) { s.writeIconSettings(w, opts.NoRemoteIcons) })
	s.mux.HandleFunc("PUT /api/settings/icons", func(w http.ResponseWriter, r *http.Request) { s.handlePutIconSettings(w, r, opts.NoRemoteIcons) })
}

// writeIconSettings reports the remote-icons setting: {remoteIcons: true |
// false | null (automatic), flag: --no-remote-icons is set, effective:
// whether icons are fetched for the current context}.
func (s *Server) writeIconSettings(w http.ResponseWriter, disabled bool) {
	var v *bool
	if s.settings != nil {
		v = s.settings.Get().RemoteIcons
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"remoteIcons": v, "flag": disabled, "effective": s.remoteIcons(disabled)})
}

// handlePutIconSettings saves settings.json "remoteIcons".
// Body: {"remoteIcons": true | false | null}; null = automatic.
func (s *Server) handlePutIconSettings(w http.ResponseWriter, r *http.Request, disabled bool) {
	var body struct {
		RemoteIcons *bool `json:"remoteIcons"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&body); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorBody{Error: "body must be {remoteIcons}", Code: http.StatusBadRequest})
		return
	}
	if s.settings == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorBody{Error: "settings are not available", Code: http.StatusServiceUnavailable})
		return
	}
	if err := s.settings.Update(func(st *settings.Settings) { st.RemoteIcons = body.RemoteIcons }); err != nil {
		writeErr(w, err)
		return
	}
	s.writeIconSettings(w, disabled)
}

// remoteIcons decides whether icons may be fetched from the internet: never
// with --no-remote-icons, else settings.json "remoteIcons" when set, else
// only for local clusters (a favicon lookup tells the group's website, and
// anyone watching DNS, which CRDs the cluster runs).
func (s *Server) remoteIcons(disabled bool) bool {
	if disabled {
		return false
	}
	if v := s.settings.Get().RemoteIcons; v != nil {
		return *v
	}
	c := s.mgr.Clients()
	return c != nil && icons.IsLocalCluster(c.Context, c.RESTConfig.Host)
}

func (s *Server) iconCluster(c *cluster.Clients) icons.Cluster {
	return icons.Cluster{Key: s.mgr.Kubeconfig() + "\x00" + c.Context, Typed: c.Typed, Config: c.RESTConfig}
}

// handleIcon serves the icon image for one API group. Bundled and missing
// icons are a 404 whose JSON body says which (the UI has the bundled
// assets and draws a monogram otherwise).
func (s *Server) handleIcon(w http.ResponseWriter, r *http.Request) {
	group := r.PathValue("group")
	if !icons.ValidGroup(group) {
		writeErr(w, httpx.BadRequest("invalid API group %q", group))
		return
	}
	c := s.mgr.Clients()
	res := s.icons.Resolve(r.Context(), s.iconCluster(c), group)
	w.Header().Set("X-Icon-Source", res.Source)
	if len(res.Data) == 0 {
		httpx.WriteJSON(w, http.StatusNotFound, map[string]any{
			"error": "no icon image for " + group, "code": http.StatusNotFound,
			"source": res.Source, "asset": res.Asset,
		})
		return
	}
	w.Header().Set("Content-Type", res.ContentType)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write(res.Data)
}

// handleIconIndex resolves every custom (CRD) group on the cluster.
func (s *Server) handleIconIndex(w http.ResponseWriter, r *http.Request) {
	c := s.mgr.Clients()
	types, err := c.Resources(r.Context(), false)
	if err != nil {
		writeErr(w, err)
		return
	}
	seen := map[string]bool{}
	var groups []string
	for _, t := range types {
		if t.Custom && !seen[t.Group] {
			seen[t.Group] = true
			groups = append(groups, t.Group)
		}
	}
	sort.Strings(groups)
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	cl := s.iconCluster(c)
	out := make(map[string]icons.Result, len(groups))
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 6)
	for _, g := range groups {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			res := s.icons.Resolve(ctx, cl, g)
			mu.Lock()
			out[g] = res
			mu.Unlock()
		}()
	}
	wg.Wait()
	httpx.WriteJSON(w, http.StatusOK, out)
}
