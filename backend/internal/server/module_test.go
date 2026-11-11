package server

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
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

func TestHubbleAutoMode(t *testing.T) {
	relay := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: "hubble-relay", Namespace: "kube-system", Labels: map[string]string{"k8s-app": "hubble-relay"}}}
	newServer := func(settingsJSON string, objs ...runtime.Object) func(method, path, body string) int {
		dir := t.TempDir()
		if settingsJSON != "" {
			_ = os.WriteFile(filepath.Join(dir, "settings.json"), []byte(settingsJSON), 0o600)
		}
		st, _ := settings.Open(filepath.Join(dir, "settings.json"))
		store, _ := columns.OpenStore(filepath.Join(dir, "columns.json"))
		mgr := cluster.NewStatic(&cluster.Clients{Context: "kind-dev", Typed: fake.NewSimpleClientset(objs...)})
		s := New(mgr, store, nil, Options{Settings: st, AuthToken: testToken})
		return func(method, path, body string) int {
			w := httptest.NewRecorder()
			s.ServeHTTP(w, localRequest(method, path, strings.NewReader(body)))
			return w.Code
		}
	}
	// Without from and to this is a 400 that never touches the cluster.
	const route = "/api/hubble/connectivity"

	// Default is auto: inactive without Hubble (the status still answers),
	// explicit on activates it, explicit off wins over on.
	do := newServer("")
	if code := do("GET", route, ""); code != 404 {
		t.Fatalf("auto, not found: %d, want 404", code)
	}
	if code := do("GET", "/api/hubble/status", ""); code != 200 {
		t.Errorf("status while inactive: %d, want 200", code)
	}
	do("PUT", "/api/settings/modules", `{"disabled":[],"enabled":["hubble"]}`)
	if code := do("GET", route, ""); code != 400 {
		t.Errorf("explicit on: %d, want 400", code)
	}
	do("PUT", "/api/settings/modules", `{"disabled":["hubble"],"enabled":["hubble"]}`)
	if code := do("GET", route, ""); code != 404 {
		t.Errorf("explicit off: %d, want 404", code)
	}

	// Detected: a relay Service. Existing settings that turned Hubble off
	// stay off; ones that never mentioned it move to auto, so it is on.
	if code := newServer("", relay)("GET", route, ""); code != 400 {
		t.Errorf("auto, found: %d, want 400", code)
	}
	if code := newServer(`{"disabledModules":["helm"]}`, relay)("GET", route, ""); code != 400 {
		t.Errorf("migrated, found: %d, want 400", code)
	}
	if code := newServer(`{"disabledModules":["hubble"]}`, relay)("GET", route, ""); code != 404 {
		t.Errorf("migrated explicit off: %d, want 404", code)
	}
}
