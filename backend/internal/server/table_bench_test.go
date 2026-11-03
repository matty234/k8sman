package server

import (
	"fmt"
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

// BenchmarkTableSnapshot renders + encodes a 1,500-pod SNAPSHOT with the
// built-in pod columns: cold (every row evaluated) and warm (rows memoised,
// as on a re-snapshot or a second watcher of the same table).
//
//	go test ./internal/server -run '^$' -bench TableSnapshot -benchmem
func BenchmarkTableSnapshot(b *testing.B) {
	items := benchPods(1500)
	cols := columns.Defaults(podsType, nil)
	rt := cluster.ResourceType{Resource: "pods", Version: "v1", Namespaced: true}
	b.Run("cold", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			tb := newTableBuilder(cols, false)
			t, built := tb.tableOf(rt, true, items, "1")
			_ = snapshotFrame(t, built)
		}
	})
	b.Run("warm", func(b *testing.B) {
		memo := mapMemo()
		tb := newTableBuilder(cols, false)
		tb.memo = memo
		tb.tableOf(rt, true, items, "1")
		b.ReportAllocs()
		b.ResetTimer()
		for b.Loop() {
			tb := newTableBuilder(cols, false)
			tb.memo = memo
			t, built := tb.tableOf(rt, true, items, "1")
			_ = snapshotFrame(t, built)
		}
	})
}
