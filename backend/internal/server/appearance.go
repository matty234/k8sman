package server

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// The icon and colour a user picked for a context's badge. Local settings
// only, so it works in read-only mode.
func (s *Server) appearanceRoutes() {
	s.mux.HandleFunc("GET /api/settings/context-appearance", s.handleGetAppearance)
	s.mux.HandleFunc("PUT /api/settings/context-appearance", s.handlePutAppearance)
}

var (
	appearanceIconID  = regexp.MustCompile(`^[a-z0-9_]{1,32}$`)
	appearanceColorID = regexp.MustCompile(`^([a-z]{1,16}|#[0-9a-fA-F]{6})$`)
)

const maxAppearances = 500

func validAppearance(a settings.Appearance) bool {
	if m, ok := strings.CutPrefix(a.Icon, "text:"); ok {
		if n := utf8.RuneCountInString(m); n < 1 || n > 2 || !utf8.ValidString(m) {
			return false
		}
		for _, r := range m {
			if r < ' ' || r == 0x7f {
				return false
			}
		}
	} else if a.Icon != "" && !appearanceIconID.MatchString(a.Icon) {
		return false
	}
	return a.Color == "" || appearanceColorID.MatchString(a.Color)
}

// handleGetAppearance returns {context, icon, color, all}: the badge of
// ?context= (default: the current one) and every saved badge by context.
func (s *Server) handleGetAppearance(w http.ResponseWriter, r *http.Request) {
	ctx := s.settingsContext(r)
	all := map[string]settings.Appearance{}
	if s.settings != nil {
		if saved := s.settings.Get().ContextAppearance; saved != nil {
			all = saved
		}
	}
	a := all[ctx]
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"context": ctx, "icon": a.Icon, "color": a.Color, "all": all})
}

// handlePutAppearance saves a context's badge.
// Body: {"context"?: "<name>", "icon": "<id>" | "text:PR", "color": "<id>" | "#rrggbb"};
// both empty forgets it. 204.
func (s *Server) handlePutAppearance(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Context string `json:"context"`
		Icon    string `json:"icon"`
		Color   string `json:"color"`
	}
	bad := func(msg string) {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorBody{Error: msg, Code: http.StatusBadRequest})
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&body); err != nil {
		bad("body must be {context?, icon, color}")
		return
	}
	a := settings.Appearance{Icon: body.Icon, Color: body.Color}
	if !validAppearance(a) {
		bad("not an icon or colour id")
		return
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
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorBody{Error: "settings are not available", Code: http.StatusServiceUnavailable})
		return
	}
	if saved := s.settings.Get().ContextAppearance; len(saved) >= maxAppearances {
		if _, known := saved[ctx]; !known {
			bad("too many contexts")
			return
		}
	}
	if err := s.settings.SetContextAppearance(ctx, a); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
