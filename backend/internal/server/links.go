package server

import (
	"encoding/json"
	"net/http"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Which form "Copy link" produces: the https://k8sman.dev/o/ page (default)
// or the raw k8sman:// URL. An app setting, like the sidebar layout.
func (s *Server) linkRoutes() {
	s.mux.HandleFunc("GET /api/settings/links", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, 200, map[string]any{"appLinks": s.settings.Get().AppLinks})
	})
	s.mux.HandleFunc("PUT /api/settings/links", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			AppLinks bool `json:"appLinks"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeErr(w, httpx.BadRequest("body must be {\"appLinks\": bool}: %v", err))
			return
		}
		if err := s.settings.Update(func(st *settings.Settings) { st.AppLinks = body.AppLinks }); err != nil {
			writeErr(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}

// The log viewer's "Newest first" preference, applied to every log view.
func (s *Server) logSettingsRoutes() {
	s.mux.HandleFunc("GET /api/settings/logs", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, 200, map[string]any{"newestFirst": s.settings.Get().LogsNewestFirst})
	})
	s.mux.HandleFunc("PUT /api/settings/logs", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			NewestFirst bool `json:"newestFirst"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeErr(w, httpx.BadRequest("body must be {\"newestFirst\": bool}: %v", err))
			return
		}
		if err := s.settings.Update(func(st *settings.Settings) { st.LogsNewestFirst = body.NewestFirst }); err != nil {
			writeErr(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
