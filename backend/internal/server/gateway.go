package server

import (
	"context"
	"net/http"
	"slices"
	"sort"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/overview"
)

// gatewayModule is the Gateway API integration on the backend: Gateway and
// route health in the overview (see docs/GATEWAY_API.md) and a small
// status endpoint for the Integrations dialog. The Security page's
// exposure checks also read Gateways and HTTPRoutes; they are part of
// Security (core).
type gatewayModule struct{ d Deps }

func (m *gatewayModule) Name() string { return "gateway" }

func (m *gatewayModule) Routes(r httpx.Router, d Deps) {
	m.d = d
	r.HandleFunc("GET /api/gateway/status", m.handleStatus)
}

// gatewayClassInfo is one GatewayClass in the status.
type gatewayClassInfo struct {
	Name       string `json:"name"`
	Controller string `json:"controller"`
	// Accepted: the controller accepted the class (condition Accepted).
	Accepted bool `json:"accepted"`
}

// gatewayStatus is GET /api/gateway/status.
type gatewayStatus struct {
	// CRD: the Gateway API CRDs are served.
	CRD     bool               `json:"crd"`
	Classes []gatewayClassInfo `json:"classes"`
}

// handleStatus lists the (few) GatewayClasses with one direct request: no
// watch is started for a detection.
func (m *gatewayModule) handleStatus(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, gatewayClasses(r.Context(), m.d.Mgr.Clients()))
}

func gatewayClasses(ctx context.Context, c *cluster.Clients) gatewayStatus {
	st := gatewayStatus{Classes: []gatewayClassInfo{}}
	t, err := c.Find(ctx, overview.GatewayGroup, "", "gatewayclasses")
	if err != nil {
		return st
	}
	st.CRD = true
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	gvr := schema.GroupVersionResource{Group: t.Group, Version: t.Version, Resource: t.Resource}
	list, err := c.Dynamic.Resource(gvr).List(ctx, metav1.ListOptions{Limit: 200})
	if err != nil {
		return st
	}
	for _, it := range list.Items {
		ctrl, _, _ := unstructured.NestedString(it.Object, "spec", "controllerName")
		info := gatewayClassInfo{Name: it.GetName(), Controller: ctrl}
		conds, _, _ := unstructured.NestedSlice(it.Object, "status", "conditions")
		for _, cond := range conds {
			if cm, ok := cond.(map[string]any); ok && cm["type"] == "Accepted" && cm["status"] == "True" {
				info.Accepted = true
			}
		}
		st.Classes = append(st.Classes, info)
	}
	sort.Slice(st.Classes, func(i, j int) bool { return st.Classes[i].Name < st.Classes[j].Name })
	return st
}

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
			return func(in *overview.Input) { in.Routes = append(slices.Clip(in.Routes), items...) }, nil
		})
	}
}
