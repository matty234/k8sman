package server

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

func TestClusterFingerprintAndLinkMappings(t *testing.T) {
	// Spellings of one API server share a fingerprint.
	same := []string{
		"https://prod.example.com/k8s/clusters/c-1",
		"HTTPS://Prod.Example.COM:443/k8s/clusters/c-1/",
		"prod.example.com/k8s/clusters/c-1",
	}
	if n := cluster.NormalizeServer(same[1]); n != "https://prod.example.com/k8s/clusters/c-1" {
		t.Fatalf("normalised: %q", n)
	}
	fp := cluster.Fingerprint(same[0])
	if len(fp) != 12 || strings.Trim(fp, "0123456789abcdef") != "" {
		t.Fatalf("fingerprint %q", fp)
	}
	for _, s := range same[1:] {
		if got := cluster.Fingerprint(s); got != fp {
			t.Errorf("%s: %s, want %s", s, got, fp)
		}
	}
	// Another port, scheme, host or path (case kept) is another cluster.
	for _, s := range []string{
		"https://prod.example.com:6443/k8s/clusters/c-1",
		"http://prod.example.com/k8s/clusters/c-1",
		"https://prod.example.com/k8s/clusters/c-2",
		"https://prod.example.com/k8s/clusters/C-1",
		"https://prod.example.com",
	} {
		if cluster.Fingerprint(s) == fp {
			t.Errorf("%s matched", s)
		}
	}
	if cluster.Fingerprint("") != "" {
		t.Error("no server should have no fingerprint")
	}

	// Remembered mappings: set, reject bad input, list, remove.
	kc := writeKubeconfig(t, filepath.Join(t.TempDir(), "config"), "dev")
	mgr, err := cluster.NewManager(kc, "")
	if err != nil {
		t.Fatal(err)
	}
	s, st, _ := newTestServer(t, mgr)
	if rec, _ := do(t, s, "GET", "/api/contexts", ""); !strings.Contains(rec.Body.String(), `"fingerprint":"`+cluster.Fingerprint("https://127.0.0.1:1")+`"`) {
		t.Fatalf("contexts: %s", rec.Body)
	}
	if rec, _ := do(t, s, "PUT", "/api/settings/link-clusters", `{"fingerprint":"`+fp+`","context":"dev"}`); rec.Code != 204 || st.Get().LinkClusterMap[fp] != "dev" {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}
	for _, bad := range []string{`{"fingerprint":"ABCDEF012345","context":"dev"}`, `{"fingerprint":"abc","context":"dev"}`, `{"fingerprint":"` + fp + `","context":"a\nb"}`} {
		if rec, _ := do(t, s, "PUT", "/api/settings/link-clusters", bad); rec.Code != 400 {
			t.Errorf("%s: %d", bad, rec.Code)
		}
	}
	if rec, _ := do(t, s, "GET", "/api/settings/link-clusters", ""); !strings.Contains(rec.Body.String(), `"linkClusterMap":{"`+fp+`":"dev"}`) {
		t.Fatalf("get: %s", rec.Body)
	}
	do(t, s, "PUT", "/api/settings/link-clusters", `{"fingerprint":"`+fp+`","context":""}`)
	if len(st.Get().LinkClusterMap) != 0 {
		t.Fatal("empty context should remove the mapping")
	}
}
