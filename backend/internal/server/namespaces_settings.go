package server

import (
	"encoding/json"
	"net/http"
	"regexp"

	"github.com/matty234/k8sman/backend/internal/httpx"
)

// Namespaces the user added by hand, per kube context, for clusters where
// Namespaces can't be listed. Local settings only, so they work in
// read-only mode.
func (s *Server) namespaceRoutes() {
	s.mux.HandleFunc("GET /api/settings/namespaces", s.handleGetNamespaces)
	s.mux.HandleFunc("PUT /api/settings/namespaces", s.handlePutNamespaces)
}

var dns1123Label = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)

const maxRememberedNamespaces = 200

// handleGetNamespaces returns {context, namespaces}. ?context= defaults to
// the current context.
func (s *Server) handleGetNamespaces(w http.ResponseWriter, r *http.Request) {
	ctx := s.settingsContext(r)
	list := []string{}
	if s.settings != nil {
		list = append(list, s.settings.Get().Namespaces[ctx]...)
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"context": ctx, "namespaces": list})
}

// handlePutNamespaces replaces a context's list.
// Body: {"context"?: "<name>", "namespaces": ["a", "b"]}.
func (s *Server) handlePutNamespaces(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Context    string   `json:"context"`
		Namespaces []string `json:"namespaces"`
	}
	bad := func(msg string) {
		httpx.WriteJSON(w, http.StatusBadRequest, apiError{Error: msg, Code: http.StatusBadRequest})
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil || len(body.Namespaces) > maxRememberedNamespaces {
		bad("body must be {context?, namespaces}")
		return
	}
	for _, n := range body.Namespaces {
		if len(n) > 63 || !dns1123Label.MatchString(n) {
			bad("not a namespace name: " + n)
			return
		}
	}
	ctx := body.Context
	if ctx == "" {
		ctx = s.settingsContext(r)
	}
	if ctx == "" {
		bad("no context")
		return
	}
	if s.settings == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, apiError{Error: "settings are not available", Code: http.StatusServiceUnavailable})
		return
	}
	if err := s.settings.SetNamespaces(ctx, body.Namespaces); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
