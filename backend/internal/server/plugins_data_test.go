package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery/cached/memory"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/kubernetes/fake"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/plugins"
	"github.com/matty234/k8sman/backend/internal/settings"
)

const patchPluginManifest = `apiVersion: k8sman.dev/v1
id: demo
name: Demo
version: 1.0.0
permissions:
  read: [example.com/Widget]
  patch: [example.com/Widget]
kinds:
  example.com/Widget:
    actions:
      - id: resize
        label: Resize
        inputs:
          - {name: size, type: int, default: object.spec.size, validate: input.size <= 10, validateMessage: At most 10.}
        patch:
          type: merge
          body: '{"spec": {"size": input.size}}'
`

// A plugin patch action runs only through POST /api/actions: refused on
// read-only contexts and without consent, its inputs checked by the
// backend, and a dry run answers with the change to confirm.
func TestPluginPatchActionThroughActionPath(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, plugins.ManifestFile), []byte(patchPluginManifest), 0o644); err != nil {
		t.Fatal(err)
	}
	st, err := settings.Open(filepath.Join(t.TempDir(), "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	host := plugins.NewHost(plugins.Options{FlagDirs: []string{dir}, Settings: st})
	host.Reload()
	defer host.Close()

	cs := fake.NewSimpleClientset()
	cs.Resources = []*metav1.APIResourceList{{GroupVersion: "example.com/v1", APIResources: []metav1.APIResource{
		{Name: "widgets", Kind: "Widget", Namespaced: true, Verbs: []string{"get", "list", "watch", "patch", "delete"}},
	}}}
	gvr := schema.GroupVersionResource{Group: "example.com", Version: "v1", Resource: "widgets"}
	widget := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "example.com/v1", "kind": "Widget",
		"metadata": map[string]any{"name": "w1", "namespace": "default"},
		"spec":     map[string]any{"size": int64(3)},
	}}
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{
		gvr: "WidgetList", {Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}: "CustomResourceDefinitionList",
	}, widget)
	c := &cluster.Clients{Context: "dev", Typed: cs, Dynamic: dyn, Discovery: memory.NewMemCacheClient(cs.Discovery())}

	server := func(readOnly bool) *Server {
		s := &Server{mgr: cluster.NewStatic(c), mux: http.NewServeMux(), readOnly: readOnly, settings: st, plugins: host}
		s.modules = []Module{&pluginsModule{s: s}}
		s.actionRoutes()
		s.mux.HandleFunc("GET /api/plugins/panel", s.handlePluginPanel)
		return s
	}
	const target = "?group=example.com&version=v1&resource=widgets&namespace=default&name=w1"
	run := func(s *Server, body string) (int, ActionResult, string) {
		w := httptest.NewRecorder()
		s.mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/actions/plugin.demo.resize"+target, strings.NewReader(body)))
		var res ActionResult
		_ = json.Unmarshal(w.Body.Bytes(), &res)
		return w.Code, res, w.Body.String()
	}

	if code, _, body := run(server(true), `{"inputs": {"size": 5}}`); code != http.StatusForbidden {
		t.Fatalf("read-only: %d %s", code, body)
	}
	// Read-only: the panel offers no plugin actions at all.
	w := httptest.NewRecorder()
	server(true).mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/plugins/panel"+target, nil))
	if !strings.Contains(w.Body.String(), `"actions":[]`) {
		t.Fatalf("read-only panel offers actions: %s", w.Body)
	}

	s := server(false)
	if code, _, body := run(s, `{"inputs": {"size": 5}}`); code != http.StatusBadRequest || !strings.Contains(body, "haven't been agreed to") {
		t.Fatalf("without consent: %d %s", code, body)
	}
	hash := host.Get("demo").PermissionsHash()
	if err := st.UpdatePlugins(func(p *settings.PluginSettings) { p.Consent = map[string]string{"demo": hash} }); err != nil {
		t.Fatal(err)
	}
	if code, _, body := run(s, `{"inputs": {"size": 50}, "dryRun": true}`); code != http.StatusBadRequest || !strings.Contains(body, "At most 10.") {
		t.Fatalf("bad input: %d %s", code, body)
	}
	code, res, body := run(s, `{"inputs": {"size": 5}, "dryRun": true}`)
	if code != 200 || res.Preview == nil || string(res.Preview.Patch) != `{"spec":{"size":5}}` ||
		!strings.Contains(res.Preview.Before, "size: 3") || !strings.Contains(res.Preview.After, "size: 5") {
		t.Fatalf("dry run: %d %s", code, body)
	}
}
