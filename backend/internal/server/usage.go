package server

import (
	"context"
	"reflect"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/metrics"
)

// usageRefreshEvery is how often live pod/node tables re-evaluate rows with
// fresh metrics (metrics-server scrapes every ~15s by default).
var usageRefreshEvery = 15 * time.Second

// usageDecorator merges `.k8sman.usage` into pods and nodes (CPU and
// memory, see metrics.UsageDecorator) and PVCs (disk usage, see
// metrics.ClaimUsageDecorator) before column evaluation. nil for other types
// or when nothing is available.
func (s *Server) usageDecorator(ctx context.Context, c *cluster.Clients, rq resourceQuery) metrics.Decorator {
	if !usageResource(rq.Type) {
		return nil
	}
	if len(rq.Namespaces) > 1 {
		// A namespace set: one decorator per namespace (each fetches only
		// its namespace, which RBAC-limited users can read).
		by := map[string]metrics.Decorator{}
		for _, ns := range rq.Namespaces {
			if d := s.usageDecorator(ctx, c, rq.inNamespace(ns)); d != nil {
				by[ns] = d
			}
		}
		if len(by) == 0 {
			return nil
		}
		return func(obj map[string]any) map[string]any {
			md, _ := obj["metadata"].(map[string]any)
			ns, _ := md["namespace"].(string)
			if d := by[ns]; d != nil {
				return d(obj)
			}
			return obj
		}
	}
	if rq.Type.Resource == "persistentvolumeclaims" {
		return metrics.For(c).ClaimUsageDecorator(ctx, namespaceFor(rq), metrics.PromQueryFor(c))
	}
	return metrics.For(c).UsageDecorator(ctx, rq.Type.Group, rq.Type.Resource, namespaceFor(rq))
}

func usageResource(rt cluster.ResourceType) bool {
	return rt.Group == "" && (rt.Resource == "pods" || rt.Resource == "nodes" || rt.Resource == "persistentvolumeclaims")
}

func namespaceFor(rq resourceQuery) string {
	if rq.Type.Namespaced {
		return rq.Namespace
	}
	return ""
}

// liveUsage re-sends watched pod/node rows whose cells changed because usage
// changed, without re-listing. It keeps the latest object per UID (shared with
// the watch, never mutated) and the cells last sent.
type liveUsage struct {
	refresh func(ctx context.Context) metrics.Decorator
	ticker  *time.Ticker
	objs    map[types.UID]*unstructured.Unstructured
	cells   map[types.UID][]any
}

// newLiveUsage returns nil for types without usage, so callers can use it
// unconditionally.
func (s *Server) newLiveUsage(c *cluster.Clients, rq resourceQuery) *liveUsage {
	if !usageResource(rq.Type) {
		return nil
	}
	return &liveUsage{
		refresh: func(ctx context.Context) metrics.Decorator { return s.usageDecorator(ctx, c, rq) },
		ticker:  time.NewTicker(usageRefreshEvery),
		objs:    map[types.UID]*unstructured.Unstructured{},
		cells:   map[types.UID][]any{},
	}
}

// tick is nil (never fires) when there is no usage to refresh.
func (l *liveUsage) tick() <-chan time.Time {
	if l == nil {
		return nil
	}
	return l.ticker.C
}

func (l *liveUsage) stop() {
	if l != nil {
		l.ticker.Stop()
	}
}

// reset tracks a fresh SNAPSHOT.
func (l *liveUsage) reset(list *unstructured.UnstructuredList, t Table) {
	if l == nil {
		return
	}
	items := make([]*unstructured.Unstructured, len(list.Items))
	for i := range list.Items {
		items[i] = &list.Items[i]
	}
	l.resetItems(items, t.Rows)
}

// resetItems tracks a fresh SNAPSHOT of (shared, read-only) objects.
func (l *liveUsage) resetItems(items []*unstructured.Unstructured, rows []Row) {
	if l == nil {
		return
	}
	clear(l.objs)
	clear(l.cells)
	for _, u := range items {
		l.objs[u.GetUID()] = u
	}
	for _, r := range rows {
		l.cells[types.UID(r.UID)] = r.Cells
	}
}

// track records a watch event's object and the row just sent.
func (l *liveUsage) track(ev watch.EventType, u *unstructured.Unstructured, row Row) {
	if l == nil {
		return
	}
	if ev == watch.Deleted {
		delete(l.objs, u.GetUID())
		delete(l.cells, u.GetUID())
		return
	}
	l.objs[u.GetUID()] = u
	l.cells[u.GetUID()] = row.Cells
}

// changedRows fetches fresh usage (one cached call), swaps it into the
// builder and returns rows whose cells changed. Cheap when metrics are
// unavailable: the decorator is nil and nothing is re-evaluated.
func (l *liveUsage) changedRows(ctx context.Context, b *tableBuilder) []Row {
	if l == nil {
		return nil
	}
	d := l.refresh(ctx)
	if d == nil && b.decorate == nil {
		return nil
	}
	b.decorate = d
	var out []Row
	for uid, u := range l.objs {
		row := b.row(u)
		if reflect.DeepEqual(row.Cells, l.cells[uid]) {
			continue
		}
		l.cells[uid] = row.Cells
		out = append(out, row)
	}
	return out
}
