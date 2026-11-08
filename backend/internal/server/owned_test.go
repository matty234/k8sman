package server

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	dynamicfake "k8s.io/client-go/dynamic/fake"

	"github.com/matty234/k8sman/backend/internal/kcache"
)

func ownedObj(apiVersion, kind, ns, name, uid, ownerUID string) *unstructured.Unstructured {
	u := &unstructured.Unstructured{Object: map[string]any{"apiVersion": apiVersion, "kind": kind}}
	u.SetNamespace(ns)
	u.SetName(name)
	u.SetUID(types.UID("u-" + uid))
	if ownerUID != "" {
		u.SetOwnerReferences([]metav1.OwnerReference{{APIVersion: "apps/v1", Kind: "ReplicaSet", Name: "x", UID: types.UID("u-" + ownerUID)}})
	}
	return u
}

func TestFindOwned(t *testing.T) {
	kinds := map[schema.GroupVersionResource]string{}
	for _, g := range append(append([]schema.GroupVersionResource{}, ownedListed...), ownedWarmOnly...) {
		kinds[g] = map[string]string{"pods": "PodList"}[g.Resource]
		if kinds[g] == "" {
			kinds[g] = g.Resource + "List"
		}
	}
	pod := ownedObj("v1", "Pod", "a", "p1", "p1", "rs")
	_ = unstructured.SetNestedField(pod.Object, "Running", "status", "phase")
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), kinds,
		pod,
		ownedObj("v1", "Pod", "b", "other-ns", "p2", "rs"),
		ownedObj("v1", "Pod", "a", "unowned", "p3", ""),
		ownedObj("batch/v1", "Job", "a", "job", "j1", "rs"),
	)
	kc := kcache.New(dyn)
	defer kc.Close()

	items, partial := findOwned(context.Background(), kc, "u-rs", "a")
	if len(items) != 2 || items[0].Kind != "Job" || items[1].Name != "p1" || items[1].Status != "Running" {
		t.Fatalf("namespaced: %+v", items)
	}
	if partial { // every listed kind was searched
		t.Error("unexpected partial")
	}
	// A cluster-scoped owner reads what is already cached, in any namespace.
	items, _ = findOwned(context.Background(), kc, "u-rs", "")
	if len(items) != 2 {
		t.Fatalf("cluster-wide, got %+v", items)
	}
}
