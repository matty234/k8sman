package server

import (
	"encoding/json"
	"fmt"
	"sync"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
)

// benchPods builds n pods shaped like the perf-load ones.
func benchPods(n int) []*unstructured.Unstructured {
	out := make([]*unstructured.Unstructured, n)
	for i := range out {
		out[i] = &unstructured.Unstructured{Object: map[string]any{
			"apiVersion": "v1", "kind": "Pod",
			"metadata": map[string]any{
				"name": fmt.Sprintf("perf-pause-%04d", i), "namespace": "perf-load", "uid": fmt.Sprintf("uid-%d", i),
				"resourceVersion": "1", "creationTimestamp": "2026-11-03T12:00:00Z",
				"labels":          map[string]any{"app": "perf-pause", "pod-template-hash": "abc"},
				"ownerReferences": []any{map[string]any{"apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "perf-pause-abc", "uid": "rs", "controller": true}},
			},
			"spec": map[string]any{"nodeName": "node-1", "containers": []any{map[string]any{"name": "pause", "image": "registry.k8s.io/pause:3.7"}}},
			"status": map[string]any{
				"phase": "Running", "podIP": "10.0.0.1",
				"conditions":        []any{map[string]any{"type": "Ready", "status": "True"}},
				"containerStatuses": []any{map[string]any{"name": "pause", "ready": true, "restartCount": int64(0), "state": map[string]any{"running": map[string]any{}}}},
			},
		}}
	}
	return out
}

// mapMemo is a minimal stand-in for kcache's per-object memo.
func mapMemo() memoFunc {
	cache := map[any]any{}
	return func(u *unstructured.Unstructured, tag any, extra string, compute func() any) any {
		k := [4]any{u.GetUID(), u.GetResourceVersion(), tag, extra}
		if v, ok := cache[k]; ok {
			return v
		}
		v := compute()
		cache[k] = v
		return v
	}
}

// Objects from the watch cache are shared between goroutines; rendering
// them (gojq normalises its input in place) must never write to them.
// Run with -race.
func TestSharedObjectsAreNotWrittenByColumnEvaluation(t *testing.T) {
	items := benchPods(20)
	cols := columns.Defaults(podsType, nil)
	rt := cluster.ResourceType{Resource: "pods", Version: "v1", Namespaced: true}
	noCache := func(_ *unstructured.Unstructured, _ any, _ string, compute func() any) any { return compute() }
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(2)
		go func() {
			defer wg.Done()
			tb := newTableBuilder(cols, true)
			tb.memo = noCache
			tb.decorate = decorator(map[string]int64{"perf-pause-0001": 5})
			tb.tableOf(rt, true, items, "1")
		}()
		go func() {
			defer wg.Done()
			_, _ = json.Marshal(items) // like /api/items or an includeObject row
		}()
	}
	wg.Wait()
	cs := items[0].Object["status"].(map[string]any)["containerStatuses"].([]any)[0].(map[string]any)
	if _, ok := cs["restartCount"].(int64); !ok {
		t.Fatalf("restartCount was normalised in place to %T", cs["restartCount"])
	}
}
