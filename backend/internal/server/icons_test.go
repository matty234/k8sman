package server

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/settings"
)

func iconServer(t *testing.T, contextName, host string, opts Options) *Server {
	t.Helper()
	dir := t.TempDir()
	kc := filepath.Join(dir, "config")
	cfg := fmt.Sprintf("apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster:\n    server: %s\nusers:\n- name: u\n  user:\n    token: x\ncontexts:\n- name: %s\n  context:\n    cluster: c\n    user: u\ncurrent-context: %s\n", host, contextName, contextName)
	if err := os.WriteFile(kc, []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	mgr, err := cluster.NewManager(kc, "")
	if err != nil {
		t.Fatal(err)
	}
	store, _ := columns.OpenStore(filepath.Join(dir, "columns.json"))
	if opts.Settings == nil {
		opts.Settings, _ = settings.Open(filepath.Join(dir, "settings.json"))
	}
	opts.AuthToken = testToken
	return New(mgr, store, nil, opts)
}

func TestRemoteIconsPolicy(t *testing.T) {
	yes, no := true, false
	cases := []struct {
		name, ctx, host string
		flagOff         bool
		setting         *bool
		want            bool
	}{
		{"local kind cluster", "kind-dev", "https://10.0.0.5:6443", false, nil, true},
		{"loopback API server", "dev", "https://127.0.0.1:6443", false, nil, true},
		{"remote cluster", "prod", "https://203.0.113.10:6443", false, nil, false},
		{"setting enables remote", "prod", "https://203.0.113.10:6443", false, &yes, true},
		{"setting disables local", "kind-dev", "https://127.0.0.1:6443", false, &no, false},
		{"flag beats setting", "kind-dev", "https://127.0.0.1:6443", true, &yes, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			st, _ := settings.Open(filepath.Join(t.TempDir(), "settings.json"))
			if c.setting != nil {
				_ = st.Update(func(s *settings.Settings) { s.RemoteIcons = c.setting })
			}
			s := iconServer(t, c.ctx, c.host, Options{Settings: st, NoRemoteIcons: c.flagOff})
			if got := s.remoteIcons(c.flagOff); got != c.want {
				t.Errorf("remoteIcons = %v, want %v", got, c.want)
			}
		})
	}
}

func TestIconEndpointRejectsBadGroups(t *testing.T) {
	s := iconServer(t, "prod", "https://203.0.113.10:6443", Options{IconCacheDir: t.TempDir()})
	for _, g := range []string{"Bad_Group", "-x.io", "a..b"} {
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, localRequest(http.MethodGet, "/api/icons/"+g, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: status %d", g, rec.Code)
		}
	}
}
