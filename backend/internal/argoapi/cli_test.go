package argoapi

import (
	"os"
	"path/filepath"
	"testing"
)

const cliCfg = `contexts:
- name: lon
  server: argocd.example.internal
  user: lon
- name: other
  server: https://argocd.example.com:443
  user: other
- name: lon-old
  server: https://argocd.example.internal/
  user: lon-old
- name: nologin
  server: dev.example.com
  user: nologin
current-context: other
servers:
- server: argocd.example.internal
  grpc-web: true
users:
- name: lon
  auth-token: tok-lon
- name: other
  auth-token: tok-other
- name: lon-old
  auth-token: tok-lon-old
- name: nologin
  auth-token: ""
`

func writeCfg(t *testing.T, s string) string {
	p := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestHostOf(t *testing.T) {
	for in, want := range map[string]string{
		"https://ArgoCD.Example.Internal": "argocd.example.internal",
		"argocd.example.internal:443":     "argocd.example.internal",
		"https://h.example.com:8443/argo/":    "h.example.com",
		"":                                    "",
	} {
		if got := hostOf(in); got != want {
			t.Errorf("hostOf(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFindCLILoginMatchesStrictlyByHost(t *testing.T) {
	p := writeCfg(t, cliCfg)
	l, ok := findCLILogin(p, "argocd.example.internal")
	if !ok || l.token != "tok-lon" || l.Context != "lon" {
		t.Fatalf("got %+v ok=%v, want first matching context lon", l, ok)
	}
	// The current context wins when it matches.
	l, ok = findCLILogin(p, "argocd.example.com")
	if !ok || l.token != "tok-other" {
		t.Fatalf("got %+v ok=%v", l, ok)
	}
	// Never fall back to a login for a different Argo CD.
	if _, ok := findCLILogin(p, "unknown.example.com"); ok {
		t.Fatal("matched a login for a different host")
	}
	// No URL in argocd-cm: nothing can be matched safely.
	if _, ok := findCLILogin(p, ""); ok {
		t.Fatal("matched without a known Argo CD host")
	}
	// A context without a token is ignored.
	if _, ok := findCLILogin(p, "dev.example.com"); ok {
		t.Fatal("used a context with an empty token")
	}
	// Missing file.
	if _, ok := findCLILogin(filepath.Join(t.TempDir(), "nope"), "argocd.example.internal"); ok {
		t.Fatal("matched with no config file")
	}
}
