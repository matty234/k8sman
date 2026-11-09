package server

import (
	"context"
	"reflect"
	"sync"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
)

// GVRs of the built-in types the Overview and Security analyses list.
var (
	gvrPods                = schema.GroupVersionResource{Version: "v1", Resource: "pods"}
	gvrNodes               = schema.GroupVersionResource{Version: "v1", Resource: "nodes"}
	gvrNamespaces          = schema.GroupVersionResource{Version: "v1", Resource: "namespaces"}
	gvrPVCs                = schema.GroupVersionResource{Version: "v1", Resource: "persistentvolumeclaims"}
	gvrEvents              = schema.GroupVersionResource{Version: "v1", Resource: "events"}
	gvrServices            = schema.GroupVersionResource{Version: "v1", Resource: "services"}
	gvrServiceAccounts     = schema.GroupVersionResource{Version: "v1", Resource: "serviceaccounts"}
	gvrDeployments         = schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "deployments"}
	gvrStatefulSets        = schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "statefulsets"}
	gvrDaemonSets          = schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "daemonsets"}
	gvrReplicaSets         = schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "replicasets"}
	gvrJobs                = schema.GroupVersionResource{Group: "batch", Version: "v1", Resource: "jobs"}
	gvrCronJobs            = schema.GroupVersionResource{Group: "batch", Version: "v1", Resource: "cronjobs"}
	gvrIngresses           = schema.GroupVersionResource{Group: "networking.k8s.io", Version: "v1", Resource: "ingresses"}
	gvrNetworkPolicies     = schema.GroupVersionResource{Group: "networking.k8s.io", Version: "v1", Resource: "networkpolicies"}
	gvrRoles               = schema.GroupVersionResource{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "roles"}
	gvrRoleBindings        = schema.GroupVersionResource{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "rolebindings"}
	gvrClusterRoles        = schema.GroupVersionResource{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterroles"}
	gvrClusterRoleBindings = schema.GroupVersionResource{Group: "rbac.authorization.k8s.io", Version: "v1", Resource: "clusterrolebindings"}
)

// listTyped lists a built-in type through the shared watch cache and
// converts the items to T. The first call costs one LIST and starts a watch
// that stays warm while the page keeps polling, so later polls cost no API
// requests; conversions are memoised per object version, so only changed
// objects are converted again. Errors are those of the LIST.
//
// ns may be a comma-separated namespace set (see listScope).
func listTyped[T any](ctx context.Context, kc *kcache.Cache, gvr schema.GroupVersionResource, ns, fieldSelector string) ([]T, error) {
	items, memo, err := listScope(ctx, kc, kcache.Key{GVR: gvr, FieldSelector: fieldSelector}, ns)
	if err != nil {
		return nil, err
	}
	tag := reflect.TypeFor[T]()
	out := make([]T, 0, len(items))
	for _, u := range items {
		v := memo(u, tag, "", func() any {
			var t T
			if err := runtime.DefaultUnstructuredConverter.FromUnstructured(u.Object, &t); err != nil {
				return err
			}
			return t
		})
		if err, ok := v.(error); ok {
			return nil, err
		}
		out = append(out, v.(T))
	}
	return out, nil
}

// listCached lists any type through the shared watch cache. Items are shared
// with the cache: copy before modifying.
// ns may be a comma-separated namespace set (see listScope).
func listCached(ctx context.Context, kc *kcache.Cache, gvr schema.GroupVersionResource, ns string) ([]*unstructured.Unstructured, error) {
	items, _, err := listScope(ctx, kc, kcache.Key{GVR: gvr}, ns)
	return items, err
}

// listScope lists key in scope: "" (all namespaces), one namespace, or a
// comma-separated set ("a,b"). A set is read from a warm all-namespaces
// stream when there is one, else namespace by namespace in parallel
// (which works for users who can only read those namespaces). Namespaces of
// a set that can't be read are left out; the error is returned only when
// none of them can be read.
func listScope(ctx context.Context, kc *kcache.Cache, key kcache.Key, scope string) ([]*unstructured.Unstructured, memoFunc, error) {
	set := kube.SplitNamespaces(scope)
	if len(set) <= 1 {
		key.Namespace = set.Single()
		snap, err := kc.List(ctx, key)
		if err != nil {
			return nil, nil, err
		}
		return snap.Items, snap.Memo, nil
	}
	if snap, ok := kc.CachedSet(key, set); ok {
		return snap.Items, snap.Memo, nil
	}
	items, memo, err := fanOutNamespaces(set, func(ns string) (nsPart, error) {
		k := key
		k.Namespace = ns
		snap, err := kc.List(ctx, k)
		return nsPart{items: snap.Items, memo: snap.Memo}, err
	}, func(ns string, err error) { kube.ReportSkipped(ctx, ns, err) })
	if err != nil {
		return nil, nil, err
	}
	return items, memo, nil
}

// nsPart is one namespace's share of a namespace-set listing.
type nsPart struct {
	items []*unstructured.Unstructured
	memo  memoFunc // nil when the part has none
}

// fanOutNamespaces fetches each namespace of set in parallel and merges the
// results in set order. A namespace that fails is reported to skipped and
// left out; the error is returned only when every one failed. The merged
// memo routes each object to its namespace's memo (nil when no part had
// one).
func fanOutNamespaces(set kube.Namespaces, fetch func(ns string) (nsPart, error), skipped func(ns string, err error)) ([]*unstructured.Unstructured, memoFunc, error) {
	parts := make([]nsPart, len(set))
	errs := make([]error, len(set))
	var wg sync.WaitGroup
	for i, ns := range set {
		wg.Add(1)
		go func() {
			defer wg.Done()
			parts[i], errs[i] = fetch(ns)
		}()
	}
	wg.Wait()
	var items []*unstructured.Unstructured
	memos := map[string]memoFunc{}
	ok := false
	for i, ns := range set {
		if errs[i] != nil {
			skipped(ns, errs[i])
			continue
		}
		ok = true
		items = append(items, parts[i].items...)
		if parts[i].memo != nil {
			memos[ns] = parts[i].memo
		}
	}
	if !ok {
		return nil, nil, errs[0]
	}
	if len(memos) == 0 {
		return items, nil, nil
	}
	return items, func(u *unstructured.Unstructured, tag any, extra string, compute func() any) any {
		if m := memos[u.GetNamespace()]; m != nil {
			return m(u, tag, extra, compute)
		}
		return compute()
	}, nil
}
