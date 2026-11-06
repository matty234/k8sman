package argoapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/matty234/k8sman/backend/internal/settings"
)

// SettingsID is the module id Argo CD's settings are saved under
// (settings.json moduleSettings.argocd[kube context]).
const SettingsID = "argocd"

// maxTokenLen bounds a pasted token (JWTs are well under 4 KiB).
const maxTokenLen = 8 << 10

// Settings is what is saved per kube context: an API token the user
// pasted, or the choice to use the argocd CLI's login (only the choice is
// stored; the token stays in the CLI's config). At most one is set. The
// file is written 0600; the token is never returned by the API or logged.
type Settings struct {
	Token  string `json:"token,omitempty"`
	UseCLI bool   `json:"useCli,omitempty"`
}

// settingsBody is a PUT body: Settings plus the read-only marker the UI
// gets back from GET (so a client may send what it read).
type settingsBody struct {
	Token    *string `json:"token"`
	UseCLI   *bool   `json:"useCli"`
	TokenSet *bool   `json:"tokenSet"`
}

func decodeBody(raw json.RawMessage) (settingsBody, error) {
	var b settingsBody
	if len(bytes.TrimSpace(raw)) == 0 {
		return b, nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		return b, fmt.Errorf("argocd settings: %w", err)
	}
	return b, nil
}

// ValidateSettings checks a settings object as saved (see Settings):
// known fields only, a token without whitespace and not longer than
// 8 KiB, and not both a token and the CLI login. The error never
// contains the token.
func ValidateSettings(raw json.RawMessage) error {
	b, err := decodeBody(raw)
	if err != nil {
		return err
	}
	if b.Token != nil {
		t := *b.Token
		switch {
		case len(t) > maxTokenLen:
			return fmt.Errorf("argocd settings: token is too long")
		case strings.ContainsAny(t, " \t\r\n"):
			return fmt.Errorf("argocd settings: token must not contain whitespace")
		}
	}
	if b.Token != nil && *b.Token != "" && b.UseCLI != nil && *b.UseCLI {
		return fmt.Errorf("argocd settings: use either a token or the argocd CLI login, not both")
	}
	return nil
}

// RedactSettings is what the UI may see of saved settings: whether a token
// is set, never the token.
func RedactSettings(raw json.RawMessage) json.RawMessage {
	var s Settings
	if json.Unmarshal(raw, &s) != nil {
		return json.RawMessage("{}")
	}
	out := map[string]any{}
	if s.UseCLI {
		out["useCli"] = true
	}
	if s.Token != "" {
		out["tokenSet"] = true
	}
	b, _ := json.Marshal(out)
	return b
}

// MergeSettings combines the saved settings with a PUT body, so the UI
// can change one thing without knowing the token: a field the body names
// replaces the saved one (token "" removes it; a pasted "Bearer " prefix
// is dropped), the others are kept, and choosing a token or the CLI login
// clears the other. An empty object clears everything.
func MergeSettings(saved, body json.RawMessage) (json.RawMessage, error) {
	b, err := decodeBody(body)
	if err != nil {
		return nil, err
	}
	if b.Token == nil && b.UseCLI == nil {
		return json.RawMessage("{}"), nil
	}
	var s Settings
	_ = json.Unmarshal(saved, &s)
	if b.Token != nil {
		s.Token = cleanToken(*b.Token)
		if s.Token != "" {
			s.UseCLI = false
		}
	}
	if b.UseCLI != nil {
		s.UseCLI = *b.UseCLI
		if s.UseCLI {
			s.Token = ""
		}
	}
	return json.Marshal(s)
}

// moduleTokens keeps the per-context auth choice in the settings store's
// module settings.
type moduleTokens struct{ st *settings.Store }

func (m moduleTokens) get(context string) Settings {
	var s Settings
	_, _ = m.st.ModuleSettings(SettingsID, context, &s)
	return s
}

func (m moduleTokens) update(context string, f func(*Settings)) error {
	return m.st.UpdateModuleSettings(SettingsID, context, func(saved json.RawMessage) (json.RawMessage, error) {
		var s Settings
		if len(saved) > 0 {
			_ = json.Unmarshal(saved, &s)
		}
		f(&s)
		return json.Marshal(s)
	})
}

// ArgoCDToken returns the token saved for a kube context ("" = none).
func (m moduleTokens) ArgoCDToken(context string) string { return m.get(context).Token }

// SetArgoCDToken saves (or, with an empty token, removes) the token.
func (m moduleTokens) SetArgoCDToken(context, token string) error {
	return m.update(context, func(s *Settings) { s.Token = token })
}

// ArgoCDUseCLI reports whether a kube context uses the argocd CLI's login.
func (m moduleTokens) ArgoCDUseCLI(context string) bool { return m.get(context).UseCLI }

// SetArgoCDUseCLI turns CLI-login auth on or off for a kube context.
func (m moduleTokens) SetArgoCDUseCLI(context string, on bool) error {
	return m.update(context, func(s *Settings) { s.UseCLI = on })
}
