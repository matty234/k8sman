package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery/cached/memory"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/kubernetes/fake"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// finalize clears finalizers only on an object that is already terminating,
// and is refused in read-only mode.
func TestFinalizeOnlyWhenTerminating(t *testing.T) {
	cs := fake.NewSimpleClientset()
	cs.Resources = []*metav1.APIResourceList{{GroupVersion: "v1", APIResources: []metav1.APIResource{
		{Name: "pods", Kind: "Pod", Namespaced: true, Verbs: []string{"get", "list", "patch", "delete"}},
	}}}
	pod := func(name string, terminating bool) *unstructured.Unstructured {
		u := &unstructured.Unstructured{Object: map[string]any{"apiVersion": "v1", "kind": "Pod", "metadata": map[string]any{"name": name, "namespace": "d"}}}
		u.SetFinalizers([]string{"example.com/protect"})
		if terminating {
			now := metav1.NewTime(time.Now())
			u.SetDeletionTimestamp(&now)
		}
		return u
	}
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{
		{Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}: "CustomResourceDefinitionList",
		{Version: "v1", Resource: "pods"}: "PodList",
	}, pod("live", false), pod("stuck", true))
	server := func(readOnly bool) *Server {
		c := &cluster.Clients{Context: "kind-dev", Typed: cs, Dynamic: dyn, Discovery: memory.NewMemCacheClient(cs.Discovery())}
		s := &Server{mgr: cluster.NewStatic(c), mux: http.NewServeMux(), readOnly: readOnly}
		s.actionRoutes()
		return s
	}
	post := func(s *Server, name string) int {
		w := httptest.NewRecorder()
		s.mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/actions/finalize?version=v1&resource=pods&namespace=d&name="+name, strings.NewReader("")))
		return w.Code
	}
	if c := post(server(false), "live"); c != http.StatusBadRequest {
		t.Errorf("live pod: status %d, want 400", c)
	}
	if c := post(server(true), "stuck"); c != http.StatusForbidden {
		t.Errorf("read-only: status %d, want 403", c)
	}
	if c := post(server(false), "stuck"); c != 200 {
		t.Fatalf("terminating pod: status %d", c)
	}
	got, err := dyn.Resource(schema.GroupVersionResource{Version: "v1", Resource: "pods"}).Namespace("d").Get(context.Background(), "stuck", metav1.GetOptions{})
	if err != nil || len(got.GetFinalizers()) != 0 {
		t.Errorf("finalizers not cleared: %v %v", got.GetFinalizers(), err)
	}
}
