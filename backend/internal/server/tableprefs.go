package server

import (
	"encoding/json"
	"net/http"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Table preferences per resource kind (sort, column widths, filter), kept
// in settings.json so tables come back the way they were left.
func (s *Server) tablePrefsRoutes() {
	s.mux.HandleFunc("GET /api/settings/tables", s.handleGetTablePrefs)
	s.mux.HandleFunc("PUT /api/settings/tables", s.handlePutTablePrefs)
}

// handleGetTablePrefs returns {tables: {"<group>/<Kind>": {…}}}.
func (s *Server) handleGetTablePrefs(w http.ResponseWriter, r *http.Request) {
	tables := map[string]settings.TablePrefs{}
	if s.settings != nil {
		if t := s.settings.Get().Tables; t != nil {
			tables = t
		}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"tables": tables})
}

// handlePutTablePrefs saves one kind's preferences.
// Body: {"kind": "apps/Deployment", "prefs": {…} | null}.
func (s *Server) handlePutTablePrefs(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Kind  string               `json:"kind"`
		Prefs *settings.TablePrefs `json:"prefs"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil || body.Kind == "" || len(body.Kind) > 300 {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorBody{Error: "body must be {kind, prefs}", Code: http.StatusBadRequest})
		return
	}
	if p := body.Prefs; p != nil && (len(p.Filter) > 1000 || len(p.Widths) > 100 || len(p.Mode) > 40) {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorBody{Error: "prefs too large", Code: http.StatusBadRequest})
		return
	}
	if s.settings == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorBody{Error: "settings are not available", Code: http.StatusServiceUnavailable})
		return
	}
	if err := s.settings.SetTablePrefs(body.Kind, body.Prefs); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
