package server

import (
	"context"
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

const vmPluginManifest = `apiVersion: k8sman.dev/v1
id: vms
name: VMs
version: 1.0.0
minAppVersion: 0.2.20
permissions:
  read: [kubevirt.io/VirtualMachine]
  subresources: [kubevirt.io/VirtualMachine/restart]
  create: [kubevirt.io/VirtualMachineInstanceMigration]
kinds:
  kubevirt.io/VirtualMachine:
    actions:
      - id: restart
        label: Restart
        inputs:
          - {name: grace, type: int, default: "30"}
        subresource:
          name: restart
          group: subresources.kubevirt.io
          body: '{"gracePeriodSeconds": input.grace}'
      - id: migrate
        label: Migrate
        create:
          kind: kubevirt.io/VirtualMachineInstanceMigration
          body: '{"apiVersion": "kubevirt.io/v1", "kind": "VirtualMachineInstanceMigration", "metadata": {"name": object.metadata.name + "-migration"}, "spec": {"vmiName": object.metadata.name}}'
`

// Subresource and create actions: checked against their permissions at
// load, and through POST /api/actions a subresource dry run describes the
// request (it has no dry run) while a create dry run shows the object the
// server would create; the real create names it.
func TestPluginSubresourceAndCreateActions(t *testing.T) {
	validate := func(src string) string {
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, plugins.ManifestFile), []byte(src), 0o644)
		var msgs []string
		for _, d := range plugins.Validate(dir) {
			msgs = append(msgs, d.Message)
		}
		return strings.Join(msgs, "\n")
	}
	if msgs := validate(vmPluginManifest); msgs != "" {
		t.Fatalf("diags: %s", msgs)
	}
	for _, tc := range [][3]string{
		{"  create: [kubevirt.io/VirtualMachineInstanceMigration]\n", "", "is not in permissions.create"},
		{"name: restart\n", "name: exec\n", "can't call the exec subresource"},
	} {
		if msgs := validate(strings.Replace(vmPluginManifest, tc[0], tc[1], 1)); !strings.Contains(msgs, tc[2]) {
			t.Errorf("want %q, got %s", tc[2], msgs)
		}
	}

	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, plugins.ManifestFile), []byte(vmPluginManifest), 0o644)
	st, err := settings.Open(filepath.Join(t.TempDir(), "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	host := plugins.NewHost(plugins.Options{FlagDirs: []string{dir}, Settings: st})
	host.Reload()
	defer host.Close()
	hash := host.Get("vms").PermissionsHash()
	st.UpdatePlugins(func(p *settings.PluginSettings) { p.Consent = map[string]string{"vms": hash} })

	cs := fake.NewSimpleClientset()
	verbs := []string{"get", "list", "watch", "create", "patch", "delete"}
	cs.Resources = []*metav1.APIResourceList{{GroupVersion: "kubevirt.io/v1", APIResources: []metav1.APIResource{
		{Name: "virtualmachines", Kind: "VirtualMachine", Namespaced: true, Verbs: verbs},
		{Name: "virtualmachineinstancemigrations", Kind: "VirtualMachineInstanceMigration", Namespaced: true, Verbs: verbs},
	}}}
	vms := schema.GroupVersionResource{Group: "kubevirt.io", Version: "v1", Resource: "virtualmachines"}
	migs := schema.GroupVersionResource{Group: "kubevirt.io", Version: "v1", Resource: "virtualmachineinstancemigrations"}
	vm := &unstructured.Unstructured{Object: map[string]any{"apiVersion": "kubevirt.io/v1", "kind": "VirtualMachine",
		"metadata": map[string]any{"name": "vm1", "namespace": "vms"}}}
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{
		vms: "VirtualMachineList", migs: "VirtualMachineInstanceMigrationList",
		{Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}: "CustomResourceDefinitionList",
	}, vm)
	c := &cluster.Clients{Context: "dev", Typed: cs, Dynamic: dyn, Discovery: memory.NewMemCacheClient(cs.Discovery())}
	s := &Server{mgr: cluster.NewStatic(c), mux: http.NewServeMux(), settings: st, plugins: host}
	s.modules = []Module{&pluginsModule{s: s}}
	s.actionRoutes()
	run := func(action, body string) ActionResult {
		w := httptest.NewRecorder()
		s.mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/actions/plugin.vms."+action+"?group=kubevirt.io&version=v1&resource=virtualmachines&namespace=vms&name=vm1", strings.NewReader(body)))
		var res ActionResult
		if err := json.Unmarshal(w.Body.Bytes(), &res); err != nil || w.Code != 200 {
			t.Fatalf("%s: %d %s", action, w.Code, w.Body)
		}
		return res
	}

	res := run("restart", `{"inputs": {"grace": 0}, "dryRun": true}`)
	if p := res.Preview; p == nil || p.PatchType != "subresource" ||
		string(p.Patch) != `{"body":{"gracePeriodSeconds":0},"method":"PUT","path":"/apis/subresources.kubevirt.io/v1/namespaces/vms/virtualmachines/vm1/restart"}` {
		t.Fatalf("restart preview: %+v", res.Preview)
	}
	res = run("migrate", `{"dryRun": true}`)
	if p := res.Preview; p == nil || p.PatchType != "create" || p.Before != "" ||
		!strings.Contains(p.After, "name: vm1-migration\n  namespace: vms") || !strings.Contains(p.After, "vmiName: vm1") {
		t.Fatalf("migrate preview: %+v", res.Preview)
	}
	// The fake client ignores dryRun: drop what the dry run created.
	dyn.Resource(migs).Namespace("vms").Delete(context.Background(), "vm1-migration", metav1.DeleteOptions{})
	if res = run("migrate", `{}`); res.Created == nil || res.Created.Name != "vm1-migration" || res.Created.Namespace != "vms" {
		t.Fatalf("migrate: %+v", res)
	}
}
