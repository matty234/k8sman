package server

import (
	"net/http/httptest"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery/cached/memory"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"

	"encoding/json"
	"net/http"
	"path/filepath"
	"strings"
	"testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

func TestContextReadOnly(t *testing.T) {
	kc := writeKubeconfig(t, filepath.Join(t.TempDir(), "config"), "prod-eu", "dev")
	mgr, err := cluster.NewManager(kc, "")
	if err != nil {
		t.Fatal(err)
	}
	s, _, _ := newTestServer(t, mgr)
	health := func() (bool, string) {
		rec, _ := do(t, s, "GET", "/api/health", "")
		var h struct {
			ReadOnly bool   `json:"readOnly"`
			Reason   string `json:"readOnlyReason"`
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &h)
		return h.ReadOnly, h.Reason
	}
	contexts := func() map[string]string {
		rec, _ := do(t, s, "GET", "/api/contexts", "")
		var c struct {
			ReadOnly map[string]string `json:"readOnly"`
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &c)
		return c.ReadOnly
	}

	// A production-looking name is read-only until the user says otherwise.
	if ro, why := health(); !ro || why != "auto" {
		t.Fatalf("prod-eu: readOnly=%v reason=%q, want auto", ro, why)
	}
	rec, _ := do(t, s, "PUT", "/api/object", `{}`)
	if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "context is read-only") {
		t.Fatalf("edit on prod-eu: %d %s", rec.Code, rec.Body)
	}
	if got := contexts(); got["prod-eu"] != "auto" || got["dev"] != "" {
		t.Fatalf("contexts: %v", got)
	}

	if rec, _ := do(t, s, "PUT", "/api/settings/readonly", `{"context":"prod-eu","readOnly":false}`); rec.Code != 200 {
		t.Fatalf("allow: %d %s", rec.Code, rec.Body)
	}
	if ro, _ := health(); ro {
		t.Fatal("prod-eu still read-only after allowing changes")
	}
	if rec, _ := do(t, s, "PUT", "/api/object", `{}`); rec.Code == http.StatusForbidden {
		t.Fatalf("edit refused after allowing: %s", rec.Body)
	}

	do(t, s, "PUT", "/api/settings/readonly", `{"context":"dev","readOnly":true}`)
	do(t, s, "PUT", "/api/settings/readonly", `{"context":"prod-eu","readOnly":null}`)
	if got := contexts(); got["dev"] != "context" || got["prod-eu"] != "auto" {
		t.Fatalf("after dev locked and prod-eu back to automatic: %v", got)
	}
}

func TestTablePrefs(t *testing.T) {
	kc := writeKubeconfig(t, filepath.Join(t.TempDir(), "config"), "dev")
	mgr, err := cluster.NewManager(kc, "")
	if err != nil {
		t.Fatal(err)
	}
	s, st, _ := newTestServer(t, mgr)
	body := `{"kind":"apps/Deployment","prefs":{"sortColumn":"Age","sortDescending":true,"widths":{"Name":220},"filter":"status=running"}}`
	if rec, _ := do(t, s, "PUT", "/api/settings/tables", body); rec.Code != http.StatusNoContent {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}
	rec, _ := do(t, s, "GET", "/api/settings/tables", "")
	if !strings.Contains(rec.Body.String(), `"apps/Deployment":{"sortColumn":"Age","sortDescending":true,"widths":{"Name":220},"filter":"status=running"}`) {
		t.Fatalf("get: %s", rec.Body)
	}
	if p := st.Get().Tables["apps/Deployment"]; p.Widths["Name"] != 220 {
		t.Fatalf("not saved: %+v", p)
	}
	do(t, s, "PUT", "/api/settings/tables", `{"kind":"apps/Deployment","prefs":null}`)
	if _, ok := st.Get().Tables["apps/Deployment"]; ok {
		t.Fatal("null should forget the kind")
	}
}

func TestRememberedNamespaces(t *testing.T) {
	kc := writeKubeconfig(t, filepath.Join(t.TempDir(), "config"), "dev")
	mgr, err := cluster.NewManager(kc, "")
	if err != nil {
		t.Fatal(err)
	}
	s, st, _ := newTestServer(t, mgr)
	if rec, _ := do(t, s, "PUT", "/api/settings/namespaces", `{"context":"dev","namespaces":["team-a","b2"]}`); rec.Code != http.StatusNoContent {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}
	if rec, _ := do(t, s, "PUT", "/api/settings/namespaces", `{"context":"dev","namespaces":["Bad_Name"]}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid name: %d", rec.Code)
	}
	rec, _ := do(t, s, "GET", "/api/settings/namespaces?context=dev", "")
	if !strings.Contains(rec.Body.String(), `"namespaces":["team-a","b2"]`) || len(st.Get().Namespaces["dev"]) != 2 {
		t.Fatalf("get: %s", rec.Body)
	}
	do(t, s, "PUT", "/api/settings/namespaces", `{"context":"dev","namespaces":[]}`)
	if _, ok := st.Get().Namespaces["dev"]; ok {
		t.Fatal("empty list should forget the context")
	}
}

func TestUpdateStatusSubresource(t *testing.T) {
	cs := fake.NewSimpleClientset()
	cs.Resources = []*metav1.APIResourceList{{GroupVersion: "v1", APIResources: []metav1.APIResource{
		{Name: "configmaps", Kind: "ConfigMap", Namespaced: true, Verbs: []string{"get", "list", "update"}},
		{Name: "configmaps/status", Kind: "ConfigMap", Namespaced: true, Verbs: []string{"get", "update"}},
	}}}
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{
		{Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}: "CustomResourceDefinitionList",
	})
	var subs []string
	dyn.PrependReactor("update", "configmaps", func(a k8stesting.Action) (bool, runtime.Object, error) {
		subs = append(subs, a.GetSubresource())
		return true, a.(k8stesting.UpdateAction).GetObject(), nil
	})
	put := func(readOnly bool, q string) *httptest.ResponseRecorder {
		c := &cluster.Clients{Context: "dev", Typed: cs, Dynamic: dyn, Discovery: memory.NewMemCacheClient(cs.Discovery())}
		s := &Server{mgr: cluster.NewStatic(c), mux: http.NewServeMux(), readOnly: readOnly}
		s.mutationRoutes()
		body := "apiVersion: v1\nkind: ConfigMap\nmetadata: {name: x, namespace: d, resourceVersion: '1'}\n"
		w := httptest.NewRecorder()
		s.mux.ServeHTTP(w, httptest.NewRequest("PUT", "/api/object?resource=configmaps&version=v1&namespace=d&name=x"+q, strings.NewReader(body)))
		return w
	}
	if w := put(false, "&subresource=status"); w.Code != 200 || len(subs) != 1 || subs[0] != "status" {
		t.Fatalf("status update: %d %s subs=%v", w.Code, w.Body, subs)
	}
	if w := put(false, "&subresource=scale"); w.Code != 400 {
		t.Fatalf("scale on a type without it: %d", w.Code)
	}
	if w := put(true, "&subresource=status"); w.Code != http.StatusForbidden {
		t.Fatalf("read-only: %d", w.Code)
	}
}
