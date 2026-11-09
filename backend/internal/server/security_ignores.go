package server

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/security"
)

const maxSecurityIgnores = 500

// Findings the user ignores on the Security page, per kube context. Local
// settings only, so they work in read-only mode.
func (s *Server) securityIgnoreRoutes() {
	s.mux.HandleFunc("GET /api/settings/security-ignores", func(w http.ResponseWriter, r *http.Request) {
		ctx := s.settingsContext(r)
		rules := []security.IgnoreRule{}
		if s.settings != nil {
			rules = append(rules, s.settings.SecurityIgnores(ctx)...)
		}
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"context": ctx, "ignores": rules})
	})
	s.mux.HandleFunc("PUT /api/settings/security-ignores", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Context string                `json:"context"`
			Ignores []security.IgnoreRule `json:"ignores"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil || len(body.Ignores) > maxSecurityIgnores {
			writeErr(w, httpx.BadRequest("body must be {context?, ignores: [{check, namespace?, kind?, name?, reason?, at?}]}"))
			return
		}
		now := time.Now().UTC().Format(time.RFC3339)
		for i := range body.Ignores {
			g := &body.Ignores[i]
			if g.Check == "" || (g.Kind == "") != (g.Name == "") {
				writeErr(w, httpx.BadRequest("a rule needs a check, and kind and name together"))
				return
			}
			if len(g.Check) > 100 || len(g.Namespace) > 253 || len(g.Kind) > 253 || len(g.Name) > 253 || len(g.Reason) > 1000 {
				writeErr(w, httpx.BadRequest("a rule field is too long"))
				return
			}
			if g.At == "" {
				g.At = now
			}
		}
		ctx := body.Context
		if ctx == "" {
			ctx = s.settingsContext(r)
		}
		if ctx == "" {
			writeErr(w, httpx.BadRequest("no context"))
			return
		}
		if s.settings == nil {
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorBody{Error: "settings are not available", Code: http.StatusServiceUnavailable})
			return
		}
		if err := s.settings.SetSecurityIgnores(ctx, body.Ignores); err != nil {
			writeErr(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
