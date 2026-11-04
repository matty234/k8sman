package server

import (
	"encoding/json"
	"net/http"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// The sidebar layout (pages shown/hidden/ordered and pinned kinds) lives in
// settings.json and works without a cluster connection.
func (s *Server) sidebarRoutes() {
	s.mux.HandleFunc("GET /api/settings/sidebar", s.handleGetSidebar)
	s.mux.HandleFunc("PUT /api/settings/sidebar", s.handlePutSidebar)
	s.mux.HandleFunc("DELETE /api/settings/sidebar", s.handleDeleteSidebar)
}

// handleGetSidebar returns {sidebar: {items:[…]}}, or {sidebar: null} when
// the user hasn't customised it (the UI then uses its default layout).
func (s *Server) handleGetSidebar(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, 200, map[string]any{"sidebar": s.settings.Get().Sidebar})
}

func (s *Server) handlePutSidebar(w http.ResponseWriter, r *http.Request) {
	var body settings.Sidebar
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("body must be {\"items\": [...]}: %v", err))
		return
	}
	if body.Items == nil {
		body.Items = []settings.SidebarItem{}
	}
	if err := body.Valid(); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	if err := s.settings.SetSidebar(&body); err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"sidebar": body})
}

func (s *Server) handleDeleteSidebar(w http.ResponseWriter, r *http.Request) {
	if err := s.settings.SetSidebar(nil); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
