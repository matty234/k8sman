package server

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

func (s *Server) kubeconfigRoutes() {
	s.mux.HandleFunc("GET /api/kubeconfigs", s.handleKubeconfigs)
	s.mux.HandleFunc("POST /api/kubeconfigs/current", s.handleSwitchKubeconfig)
}

// handleKubeconfigs lists kubeconfig files the user can switch to. Only
// paths and context names are returned, never credentials.
func (s *Server) handleKubeconfigs(w http.ResponseWriter, r *http.Request) {
	home, _ := os.UserHomeDir()
	env := os.Getenv("KUBECONFIG")
	current := s.mgr.Kubeconfig()
	recent := s.settings.Get().RecentKubeconfigs
	cands := cluster.DiscoverKubeconfigs(home, env, append([]string{current}, recent...))
	out := map[string]any{"current": current, "candidates": cands, "home": home}
	if current == "" {
		// Default loading rules merging several $KUBECONFIG files.
		out["merged"] = cluster.SplitKubeconfigEnv(env)
	}
	if c := s.mgr.Clients(); c != nil {
		out["context"] = c.Context
	} else {
		out["error"] = s.mgr.Err().Error()
	}
	writeJSON(w, 200, out)
}

// handleSwitchKubeconfig makes another kubeconfig file active and connects to
// its last used (else current) context.
func (s *Server) handleSwitchKubeconfig(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Path == "" {
		writeErr(w, badRequest("body must be {\"path\": \"<kubeconfig file>\"}"))
		return
	}
	home, _ := os.UserHomeDir()
	path := filepath.Clean(cluster.ExpandHome(body.Path, home))
	if !filepath.IsAbs(path) {
		writeErr(w, badRequest("path must be absolute"))
		return
	}
	last := s.settings.Get().LastContext[path]
	if err := s.mgr.SwitchKubeconfig(path, last); err != nil {
		writeErr(w, badRequest("%v", err))
		return
	}
	if err := s.settings.UseKubeconfig(path); err != nil {
		log.Printf("save settings: %v", err)
	}
	if c := s.mgr.Clients(); c != nil {
		if err := s.settings.SetLastContext(path, c.Context); err != nil {
			log.Printf("save settings: %v", err)
		}
		log.Printf("switched kubeconfig to %s (context %s)", path, c.Context)
	}
	s.handleKubeconfigs(w, r)
}
