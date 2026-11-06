package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
)

func TestApplyCreatesEachDocument(t *testing.T) {
	cs := fake.NewSimpleClientset()
	cs.Resources = []*metav1.APIResourceList{
		{GroupVersion: "v1", APIResources: []metav1.APIResource{
			{Name: "configmaps", Kind: "ConfigMap", Namespaced: true, Verbs: []string{"create", "get", "list"}},
			{Name: "namespaces", Kind: "Namespace", Verbs: []string{"create", "get", "list"}},
		}},
	}
	existing := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "ConfigMap", "metadata": map[string]any{"name": "taken", "namespace": "demo"},
	}}
	dyn := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), existing)
	server := func(readOnly bool) *Server {
		c := &cluster.Clients{Context: "kind-dev", Typed: cs, Dynamic: dyn, Discovery: memory.NewMemCacheClient(cs.Discovery())}
		s := &Server{mgr: cluster.NewStatic(c), mux: http.NewServeMux(), readOnly: readOnly}
		s.applyRoutes()
		return s
	}
	body := `# leading comment
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  key: value
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: taken
---
apiVersion: example.dev/v1
kind: Widget
metadata:
  name: w
`
	post := func(s *Server) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		s.mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/apply?namespace=demo", strings.NewReader(body)))
		return w
	}

	w := post(server(false))
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body)
	}
	var got struct {
		Context string        `json:"context"`
		Results []applyResult `json:"results"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &got)
	if got.Context != "kind-dev" || len(got.Results) != 4 {
		t.Fatalf("got %+v", got)
	}
	ns, cm, taken, widget := got.Results[0], got.Results[1], got.Results[2], got.Results[3]
	if !ns.Created || ns.Namespace != "" || ns.Line != 2 {
		t.Errorf("namespace: %+v", ns)
	}
	if !cm.Created || cm.Namespace != "demo" || cm.Line != 7 || cm.Error != "" {
		t.Errorf("configmap should default to ?namespace: %+v", cm)
	}
	if taken.Created || taken.Reason != "AlreadyExists" {
		t.Errorf("existing object: %+v", taken)
	}
	if widget.Created || !strings.Contains(widget.Error, "isn't served") {
		t.Errorf("unknown kind: %+v", widget)
	}
	cmGVR := schema.GroupVersionResource{Version: "v1", Resource: "configmaps"}
	if _, err := dyn.Resource(cmGVR).Namespace("demo").Get(context.Background(), "app-config", metav1.GetOptions{}); err != nil {
		t.Errorf("app-config not created: %v", err)
	}

	if w := post(server(true)); w.Code != http.StatusForbidden {
		t.Errorf("read-only: status %d, want 403", w.Code)
	}
}
