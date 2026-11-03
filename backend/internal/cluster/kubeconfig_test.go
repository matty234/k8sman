package cluster

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeKubeconfig writes a kubeconfig with the given contexts (the first is
// current) pointing at an unreachable server; building clients never dials.
func writeKubeconfig(t *testing.T, path string, contexts ...string) string {
	t.Helper()
	var b strings.Builder
	b.WriteString("apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster:\n    server: https://127.0.0.1:1\n    insecure-skip-tls-verify: true\nusers:\n- name: u\n  user:\n    token: x\ncontexts:\n")
	for _, c := range contexts {
		fmt.Fprintf(&b, "- name: %s\n  context:\n    cluster: c\n    user: u\n    namespace: ns-%s\n", c, c)
	}
	if len(contexts) > 0 {
		fmt.Fprintf(&b, "current-context: %s\n", contexts[0])
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestInspectKubeconfig(t *testing.T) {
	dir := t.TempDir()
	good := writeKubeconfig(t, filepath.Join(dir, "good"), "b", "a")
	info := InspectKubeconfig(good)
	if info.Error != "" || strings.Join(info.Contexts, ",") != "a,b" || info.CurrentContext != "b" {
		t.Fatalf("unexpected %+v", info)
	}
	if info := InspectKubeconfig(filepath.Join(dir, "missing")); info.Error == "" {
		t.Fatal("missing file should report an error")
	}
	bad := filepath.Join(dir, "bad")
	_ = os.WriteFile(bad, []byte("{{{ not yaml"), 0o600)
	if info := InspectKubeconfig(bad); info.Error == "" {
		t.Fatal("invalid file should report an error")
	}
}

func TestDiscoverKubeconfigs(t *testing.T) {
	home := t.TempDir()
	kube := filepath.Join(home, ".kube")
	writeKubeconfig(t, filepath.Join(kube, "config"), "main")
	writeKubeconfig(t, filepath.Join(kube, "staging.yaml"), "stg1", "stg2")
	writeKubeconfig(t, filepath.Join(kube, "teams", "dev"), "dev")
	writeKubeconfig(t, filepath.Join(kube, "cache", "discovery"), "nope")
	writeKubeconfig(t, filepath.Join(kube, "http-cache", "x"), "nope")
	writeKubeconfig(t, filepath.Join(kube, "teams", "deep", "x"), "nope")
	_ = os.WriteFile(filepath.Join(kube, "notes.txt"), []byte("hello"), 0o600)
	envFile := writeKubeconfig(t, filepath.Join(home, "elsewhere", "env-config"), "env")
	recent := writeKubeconfig(t, filepath.Join(home, "proj", "kc"), "proj")

	got := DiscoverKubeconfigs(home, envFile, []string{recent, filepath.Join(kube, "config"), filepath.Join(home, "gone")})
	var paths []string
	for _, c := range got {
		rel, _ := filepath.Rel(home, c.Path)
		paths = append(paths, rel+"="+c.Source)
	}
	want := []string{
		"elsewhere/env-config=KUBECONFIG",
		".kube/config=default",
		".kube/staging.yaml=kube-dir",
		".kube/teams/dev=kube-dir",
		"proj/kc=recent",
		"gone=recent",
	}
	if strings.Join(paths, " ") != strings.Join(want, " ") {
		t.Fatalf("candidates:\n got  %v\n want %v", paths, want)
	}
	if got[2].Error != "" || len(got[2].Contexts) != 2 {
		t.Fatalf("staging: %+v", got[2])
	}
	if got[5].Error == "" {
		t.Fatal("missing recent file should carry an error")
	}
}

func TestDefaultKubeconfig(t *testing.T) {
	if got := DefaultKubeconfig("/h", ""); got != "/h/.kube/config" {
		t.Fatal(got)
	}
	if got := DefaultKubeconfig("/h", "/a"); got != "/a" {
		t.Fatal(got)
	}
	if got := DefaultKubeconfig("/h", "/a"+string(os.PathListSeparator)+"/b"); got != "" {
		t.Fatal(got)
	}
}

func TestSwitchKubeconfig(t *testing.T) {
	dir := t.TempDir()
	one := writeKubeconfig(t, filepath.Join(dir, "one"), "one-a", "one-b")
	two := writeKubeconfig(t, filepath.Join(dir, "two"), "two-a", "two-b")

	m, err := NewManager(one, "")
	if err != nil {
		t.Fatal(err)
	}
	if c := m.Clients(); c.Context != "one-a" || c.Namespace != "ns-one-a" {
		t.Fatalf("initial %s/%s", c.Context, c.Namespace)
	}
	oneB, err := m.ClientsFor("one-b")
	if err != nil {
		t.Fatal(err)
	}

	// Remembered context wins over current-context.
	if err := m.SwitchKubeconfig(two, "two-b"); err != nil {
		t.Fatal(err)
	}
	if m.Kubeconfig() != two || m.Clients().Context != "two-b" {
		t.Fatalf("after switch: %s %s", m.Kubeconfig(), m.Clients().Context)
	}
	cur, ctxs, err := m.Contexts()
	if err != nil || cur != "two-b" || len(ctxs) != 2 || ctxs[0].Name != "two-a" {
		t.Fatalf("contexts %s %+v %v", cur, ctxs, err)
	}
	// Unknown remembered context falls back to the file's current-context.
	if err := m.SwitchKubeconfig(one, "gone"); err != nil || m.Clients().Context != "one-a" {
		t.Fatalf("fallback: %v %s", err, m.Clients().Context)
	}
	// Caches were cleared on switch.
	again, err := m.ClientsIn(one, "one-b")
	if err != nil || again == oneB {
		t.Fatalf("cache not cleared: %v", err)
	}
	// Forwards created under another kubeconfig still resolve.
	if c, err := m.ClientsIn(two, "two-a"); err != nil || c.Context != "two-a" {
		t.Fatalf("ClientsIn other file: %v", err)
	}
	if _, err := m.ClientsIn(two, "one-a"); err == nil {
		t.Fatal("context from another file must not resolve")
	}

	bad := filepath.Join(dir, "bad")
	_ = os.WriteFile(bad, []byte("kind: Config\napiVersion: v1\n"), 0o600)
	if err := m.SwitchKubeconfig(bad, ""); err == nil {
		t.Fatal("kubeconfig without contexts must be rejected")
	}
	if err := m.SwitchKubeconfig(filepath.Join(dir, "missing"), ""); err == nil {
		t.Fatal("missing kubeconfig must be rejected")
	}
	if m.Kubeconfig() != one {
		t.Fatal("failed switch must keep the previous kubeconfig")
	}
}

func TestDisconnected(t *testing.T) {
	dir := t.TempDir()
	m := NewDisconnected(filepath.Join(dir, "missing"), fmt.Errorf("boom"))
	if m.Clients() != nil || m.Err() == nil {
		t.Fatal("expected disconnected")
	}
	kc := writeKubeconfig(t, filepath.Join(dir, "kc"), "x")
	if err := m.SwitchKubeconfig(kc, ""); err != nil || m.Clients() == nil || m.Err() != nil {
		t.Fatalf("connect: %v", err)
	}
}
