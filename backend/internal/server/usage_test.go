package server

import (
	"context"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/metrics"
)

var podsType = cluster.ResourceType{Group: "", Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true}

func pod(name, uid string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Pod",
		"metadata": map[string]any{"name": name, "namespace": "demo", "uid": uid},
		"spec":     map[string]any{"containers": []any{map[string]any{"name": "app"}}},
	}}
}

// decorator gives each pod name a fixed CPU (millicores) and 64Mi of memory.
func decorator(cpu map[string]int64) metrics.Decorator {
	return func(obj map[string]any) map[string]any {
		name := obj["metadata"].(map[string]any)["name"].(string)
		m, ok := cpu[name]
		if !ok {
			return obj
		}
		u := metrics.MakeUsage(m, 64<<20)
		out := map[string]any{}
		for k, v := range obj {
			out[k] = v
		}
		out[metrics.UsageKey] = map[string]any{"usage": map[string]any{"cpu": u.CPU, "memory": u.Memory, "cpuMillis": int(u.CPUMillis), "memoryBytes": int(u.MemoryBytes)}}
		return out
	}
}

func newTestLiveUsage(refresh func(context.Context) metrics.Decorator) *liveUsage {
	return &liveUsage{refresh: refresh, objs: map[types.UID]*unstructured.Unstructured{}, cells: map[types.UID][]any{}}
}

func colIndex(cols []columns.Column, name string) int {
	for i, c := range cols {
		if c.Name == name {
			return i
		}
	}
	return -1
}

// raw is a usage cell's value (cores or bytes), or -1.
func raw(cell any) float64 {
	m, _ := cell.(map[string]any)
	switch v := m["raw"].(type) {
	case float64:
		return v
	case int:
		return float64(v)
	}
	return -1
}

func TestBuiltinUsageColumns(t *testing.T) {
	cols := columns.Defaults(podsType, nil)
	cpu, mem := colIndex(cols, "CPU"), colIndex(cols, "Memory")
	if cpu < 0 || mem < 0 || cols[cpu].Type != "usage" {
		t.Fatalf("pods columns: %+v", cols)
	}
	b := newTableBuilder(cols, true)
	b.decorate = decorator(map[string]int64{"a": 12})
	a, other := pod("a", "1"), pod("b", "2")
	ra, rb := b.row(a), b.row(other)
	if raw(ra.Cells[cpu]) != 0.012 || raw(ra.Cells[mem]) != 64<<20 {
		t.Fatalf("cells: %v", ra.Cells)
	}
	// No metrics for b → empty cell (UI shows "—"), and no column errors.
	if rb.Cells[cpu] != nil || rb.Cells[mem] != nil || len(b.colErrs) != 0 {
		t.Fatalf("missing usage: %v %v", rb.Cells, b.colErrs)
	}
	// The returned and stored objects are never decorated.
	if _, ok := a.Object[metrics.UsageKey]; ok {
		t.Fatal("stored object mutated")
	}
	if _, ok := ra.Object[metrics.UsageKey]; ok {
		t.Fatal("row object should be the original")
	}
}

func TestLiveUsageSendsOnlyChangedRows(t *testing.T) {
	cols := columns.Defaults(podsType, nil)
	cpu := map[string]int64{"a": 10, "b": 20}
	lu := newTestLiveUsage(func(context.Context) metrics.Decorator { return decorator(cpu) })
	b := newTableBuilder(cols, false)
	b.decorate = decorator(cpu)
	list := &unstructured.UnstructuredList{Items: []unstructured.Unstructured{*pod("a", "1"), *pod("b", "2")}}
	lu.reset(list, b.table(podsType, true, list))

	if rows := lu.changedRows(context.Background(), b); len(rows) != 0 {
		t.Fatalf("nothing changed, got %d rows", len(rows))
	}
	cpu["b"] = 25
	rows := lu.changedRows(context.Background(), b)
	if len(rows) != 1 || rows[0].Name != "b" || raw(rows[0].Cells[colIndex(cols, "CPU")]) != 0.025 {
		t.Fatalf("want b only: %+v", rows)
	}
	// A watch event updates what was last sent.
	c := pod("c", "3")
	cpu["c"] = 5
	lu.track(watch.Added, c, b.row(c))
	if rows := lu.changedRows(context.Background(), b); len(rows) != 0 {
		t.Fatalf("tracked row resent: %+v", rows)
	}
	lu.track(watch.Deleted, c, Row{})
	if len(lu.objs) != 2 {
		t.Fatalf("delete not tracked: %d", len(lu.objs))
	}
	// Metrics disappear: rows with usage are re-sent with empty cells once.
	none := newTestLiveUsage(func(context.Context) metrics.Decorator { return nil })
	none.objs, none.cells = lu.objs, lu.cells
	if rows := none.changedRows(context.Background(), b); len(rows) != 2 || rows[0].Cells[colIndex(cols, "CPU")] != nil {
		t.Fatalf("want 2 cleared rows: %+v", rows)
	}
	if rows := none.changedRows(context.Background(), b); rows != nil {
		t.Fatalf("no metrics and nothing to clear should be a no-op: %+v", rows)
	}
}

// Without a column that reads .k8sman nothing is decorated, fetched or
// refreshed. The nil Server and clients would panic on any metrics fetch.
func TestNoEnrichmentWithoutColumnsReadingIt(t *testing.T) {
	var s *Server
	rq := resourceQuery{Type: podsType, Namespace: "demo"}
	plain := columns.NewEvaluator([]columns.Column{{Name: "Name", Query: ".metadata.name"}})
	if d := s.decoratorFor(context.Background(), nil, rq, plain); d != nil {
		t.Fatal("decorator built for columns that do not read .k8sman")
	}
	if l := s.newLiveUsage(nil, rq, plain.UsesEnrichment()); l != nil {
		t.Fatal("live usage refresh started for columns that do not read .k8sman")
	}
	if !columns.NewEvaluator(columns.Defaults(podsType, nil)).UsesEnrichment() {
		t.Fatal("default pod columns must still enrich")
	}
}
