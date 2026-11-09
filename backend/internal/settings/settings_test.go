package settings

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "settings.json")
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < MaxRecent+3; i++ {
		if err := st.UseKubeconfig(filepath.Join("/k", string(rune('a'+i)))); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.UseKubeconfig("/k/c"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetLastContext("/k/c", "prod"); err != nil {
		t.Fatal(err)
	}

	again, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s := again.Get()
	if s.Kubeconfig != "/k/c" || s.LastContext["/k/c"] != "prod" {
		t.Fatalf("got %+v", s)
	}
	if len(s.RecentKubeconfigs) != MaxRecent || s.RecentKubeconfigs[0] != "/k/c" {
		t.Fatalf("recent %v", s.RecentKubeconfigs)
	}
	if strings.Count(strings.Join(s.RecentKubeconfigs, ","), "/k/c") != 1 {
		t.Fatalf("duplicate recent: %v", s.RecentKubeconfigs)
	}
	// Get returns a copy.
	s.LastContext["/k/c"] = "changed"
	if again.Get().LastContext["/k/c"] != "prod" {
		t.Fatal("Get must not alias internal state")
	}
}

func TestCorruptFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	_ = os.WriteFile(path, []byte("{nope"), 0o600)
	st, err := Open(path)
	if err == nil || st == nil {
		t.Fatal("expected usable store and an error")
	}
	if err := st.SetLastContext("/x", "y"); err != nil {
		t.Fatal(err)
	}
	if again, err := Open(path); err != nil || again.Get().LastContext["/x"] != "y" {
		t.Fatalf("rewrite failed: %v", err)
	}
}

func TestAutoReadOnly(t *testing.T) {
	for name, want := range map[string]bool{
		"prod": true, "prod-eu": true, "gke_acme_europe-west1_prod": true, "Production": true, "eks-prd-1": true,
		"dev": false, "kind-k8sman-dev": false, "product-api": false, "staging": false, "reproducible": false,
	} {
		if got := AutoReadOnly(name); got != want {
			t.Errorf("AutoReadOnly(%q) = %v, want %v", name, got, want)
		}
	}
}
