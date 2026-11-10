package server

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/plugins"
)

// benchPluginColumns are three plugin (CEL) columns on Pods, and the same
// three as jq columns.
const benchPluginManifest = `apiVersion: k8sman.dev/v1
id: bench
name: Bench
version: 1.0.0
permissions:
  read: [/Pod]
kinds:
  /Pod:
    columns:
      - name: Phase2
        value: object.status.phase
      - name: Node2
        value: object.spec.?nodeName.orValue("")
      - name: Ready2
        type: status
        value: 'conditionTrue(object, "Ready") ? "Ready" : "Not ready"'
`

var benchJQColumns = []columns.Column{
	{Name: "Phase2", Query: ".status.phase"},
	{Name: "Node2", Query: `.spec.nodeName // ""`},
	{Name: "Ready2", Query: `if ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) > 0 then "Ready" else "Not ready" end`, Type: "status"},
}

// BenchmarkTableSnapshot renders a 1,500-pod snapshot with the default
// columns, plus three jq columns, plus three plugin columns; cold (empty
// row memo) and warm (every row memoised). The plugin budget
// (docs/PLUGINS.md §8) is cold ≤ +10 ms and warm +0 over the defaults.
func BenchmarkTableSnapshot(b *testing.B) {
	items := benchPods(1500)
	base := columns.Defaults(podsType, nil)
	dir := b.TempDir()
	if err := os.WriteFile(filepath.Join(dir, plugins.ManifestFile), []byte(benchPluginManifest), 0o644); err != nil {
		b.Fatal(err)
	}
	h := plugins.NewHost(plugins.Options{FlagDirs: []string{dir}})
	h.Reload()
	defer h.Close()
	plug := h.Columns("bench", podsType, base)
	if len(plug) != len(base)+3 {
		b.Fatalf("plugin columns not added: %d", len(plug))
	}
	for _, tc := range []struct {
		name string
		cols []columns.Column
	}{{"defaults", base}, {"jq3", append(slices.Clone(base), benchJQColumns...)}, {"plugin3", plug}} {
		b.Run(tc.name+"/cold", func(b *testing.B) {
			for b.Loop() {
				tb := newTableBuilder(tc.cols, false)
				tb.memo = mapMemo()
				tb.tableOf(podsType, true, items, "1")
			}
		})
		b.Run(tc.name+"/warm", func(b *testing.B) {
			memo := mapMemo()
			for b.Loop() {
				tb := newTableBuilder(tc.cols, false)
				tb.memo = memo
				tb.tableOf(podsType, true, items, "1")
			}
		})
	}
}

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
