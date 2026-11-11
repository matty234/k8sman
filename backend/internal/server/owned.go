package server

import (
	"context"
	"net/http"
	"sort"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kapi"
	"github.com/matty234/k8sman/backend/internal/kcache"
)

// ownedItem is one object that names the queried uid in its ownerReferences.
type ownedItem struct {
	Group     string `json:"group"`
	Version   string `json:"version"`
	Kind      string `json:"kind"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name"`
	UID       string `json:"uid"`
	Status    string `json:"status,omitempty"`
}

// Likely child kinds of any owner. ownedListed kinds start a shared watch
// when none is warm (namespaced lookups only): the usual children of
// controllers and operators. ownedWarmOnly kinds are read only if already
// cached; opening an object shouldn't start a watch on every Secret,
// ConfigMap and Service in its namespace.
var (
	ownedListed = []schema.GroupVersionResource{
		gvrPods, gvrReplicaSets, gvrJobs, gvrPVCs,
		kapi.ControllerRevisions.GVR(),
	}
	ownedWarmOnly = []schema.GroupVersionResource{
		gvrServices,
		kapi.EndpointSlices.GVR(),
		kapi.ConfigMaps.GVR(),
		kapi.Secrets.GVR(),
	}
)

// findOwned returns the cached objects owned by uid, from every warm stream
// plus the likely child kinds. ns narrows to one namespace (a namespaced
// owner only owns objects in its own namespace); "" (a cluster-scoped owner)
// searches all namespaces but, to avoid starting cluster-wide watches, only
// reads kinds that are already cached. partial reports that a listed kind
// could not be searched.
//
// There is no uid index: this scans the cached objects (an in-memory loop,
// around a millisecond per 100k objects) and keeps nothing between requests.
func findOwned(ctx context.Context, kc *kcache.Cache, uid, ns string) (items []ownedItem, partial bool) {
	seen := map[string]bool{}
	scan := func(objs []*unstructured.Unstructured) {
		for _, u := range objs {
			if ns != "" && u.GetNamespace() != ns {
				continue
			}
			for _, o := range u.GetOwnerReferences() {
				if string(o.UID) != uid {
					continue
				}
				if id := string(u.GetUID()); !seen[id] {
					seen[id] = true
					gv, _ := schema.ParseGroupVersion(u.GetAPIVersion())
					items = append(items, ownedItem{gv.Group, gv.Version, u.GetKind(), u.GetNamespace(), u.GetName(), id, ownedStatus(u)})
				}
				break
			}
		}
	}
	for _, snap := range kc.Warm() {
		scan(snap.Items)
	}
	for _, gvr := range ownedListed {
		if ns == "" {
			if _, ok := kc.Cached(kcache.Key{GVR: gvr}); !ok {
				partial = true
			}
			continue
		}
		objs, err := listCached(ctx, kc, gvr, ns)
		if err != nil {
			partial = true
			continue
		}
		scan(objs)
	}
	// Warm-only kinds don't count towards partial: they're read whenever
	// cached (via Warm above), and flagging them would show the hint on
	// nearly every object.
	_ = ownedWarmOnly
	sort.Slice(items, func(i, j int) bool {
		a, b := items[i], items[j]
		if a.Kind != b.Kind {
			return a.Kind < b.Kind
		}
		if a.Namespace != b.Namespace {
			return a.Namespace < b.Namespace
		}
		return a.Name < b.Name
	})
	return items, partial
}

// ownedStatus is a short status word for the common shapes: status.phase
// (Pods, PVCs) or the first of the Failed/Complete/Ready/Available
// conditions that is True.
func ownedStatus(u *unstructured.Unstructured) string {
	if p, ok, _ := unstructured.NestedString(u.Object, "status", "phase"); ok {
		return p
	}
	conds, _, _ := unstructured.NestedSlice(u.Object, "status", "conditions")
	for _, want := range []string{"Failed", "Complete", "Ready", "Available"} {
		for _, c := range conds {
			m, _ := c.(map[string]any)
			if m["type"] == want && m["status"] == "True" {
				return want
			}
		}
	}
	return ""
}

func (s *Server) handleOwned(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	uid := q.Get("uid")
	if uid == "" {
		writeErr(w, httpx.BadRequest("uid is required"))
		return
	}
	items, partial := findOwned(r.Context(), kcache.For(s.mgr.Clients()), uid, q.Get("namespace"))
	if items == nil {
		items = []ownedItem{}
	}
	httpx.WriteJSON(w, 200, map[string]any{"items": items, "partial": partial})
}
