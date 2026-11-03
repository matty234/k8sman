package server

import (
	"context"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/icons"
)

func (s *Server) iconRoutes(opts Options) {
	s.icons = icons.NewResolver(opts.IconCacheDir, func() bool { return s.remoteIcons(opts.NoRemoteIcons) })
	s.mux.HandleFunc("GET /api/icons", s.handleIconIndex)
	s.mux.HandleFunc("GET /api/icons/{group}", s.handleIcon)
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
		writeErr(w, badRequest("invalid API group %q", group))
		return
	}
	c := s.mgr.Clients()
	res := s.icons.Resolve(r.Context(), s.iconCluster(c), group)
	w.Header().Set("X-Icon-Source", res.Source)
	if len(res.Data) == 0 {
		writeJSON(w, http.StatusNotFound, map[string]any{
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
	writeJSON(w, http.StatusOK, out)
}
