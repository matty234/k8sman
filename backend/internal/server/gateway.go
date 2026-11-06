package server

import (
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/overview"
)

// gatewayModule is the Gateway API integration on the backend: Gateway and
// route health in the overview (see docs/GATEWAY_API.md). It has no routes
// of its own. The Security page's exposure checks also read Gateways and
// HTTPRoutes; they are part of Security (core).
type gatewayModule struct{}

func (m *gatewayModule) Name() string { return "gateway" }

func (m *gatewayModule) Routes(httpx.Router, Deps) {}

// OverviewInputs lists Gateways and every served route kind, but only when
// the Gateway API CRDs are installed (otherwise the inputs stay nil and the
// analysis skips them).
func (m *gatewayModule) OverviewInputs(l *OverviewLists) {
	ctx, c, ns := l.Ctx, l.Clients, l.Namespace
	gw, err := c.Find(ctx, overview.GatewayGroup, "", "gateways")
	if err != nil {
		return
	}
	list := func(t cluster.ResourceType) ([]unstructured.Unstructured, error) {
		gvr := schema.GroupVersionResource{Group: t.Group, Version: t.Version, Resource: t.Resource}
		items, err := listCached(ctx, kcache.For(c), gvr, ns)
		if err != nil {
			return nil, err
		}
		out := make([]unstructured.Unstructured, len(items))
		for i, it := range items {
			out[i] = *it
			if it.GetKind() == "" {
				// Lists may leave kind empty on items; the analysis needs it.
				// Items are shared with the cache, so set it on a copy.
				out[i] = *it.DeepCopy()
				out[i].SetKind(t.Kind)
			}
		}
		return out, nil
	}
	l.Set(func(in *overview.Input) { in.Routes = []unstructured.Unstructured{} })
	l.Go("gateways", func() (func(*overview.Input), error) {
		items, err := list(gw)
		if err != nil {
			return nil, err
		}
		return func(in *overview.Input) { in.Gateways = items }, nil
	})
	for _, res := range overview.GatewayRouteResources {
		t, err := c.Find(ctx, overview.GatewayGroup, "", res)
		if err != nil {
			continue
		}
		l.Go(res, func() (func(*overview.Input), error) {
			items, err := list(t)
			if err != nil {
				return nil, err
			}
			return func(in *overview.Input) { in.Routes = append(in.Routes, items...) }, nil
		})
	}
}
