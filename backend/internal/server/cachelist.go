package server

import (
	"context"
	"reflect"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/kcache"
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
func listTyped[T any](ctx context.Context, kc *kcache.Cache, gvr schema.GroupVersionResource, ns, fieldSelector string) ([]T, error) {
	snap, err := kc.List(ctx, kcache.Key{GVR: gvr, Namespace: ns, FieldSelector: fieldSelector})
	if err != nil {
		return nil, err
	}
	tag := reflect.TypeFor[T]()
	out := make([]T, 0, len(snap.Items))
	for _, u := range snap.Items {
		v := snap.Memo(u, tag, "", func() any {
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
func listCached(ctx context.Context, kc *kcache.Cache, gvr schema.GroupVersionResource, ns string) ([]*unstructured.Unstructured, error) {
	snap, err := kc.List(ctx, kcache.Key{GVR: gvr, Namespace: ns})
	if err != nil {
		return nil, err
	}
	return snap.Items, nil
}
