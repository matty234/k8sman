package argoapi

import (
	"bytes"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/matty234/k8sman/backend/internal/settings"
)

// A settings.json from before the module settings keeps working: the token
// and the CLI choice move to moduleSettings.argocd[context], the old fields
// are dropped from the file, a context that already has new settings keeps
// them, and nothing prints the token.
func TestLegacyArgoCDSettingsMigrate(t *testing.T) {
	const secret = "legacy-token-SECRET"
	path := filepath.Join(t.TempDir(), "settings.json")
	legacy := `{"argocdTokens":{"dev":"` + secret + `","both":"old-ignored"},"argocdUseCli":{"sso":true,"both":true},` +
		`"moduleSettings":{"argocd":{"both":{"token":"new-wins"}}}}`
	if err := os.WriteFile(path, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	var logged bytes.Buffer
	log.SetOutput(&logged)
	defer log.SetOutput(os.Stderr)

	st, err := settings.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	tokens := moduleTokens{st}
	if tokens.ArgoCDToken("dev") != secret || tokens.ArgoCDUseCLI("dev") {
		t.Fatalf("dev: token %q", tokens.ArgoCDToken("dev"))
	}
	if tokens.ArgoCDToken("sso") != "" || !tokens.ArgoCDUseCLI("sso") {
		t.Fatal("sso: the CLI choice should have moved")
	}
	if tokens.ArgoCDToken("both") != "new-wins" || tokens.ArgoCDUseCLI("both") {
		t.Fatal("existing module settings must win over the legacy fields")
	}
	// Reopening reads what was written: new fields only.
	b, _ := os.ReadFile(path)
	if strings.Contains(string(b), "argocdTokens") || strings.Contains(string(b), "argocdUseCli") {
		t.Fatalf("legacy fields still in the file: %s", b)
	}
	again, _ := settings.Open(path)
	if (moduleTokens{again}).ArgoCDToken("dev") != secret {
		t.Fatal("token lost after reopening")
	}
	// The API shows that a token is set, never the token.
	if r := string(RedactSettings(st.RawModuleSettings(SettingsID, "dev"))); strings.Contains(r, secret) || !strings.Contains(r, `"tokenSet":true`) {
		t.Fatalf("redacted: %s", r)
	}
	if strings.Contains(logged.String(), secret) {
		t.Fatalf("token was logged: %s", logged.String())
	}
}
