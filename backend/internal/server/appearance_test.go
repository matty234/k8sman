package server

import (
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// A context's badge is saved per context, validated, allowed on a
// read-only (production-looking) context, and forgotten when emptied.
func TestContextAppearance(t *testing.T) {
	kc := writeKubeconfig(t, filepath.Join(t.TempDir(), "config"), "prod-eu", "dev")
	mgr, err := cluster.NewManager(kc, "")
	if err != nil {
		t.Fatal(err)
	}
	s, _, _ := newTestServer(t, mgr)
	type got struct {
		Icon, Color string
		All         map[string]map[string]string
	}
	get := func(q string) (c got) {
		rec, _ := do(t, s, "GET", "/api/settings/context-appearance"+q, "")
		_ = json.Unmarshal(rec.Body.Bytes(), &c)
		return
	}
	// prod-eu is read-only, yet the badge can be set.
	if rec, _ := do(t, s, "PUT", "/api/settings/context-appearance", `{"icon":"rocket_launch","color":"red"}`); rec.Code != 204 {
		t.Fatalf("save: %d %s", rec.Code, rec.Body)
	}
	do(t, s, "PUT", "/api/settings/context-appearance", `{"context":"dev","icon":"text:EU","color":"#12abEF"}`)
	for _, bad := range []string{`{"icon":"Not An Id"}`, `{"icon":"text:ABC"}`, `{"color":"#12"}`} {
		if rec, _ := do(t, s, "PUT", "/api/settings/context-appearance", bad); rec.Code != 400 {
			t.Fatalf("%s: %d, want 400", bad, rec.Code)
		}
	}
	if c := get(""); c.Icon != "rocket_launch" || c.Color != "red" || len(c.All) != 2 {
		t.Fatalf("current: %+v", c)
	}
	if c := get("?context=dev"); c.Icon != "text:EU" || c.Color != "#12abEF" {
		t.Fatalf("dev: %+v", c)
	}
	do(t, s, "PUT", "/api/settings/context-appearance", `{"context":"dev","icon":"","color":""}`)
	if c := get(""); len(c.All) != 1 {
		t.Fatalf("after reset: %+v", c)
	}
}
