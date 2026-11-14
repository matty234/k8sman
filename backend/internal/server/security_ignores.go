package server

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
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
		rules = append(rules, s.settings.SecurityIgnores(ctx)...)
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"context": ctx, "ignores": rules})
	})
	s.mux.HandleFunc("PUT /api/settings/security-ignores", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Context string                `json:"context"`
			Ignores []security.IgnoreRule `json:"ignores"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil || len(body.Ignores) > maxSecurityIgnores {
			writeErr(w, httpx.BadRequest("body must be {context?, ignores: [{check, namespace?, kind?, name?, reason?, at?, by?}]}"))
			return
		}
		if err := checkIgnoreRules(body.Ignores); err != nil {
			writeErr(w, err)
			return
		}
		ctx := body.Context
		if ctx == "" {
			ctx = s.settingsContext(r)
		}
		if ctx == "" {
			writeErr(w, httpx.BadRequest("no context"))
			return
		}
		if err := s.settings.SetSecurityIgnores(ctx, body.Ignores); err != nil {
			writeErr(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	// POST adds rules to the current context's (a rule for the same target
	// replaces the old one). It's the one write the Claude Code token may
	// make (mcpAllowed); its rules are marked by "claude" so the Security
	// page can say who ignored what.
	s.mux.HandleFunc("POST /api/security/ignores", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Rules []security.IgnoreRule `json:"rules"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil || len(body.Rules) == 0 || len(body.Rules) > maxSecurityIgnores {
			writeErr(w, httpx.BadRequest("body must be {rules: [{check, namespace?, kind?, name?, reason?}]} with at least one rule"))
			return
		}
		if err := checkIgnoreRules(body.Rules); err != nil {
			writeErr(w, err)
			return
		}
		viaMCP := fromMCP(r.Context())
		for i := range body.Rules {
			if viaMCP {
				body.Rules[i].By = "claude"
			}
		}
		ctx := s.settingsContext(r)
		if ctx == "" {
			writeErr(w, httpx.BadRequest("no context"))
			return
		}
		rules := s.settings.SecurityIgnores(ctx)
		for _, add := range body.Rules {
			rules = slices.DeleteFunc(rules, add.SameTarget)
			rules = append(rules, add)
		}
		if len(rules) > maxSecurityIgnores {
			writeErr(w, httpx.BadRequest("at most %d ignore rules", maxSecurityIgnores))
			return
		}
		if err := s.settings.SetSecurityIgnores(ctx, rules); err != nil {
			writeErr(w, err)
			return
		}
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"context": ctx, "added": body.Rules})
	})
}

// checkIgnoreRules validates rules and stamps the missing times.
func checkIgnoreRules(rules []security.IgnoreRule) error {
	now := time.Now().UTC().Format(time.RFC3339)
	for i := range rules {
		g := &rules[i]
		if g.Check == "" || (g.Kind == "") != (g.Name == "") {
			return httpx.BadRequest("a rule needs a check, and kind and name together")
		}
		if len(g.Check) > 100 || len(g.Namespace) > 253 || len(g.Kind) > 253 || len(g.Name) > 253 || len(g.Reason) > 1000 || len(g.By) > 40 {
			return httpx.BadRequest("a rule field is too long")
		}
		if g.At == "" {
			g.At = now
		}
	}
	return nil
}

type mcpKey struct{}

// fromMCP reports whether the request carried the Claude Code token.
func fromMCP(ctx context.Context) bool { v, _ := ctx.Value(mcpKey{}).(bool); return v }
