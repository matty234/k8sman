package server

import (
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"k8s.io/client-go/kubernetes/fake"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/settings"
)

func TestDisabledModuleRoutes404(t *testing.T) {
	dir := t.TempDir()
	st, _ := settings.Open(filepath.Join(dir, "settings.json"))
	store, _ := columns.OpenStore(filepath.Join(dir, "columns.json"))
	mgr := cluster.NewStatic(&cluster.Clients{Context: "kind-dev", Typed: fake.NewSimpleClientset()})
	s := New(mgr, store, nil, Options{Settings: st, AuthToken: testToken})
	do := func(method, path, body string) int {
		w := httptest.NewRecorder()
		s.ServeHTTP(w, localRequest(method, path, strings.NewReader(body)))
		return w.Code
	}
	// Without repo and chart this is a 400 that never touches the cluster.
	const helmRoute = "/api/helm/chart-versions"

	if code := do("GET", helmRoute, ""); code != 400 {
		t.Fatalf("enabled: %d, want 400", code)
	}
	if code := do("PUT", "/api/settings/modules", `{"disabled":["helm"]}`); code != 200 {
		t.Fatalf("PUT /api/settings/modules: %d", code)
	}
	if code := do("GET", helmRoute, ""); code != 404 {
		t.Errorf("disabled: %d, want 404", code)
	}
	do("PUT", "/api/settings/modules", `{"disabled":[]}`)
	if code := do("GET", helmRoute, ""); code != 400 {
		t.Errorf("enabled again: %d, want 400", code)
	}
}
