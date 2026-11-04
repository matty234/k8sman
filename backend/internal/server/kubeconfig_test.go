package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/portforward"
	"github.com/matty234/k8sman/backend/internal/settings"
)

func writeKubeconfig(t *testing.T, path string, contexts ...string) string {
	t.Helper()
	var b strings.Builder
	b.WriteString("apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster:\n    server: https://127.0.0.1:1\nusers:\n- name: u\n  user:\n    token: x\ncontexts:\n")
	for _, c := range contexts {
		fmt.Fprintf(&b, "- name: %s\n  context:\n    cluster: c\n    user: u\n", c)
	}
	fmt.Fprintf(&b, "current-context: %s\n", contexts[0])
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

type kcResponse struct {
	Current    string                   `json:"current"`
	Context    string                   `json:"context"`
	Error      string                   `json:"error"`
	Candidates []cluster.KubeconfigInfo `json:"candidates"`
}

func newTestServer(t *testing.T, mgr *cluster.Manager) (*Server, *settings.Store, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("KUBECONFIG", "")
	st, err := settings.Open(filepath.Join(home, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	store, err := columns.OpenStore(filepath.Join(home, "columns.json"))
	if err != nil {
		t.Fatal(err)
	}
	pf, err := portforward.NewManager(mgr, filepath.Join(home, "pf.json"))
	if err != nil {
		t.Fatal(err)
	}
	return New(mgr, store, pf, Options{Settings: st, AuthToken: testToken}), st, home
}

func do(t *testing.T, s *Server, method, path, body string) (*httptest.ResponseRecorder, kcResponse) {
	t.Helper()
	req := localRequest(method, path, strings.NewReader(body))
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	var out kcResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec, out
}

func TestKubeconfigEndpoints(t *testing.T) {
	dir := t.TempDir()
	first := writeKubeconfig(t, filepath.Join(dir, "first"), "f1")
	mgr, err := cluster.NewManager(first, "")
	if err != nil {
		t.Fatal(err)
	}
	s, st, home := newTestServer(t, mgr)
	second := writeKubeconfig(t, filepath.Join(home, ".kube", "second"), "s1", "s2")

	rec, got := do(t, s, "GET", "/api/kubeconfigs", "")
	if rec.Code != 200 || got.Current != first || got.Context != "f1" {
		t.Fatalf("list: %d %s", rec.Code, rec.Body)
	}
	var paths []string
	for _, c := range got.Candidates {
		paths = append(paths, c.Path)
	}
	if strings.Join(paths, ",") != second+","+first {
		t.Fatalf("candidates %v", paths)
	}

	// Switching remembers the file and its context; a context switch after
	// that is remembered per file.
	rec, got = do(t, s, "POST", "/api/kubeconfigs/current", `{"path":"~/.kube/second"}`)
	if rec.Code != 200 || got.Current != second || got.Context != "s1" {
		t.Fatalf("switch: %d %s", rec.Code, rec.Body)
	}
	if rec, _ := do(t, s, "POST", "/api/contexts/current", `{"name":"s2"}`); rec.Code != 200 {
		t.Fatalf("switch context: %d %s", rec.Code, rec.Body)
	}
	if rec, _ = do(t, s, "POST", "/api/kubeconfigs/current", `{"path":"`+first+`"}`); rec.Code != 200 {
		t.Fatal(rec.Body)
	}
	_, got = do(t, s, "POST", "/api/kubeconfigs/current", `{"path":"`+second+`"}`)
	if got.Context != "s2" {
		t.Fatalf("last context not restored: %+v", got)
	}
	saved := st.Get()
	if saved.Kubeconfig != second || saved.LastContext[second] != "s2" || saved.LastContext[first] != "f1" || saved.RecentKubeconfigs[0] != second {
		t.Fatalf("settings %+v", saved)
	}

	for _, body := range []string{`{}`, `{"path":"relative"}`, `{"path":"/does/not/exist"}`} {
		if rec, _ := do(t, s, "POST", "/api/kubeconfigs/current", body); rec.Code != 400 {
			t.Fatalf("%s: want 400, got %d", body, rec.Code)
		}
	}
	if mgr.Kubeconfig() != second {
		t.Fatal("failed switch changed kubeconfig")
	}
}

func TestDisconnectedServer(t *testing.T) {
	mgr := cluster.NewDisconnected("/nope", errors.New("no kubeconfig"))
	s, _, home := newTestServer(t, mgr)

	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, localRequest("GET", "/api/health", nil))
	var h map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &h)
	if rec.Code != 200 || h["connected"] != false {
		t.Fatalf("health: %d %s", rec.Code, rec.Body)
	}
	if rec, _ := do(t, s, "GET", "/api/resources", ""); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("resources: want 503, got %d", rec.Code)
	}
	if rec, _ := do(t, s, "GET", "/api/portforwards", ""); rec.Code != 200 {
		t.Fatalf("portforwards: %d", rec.Code)
	}
	if rec, _ := do(t, s, "POST", "/api/portforwards", `{"namespace":"a","kind":"pod","name":"b","port":"80"}`); rec.Code != 400 {
		t.Fatalf("create forward while disconnected: %d %s", rec.Code, rec.Body)
	}
	// The sidebar layout is editable without a cluster.
	if rec, _ := do(t, s, "PUT", "/api/settings/sidebar", `{"items":[{"view":"overview"},{"group":"apps","kind":"Deployment"}]}`); rec.Code != 200 {
		t.Fatalf("put sidebar: %d %s", rec.Code, rec.Body)
	}
	if rec, _ := do(t, s, "GET", "/api/settings/sidebar", ""); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"kind":"Deployment"`) {
		t.Fatalf("get sidebar: %d %s", rec.Code, rec.Body)
	}
	if rec, _ := do(t, s, "PUT", "/api/settings/sidebar", `{"items":[{"view":"overview","kind":"Pod"}]}`); rec.Code != 400 {
		t.Fatalf("invalid sidebar: want 400, got %d", rec.Code)
	}
	if rec, _ := do(t, s, "DELETE", "/api/settings/sidebar", ""); rec.Code != 204 {
		t.Fatalf("reset sidebar: %d", rec.Code)
	}
	if rec, _ := do(t, s, "GET", "/api/settings/sidebar", ""); !strings.Contains(rec.Body.String(), `"sidebar":null`) {
		t.Fatalf("after reset: %s", rec.Body)
	}
	kc := writeKubeconfig(t, filepath.Join(home, "kc"), "x")
	if rec, got := do(t, s, "POST", "/api/kubeconfigs/current", `{"path":"`+kc+`"}`); rec.Code != 200 || got.Context != "x" {
		t.Fatalf("connect: %d %s", rec.Code, rec.Body)
	}
}
