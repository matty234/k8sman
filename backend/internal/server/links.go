package server

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"unicode"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Shareable-link settings: which form "Copy link" produces (the
// https://k8sman.dev/o/ page by default, or the raw k8sman:// URL) and the
// remembered cluster mappings. App settings, like the sidebar layout.
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

	// Remembered "open links for this cluster here" choices: cluster
	// fingerprint (from a link's c=) → local context name.
	s.mux.HandleFunc("GET /api/settings/link-clusters", func(w http.ResponseWriter, r *http.Request) {
		m := s.settings.Get().LinkClusterMap
		if m == nil {
			m = map[string]string{}
		}
		httpx.WriteJSON(w, 200, map[string]any{"linkClusterMap": m})
	})
	s.mux.HandleFunc("PUT /api/settings/link-clusters", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Fingerprint string `json:"fingerprint"`
			Context     string `json:"context"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeErr(w, httpx.BadRequest("body must be {\"fingerprint\": string, \"context\": string}: %v", err))
			return
		}
		if !fingerprintRE.MatchString(body.Fingerprint) {
			writeErr(w, httpx.BadRequest("fingerprint must be 12 lowercase hex characters"))
			return
		}
		if len(body.Context) > 253 || strings.IndexFunc(body.Context, unicode.IsControl) >= 0 {
			writeErr(w, httpx.BadRequest("invalid context name"))
			return
		}
		if err := s.settings.Update(func(st *settings.Settings) {
			if body.Context == "" {
				delete(st.LinkClusterMap, body.Fingerprint)
				return
			}
			if st.LinkClusterMap == nil {
				st.LinkClusterMap = map[string]string{}
			}
			st.LinkClusterMap[body.Fingerprint] = body.Context
		}); err != nil {
			writeErr(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}

var fingerprintRE = regexp.MustCompile(`^[0-9a-f]{12}$`)

// The log viewer's "Newest first" preference, applied to every log view.
func (s *Server) logSettingsRoutes() {
	s.mux.HandleFunc("GET /api/settings/logs", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, 200, map[string]any{"newestFirst": s.settings.Get().LogsNewestFirst, "colourSyntax": !s.settings.Get().LogsPlainSyntax})
	})
	s.mux.HandleFunc("PUT /api/settings/logs", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			NewestFirst  *bool `json:"newestFirst"`
			ColourSyntax *bool `json:"colourSyntax"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeErr(w, httpx.BadRequest("body must be {\"newestFirst\"?: bool, \"colourSyntax\"?: bool}: %v", err))
			return
		}
		if err := s.settings.Update(func(st *settings.Settings) {
			if body.NewestFirst != nil {
				st.LogsNewestFirst = *body.NewestFirst
			}
			if body.ColourSyntax != nil {
				st.LogsPlainSyntax = !*body.ColourSyntax
			}
		}); err != nil {
			writeErr(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}

// The widths the window's side panels were dragged to (the left nav and the
// right inspector), restored at launch. 0 = the default.
func (s *Server) panelSettingsRoutes() {
	s.mux.HandleFunc("GET /api/settings/panels", func(w http.ResponseWriter, r *http.Request) {
		st := s.settings.Get()
		httpx.WriteJSON(w, 200, map[string]any{"navWidth": st.NavWidth, "inspectorWidth": st.InspectorWidth})
	})
	s.mux.HandleFunc("PUT /api/settings/panels", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			NavWidth       *float64 `json:"navWidth"`
			InspectorWidth *float64 `json:"inspectorWidth"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeErr(w, httpx.BadRequest("body must be {\"navWidth\"?: number, \"inspectorWidth\"?: number}: %v", err))
			return
		}
		for _, v := range []*float64{body.NavWidth, body.InspectorWidth} {
			if v != nil && (*v < 0 || *v > 10000) {
				writeErr(w, httpx.BadRequest("widths must be between 0 and 10000"))
				return
			}
		}
		if err := s.settings.Update(func(st *settings.Settings) {
			if body.NavWidth != nil {
				st.NavWidth = *body.NavWidth
			}
			if body.InspectorWidth != nil {
				st.InspectorWidth = *body.InspectorWidth
			}
		}); err != nil {
			writeErr(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
