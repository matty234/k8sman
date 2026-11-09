package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/discovery/cached/memory"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/kubernetes/fake"
	clienttesting "k8s.io/client-go/testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// A namespace set is one table merged from a watch per namespace: the
// snapshot holds every readable namespace's rows, a forbidden namespace is
// a PARTIAL_ERROR frame, and the socket stays open for later changes.
func TestWatchNamespaceSetMergesAndReportsForbidden(t *testing.T) {
	gvr := schema.GroupVersionResource{Version: "v1", Resource: "configmaps"}
	obj := func(ns, name string) *unstructured.Unstructured {
		u := &unstructured.Unstructured{Object: map[string]any{"apiVersion": "v1", "kind": "ConfigMap"}}
		u.SetNamespace(ns)
		u.SetName(name)
		u.SetUID(types.UID(ns + "-" + name))
		return u
	}
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{gvr: "ConfigMapList",
		{Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}: "CustomResourceDefinitionList"},
		obj("team-a", "web"), obj("team-b", "api"), obj("other", "hidden"))
	dyn.PrependReactor("list", "configmaps", func(a clienttesting.Action) (bool, runtime.Object, error) {
		if a.GetNamespace() == "team-c" {
			return true, nil, apierrors.NewForbidden(gvr.GroupResource(), "", errors.New("RBAC says no"))
		}
		return false, nil, nil
	})
	cs := fake.NewSimpleClientset()
	cs.Resources = []*metav1.APIResourceList{{GroupVersion: "v1", APIResources: []metav1.APIResource{
		{Name: "configmaps", Kind: "ConfigMap", Namespaced: true, Verbs: []string{"get", "list", "watch"}},
	}}}
	c := &cluster.Clients{Context: "kind-dev", Typed: cs, Dynamic: dyn, Discovery: memory.NewMemCacheClient(cs.Discovery())}
	s := &Server{mgr: cluster.NewStatic(c), mux: http.NewServeMux()}
	s.routes()
	srv := httptest.NewServer(s.mux)
	t.Cleanup(srv.Close)

	q := url.Values{"version": {"v1"}, "resource": {"configmaps"}, "namespaces": {"team-c,team-b,team-a"},
		"columns": {`[{"name":"Name","query":".metadata.name"}]`}}
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/api/watch?"+q.Encode(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	read := func() map[string]any {
		t.Helper()
		_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
		var m map[string]any
		if err := ws.ReadJSON(&m); err != nil {
			t.Fatal(err)
		}
		return m
	}

	var partial, snapshot map[string]any
	for partial == nil || snapshot == nil {
		switch m := read(); m["type"] {
		case "PARTIAL_ERROR":
			partial = m
		case "SNAPSHOT":
			snapshot = m
		default:
			t.Fatalf("unexpected frame %v", m)
		}
	}
	if partial["namespace"] != "team-c" || partial["reason"] != "Forbidden" {
		t.Fatalf("partial error %v", partial)
	}
	var names []string
	for _, r := range snapshot["table"].(map[string]any)["rows"].([]any) {
		row := r.(map[string]any)
		names = append(names, row["namespace"].(string)+"/"+row["name"].(string))
	}
	sort.Strings(names)
	if strings.Join(names, ",") != "team-a/web,team-b/api" {
		t.Fatalf("snapshot rows %v", names)
	}
	if cols := snapshot["table"].(map[string]any)["columns"].([]any); len(cols) != 1 {
		t.Fatalf("the request's own columns should be used, got %v", cols)
	}

	// The socket stays open: a change in a readable namespace arrives.
	if _, err := dyn.Resource(gvr).Namespace("team-b").Create(context.Background(), obj("team-b", "worker"), metav1.CreateOptions{}); err != nil {
		t.Fatal(err)
	}
	m := read()
	if m["type"] != "ADDED" || m["row"].(map[string]any)["name"] != "worker" {
		t.Fatalf("want ADDED worker, got %v", m)
	}
}

// With a namespace allowlist, "all namespaces" fans out over the allowed
// namespaces (no cluster-wide LIST, which a tenant may not do), and
// /api/namespaces answers with the allowlist.
func TestAllowedNamespacesNarrowAllNamespaces(t *testing.T) {
	gvr := schema.GroupVersionResource{Version: "v1", Resource: "configmaps"}
	obj := func(ns, name string) *unstructured.Unstructured {
		u := &unstructured.Unstructured{Object: map[string]any{"apiVersion": "v1", "kind": "ConfigMap"}}
		u.SetNamespace(ns)
		u.SetName(name)
		return u
	}
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{gvr: "ConfigMapList",
		{Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}: "CustomResourceDefinitionList"},
		obj("team-a", "web"), obj("team-b", "api"), obj("other", "hidden"))
	dyn.PrependReactor("list", "configmaps", func(a clienttesting.Action) (bool, runtime.Object, error) {
		if a.GetNamespace() == "" {
			return true, nil, apierrors.NewForbidden(gvr.GroupResource(), "", errors.New("cluster-wide list"))
		}
		return false, nil, nil
	})
	cs := fake.NewSimpleClientset()
	cs.Resources = []*metav1.APIResourceList{{GroupVersion: "v1", APIResources: []metav1.APIResource{
		{Name: "configmaps", Kind: "ConfigMap", Namespaced: true, Verbs: []string{"get", "list", "watch"}},
	}}}
	c := &cluster.Clients{Context: "tenant", Typed: cs, Dynamic: dyn, Discovery: memory.NewMemCacheClient(cs.Discovery())}
	s, _, _ := newTestServer(t, cluster.NewStatic(c))

	if rec, _ := do(t, s, "PUT", "/api/settings/allowed-namespaces", `{"namespaces":["team-b","team-a"]}`); rec.Code != 204 {
		t.Fatalf("put allowlist: %d %s", rec.Code, rec.Body)
	}
	rec, _ := do(t, s, "GET", "/api/namespaces", "")
	if !strings.Contains(rec.Body.String(), `"namespaces":["team-a","team-b"]`) || !strings.Contains(rec.Body.String(), `"restricted":true`) {
		t.Fatalf("namespaces: %s", rec.Body)
	}
	rec, _ = do(t, s, "GET", "/api/items?version=v1&resource=configmaps", "")
	var got struct {
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); rec.Code != 200 || err != nil {
		t.Fatalf("items: %d %s", rec.Code, rec.Body)
	}
	var names []string
	for _, it := range got.Items {
		names = append(names, it["metadata"].(map[string]any)["name"].(string))
	}
	sort.Strings(names)
	if strings.Join(names, ",") != "api,web" {
		t.Fatalf("items %v", names)
	}

	// The default namespace round-trips.
	if rec, _ := do(t, s, "PUT", "/api/settings/default-namespace", `{"mode":"namespaces","namespaces":["team-b"]}`); rec.Code != 204 {
		t.Fatalf("put default: %d %s", rec.Code, rec.Body)
	}
	if rec, _ := do(t, s, "GET", "/api/settings/default-namespace", ""); !strings.Contains(rec.Body.String(), `"mode":"namespaces","namespaces":["team-b"]`) {
		t.Fatalf("default: %s", rec.Body)
	}
}
