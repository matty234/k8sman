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
	snaps := make([]kcache.Snapshot, len(set))
	errs := make([]error, len(set))
	var wg sync.WaitGroup
	for i, ns := range set {
		wg.Add(1)
		go func() {
			defer wg.Done()
			k := key
			k.Namespace = ns
			snaps[i], errs[i] = kc.List(ctx, k)
		}()
	}
	wg.Wait()
	var items []*unstructured.Unstructured
	memos := map[string]memoFunc{}
	ok := false
	for i, ns := range set {
		if errs[i] != nil {
			continue
		}
		ok = true
		items = append(items, snaps[i].Items...)
		memos[ns] = snaps[i].Memo
	}
	if !ok {
		return nil, nil, errs[0]
	}
	return items, func(u *unstructured.Unstructured, tag any, extra string, compute func() any) any {
		if m := memos[u.GetNamespace()]; m != nil {
			return m(u, tag, extra, compute)
		}
		return compute()
	}, nil
}
