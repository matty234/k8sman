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

// Views keep their order: undoing a delete puts the view back at its index,
// and views bound to the default kubeconfig and to the same file by an
// explicit path share one kubeconfig key.
func TestViewOrderRestoreAndKubeconfigKeys(t *testing.T) {
	s, _, _ := newTestServer(t, cluster.NewDisconnected("", errors.New("none")))
	put := func(id, kubeconfig, query string) {
		t.Helper()
		ctx := `null`
		if kubeconfig != "-" {
			ctx = `{"kubeconfig":"` + kubeconfig + `","name":"c"}`
		}
		body := `{"version":1,"id":"` + id + `","name":"` + id + `","context":` + ctx + `,"kind":{"group":"apps","kind":"Deployment"},"namespaces":[]}`
		if rec, _ := do(t, s, "PUT", "/api/settings/views/"+id+query, body); rec.Code != 200 {
			t.Fatalf("put %s: %d %s", id, rec.Code, rec.Body)
		}
	}
	list := func() (ids string, keys map[string]string) {
		t.Helper()
		rec, _ := do(t, s, "GET", "/api/settings/views", "")
		var got struct {
			Views []struct {
				ID string `json:"id"`
			} `json:"views"`
			Keys map[string]string `json:"kubeconfigKeys"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		for _, v := range got.Views {
			ids += v.ID
		}
		return ids, got.Keys
	}
	put("a", "-", "")
	put("b", "-", "")
	put("c", "", "")
	put("d", "~/.kube/../.kube/config", "")
	if rec, _ := do(t, s, "DELETE", "/api/settings/views/b", ""); rec.Code != 204 {
		t.Fatal(rec.Code)
	}
	put("b", "-", "?index=1")
	if ids, keys := list(); ids != "abcd" || keys[""] == "" || keys[""] != keys["~/.kube/../.kube/config"] {
		t.Fatalf("restore at index: order %q, keys %v", ids, keys)
	}
	if rec, _ := do(t, s, "PUT", "/api/settings/views/order", `{"ids":["d","a","zz","b"]}`); rec.Code != 204 {
		t.Fatal(rec.Code)
	}
	if ids, _ := list(); ids != "dacb" { // c keeps the slot it had
		t.Fatalf("reorder: %q", ids)
	}
}
