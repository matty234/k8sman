package server

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/mcpserver"
)

// Turning Claude Code access on advertises a token that can only read
// (never Secrets); turning it off removes the file and revokes the token.
func TestClaudeCodeAccess(t *testing.T) {
	mgr, err := cluster.NewManager(writeKubeconfig(t, filepath.Join(t.TempDir(), "config"), "dev"), "")
	if err != nil {
		t.Fatal(err)
	}
	s, _, home := newTestServer(t, mgr)
	s.listenAddr, s.mcpPath = "127.0.0.1:7443", filepath.Join(home, "mcp.json")

	if rec, _ := do(t, s, "PUT", "/api/settings/mcp", `{"enabled":true}`); rec.Code != 200 || !strings.Contains(rec.Body.String(), " mcp") {
		t.Fatalf("enable: %d %s", rec.Code, rec.Body)
	}
	d, err := mcpserver.ReadDiscovery(s.mcpPath)
	if err != nil || d.Addr != s.listenAddr {
		t.Fatalf("discovery: %+v %v", d, err)
	}
	asMCP := func(method, path string) int {
		req := localRequest(method, path, strings.NewReader(`{"enabled":true}`))
		req.Header.Set("Authorization", "Bearer "+d.Token)
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		return rec.Code
	}
	for path, want := range map[string]int{
		"GET /api/health": 200,
		"GET /api/object?group=&version=v1&resource=secrets&namespace=default&name=x": http.StatusForbidden,
		"PUT /api/settings/mcp":           http.StatusForbidden,
		"GET /api/exec?namespace=a&pod=b": http.StatusForbidden,
	} {
		m, p, _ := strings.Cut(path, " ")
		if got := asMCP(m, p); got != want {
			t.Errorf("%s: %d, want %d", path, got, want)
		}
	}

	// Its one write: ignoring a Security finding, marked as Claude's.
	req := localRequest("POST", "/api/security/ignores", strings.NewReader(`{"rules":[{"check":"privileged","kind":"Pod","name":"p","namespace":"a","by":"me"}]}`))
	req.Header.Set("Authorization", "Bearer "+d.Token)
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	if got := s.settings.SecurityIgnores("dev"); rec.Code != 200 || len(got) != 1 || got[0].By != "claude" || got[0].At == "" {
		t.Fatalf("ignore via MCP: %d %s %+v", rec.Code, rec.Body, got)
	}

	if rec, _ := do(t, s, "PUT", "/api/settings/mcp", `{"enabled":false}`); rec.Code != 200 {
		t.Fatalf("disable: %d %s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(s.mcpPath); !os.IsNotExist(err) {
		t.Fatalf("mcp.json still there: %v", err)
	}
	if got := asMCP("GET", "/api/health"); got != http.StatusUnauthorized {
		t.Fatalf("revoked token: %d", got)
	}
}
