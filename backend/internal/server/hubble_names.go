package server

import (
	"context"
	"net/netip"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/overview"
)

// clusterAddrs maps the cluster's own addresses to the object that has
// them (node/<name>, svc/<ns>/<name>, ingress/<ns>/<name>,
// gateway/<ns>/<name>), from the shared watch cache. Earlier kinds win
// when two objects share an address. Kinds that can't be listed (no
// permission, Gateway API not installed) are skipped.
func clusterAddrs(ctx context.Context, c *cluster.Clients) map[string]string {
	kc := kcache.For(c)
	out := map[string]string{}
	add := func(ip, label string) {
		if a, err := netip.ParseAddr(ip); err == nil {
			if k := a.Unmap().String(); out[k] == "" {
				out[k] = label
			}
		}
	}
	each := func(gvr schema.GroupVersionResource, f func(u *unstructured.Unstructured)) {
		items, err := listCached(ctx, kc, gvr, "")
		if err != nil {
			return
		}
		for _, u := range items {
			f(u)
		}
	}
	strs := func(u *unstructured.Unstructured, key string, path ...string) []string {
		l, _, _ := unstructured.NestedSlice(u.Object, path...)
		var out []string
		for _, e := range l {
			if m, ok := e.(map[string]any); ok {
				if s, ok := m[key].(string); ok {
					out = append(out, s)
				}
			}
		}
		return out
	}
	each(gvrNodes, func(u *unstructured.Unstructured) {
		for _, ip := range strs(u, "address", "status", "addresses") {
			add(ip, "node/"+u.GetName())
		}
	})
	each(gvrServices, func(u *unstructured.Unstructured) {
		label := "svc/" + u.GetNamespace() + "/" + u.GetName()
		for _, ip := range strs(u, "ip", "status", "loadBalancer", "ingress") {
			add(ip, label)
		}
		ext, _, _ := unstructured.NestedStringSlice(u.Object, "spec", "externalIPs")
		for _, ip := range ext {
			add(ip, label)
		}
		cip, _, _ := unstructured.NestedString(u.Object, "spec", "clusterIP")
		add(cip, label)
	})
	each(gvrIngresses, func(u *unstructured.Unstructured) {
		for _, ip := range strs(u, "ip", "status", "loadBalancer", "ingress") {
			add(ip, "ingress/"+u.GetNamespace()+"/"+u.GetName())
		}
	})
	if t, err := c.Find(ctx, overview.GatewayGroup, "", "gateways"); err == nil {
		each(t.GVR(), func(u *unstructured.Unstructured) {
			for _, ip := range strs(u, "value", "status", "addresses") {
				add(ip, "gateway/"+u.GetNamespace()+"/"+u.GetName())
			}
		})
	}
	return out
}
