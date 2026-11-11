package prom

import (
	"context"
	"net/http"
	"sort"
	"sync"

	"github.com/matty234/k8sman/backend/internal/httpx"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// SelectedKind lists the objects of one kind a Prometheus / Alertmanager
// custom resource selects.
type SelectedKind struct {
	Kind string `json:"kind"`
	// Total is how many exist in the cluster; Selected (capped) are those
	// the CR picks up and Count how many that is.
	Total    int         `json:"total"`
	Count    int         `json:"count"`
	Selected []ObjectRef `json:"selected"`
	Error    string      `json:"error,omitempty"`
}

// PoolHealth is a scrape pool's target health, for the Prometheus panel.
type PoolHealth struct {
	ScrapePool string   `json:"scrapePool"`
	Monitor    *Monitor `json:"monitor,omitempty"`
	Up         int      `json:"up"`
	Down       int      `json:"down"`
	Unknown    int      `json:"unknown"`
}

// SelectionResult is the GET /api/prom/selection payload.
type SelectionResult struct {
	Kinds []SelectedKind `json:"kinds"`
	// Instance is the discovered instance for this CR (nil when it isn't
	// one k8sman found); its target health follows for Prometheus.
	Instance *Instance         `json:"instance,omitempty"`
	Targets  *TargetsSummary   `json:"targets,omitempty"`
	Errors   map[string]string `json:"errors,omitempty"`
}

// TargetsSummary counts a Prometheus' active targets by health and pool.
type TargetsSummary struct {
	Up      int          `json:"up"`
	Down    int          `json:"down"`
	Unknown int          `json:"unknown"`
	Pools   []PoolHealth `json:"pools"`
}

func (h *Handler) handleSelection(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	kind, ns, name := q.Get("kind"), q.Get("namespace"), q.Get("name")
	var gvr = PrometheusGVR
	sels := promSelectables
	switch kind {
	case "Prometheus":
	case "Alertmanager":
		gvr, sels = AlertmanagerGVR, []selectable{amSelectable}
	default:
		writeErr(w, httpx.BadRequest("kind must be Prometheus or Alertmanager"))
		return
	}
	e := h.env()
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	cr, err := e.dyn.Resource(gvr).Namespace(ns).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		writeErr(w, err)
		return
	}
	spec, _ := cr.Object["spec"].(map[string]any)
	nsLabels := nsLabeler(ctx, e.typed)
	res := &SelectionResult{Kinds: make([]SelectedKind, len(sels)), Errors: map[string]string{}}
	lists := make([][]crObject, len(sels))
	errs := make([]error, len(sels))
	var wg sync.WaitGroup
	for i, s := range sels {
		wg.Add(1)
		go func() { defer wg.Done(); lists[i], errs[i] = listCRs(ctx, e.dyn, s.Kind, s.GVR) }()
	}
	// Target health for a Prometheus k8sman found.
	var (
		targets []promTarget
		tErr    error
	)
	st := h.disc.get(ctx, e, false)
	if in := st.Default(map[string]string{"Prometheus": KindPrometheus, "Alertmanager": KindAlertmanager}[kind], ns+"/"+name); in != nil && in.Namespace == ns {
		res.Instance = in
		if kind == "Prometheus" {
			wg.Add(1)
			go func() { defer wg.Done(); targets, tErr = cachedTargets(ctx, e, in) }()
		}
	}
	wg.Wait()
	for i, s := range sels {
		sk := SelectedKind{Kind: s.Kind, Selected: []ObjectRef{}}
		if errs[i] != nil {
			sk.Error = errs[i].Error()
		}
		sk.Total = len(lists[i])
		for _, o := range lists[i] {
			if ok, _ := crSelects(spec, ns, s, o.Namespace, o.Labels, nsLabels); ok {
				sk.Count++
				if len(sk.Selected) < maxSelectionItems {
					sk.Selected = append(sk.Selected, ObjectRef{Group: "monitoring.coreos.com", Kind: s.Kind, Namespace: o.Namespace, Name: o.Name})
				}
			}
		}
		sort.Slice(sk.Selected, func(a, b int) bool {
			x, y := sk.Selected[a], sk.Selected[b]
			return x.Namespace+"/"+x.Name < y.Namespace+"/"+y.Name
		})
		res.Kinds[i] = sk
	}
	if res.Instance != nil && kind == "Prometheus" {
		if tErr != nil {
			res.Errors["targets"] = tErr.Error()
		} else {
			res.Targets = summariseTargets(targets)
		}
	}
	if len(res.Errors) == 0 {
		res.Errors = nil
	}
	httpx.WriteJSON(w, 200, res)
}

func summariseTargets(raw []promTarget) *TargetsSummary {
	g := GroupTargets(raw, TargetFilter{})
	ts := &TargetsSummary{Up: g.Up, Down: g.Down, Unknown: g.Unknown, Pools: make([]PoolHealth, 0, len(g.Pools))}
	for _, p := range g.Pools {
		ts.Pools = append(ts.Pools, PoolHealth{ScrapePool: p.ScrapePool, Monitor: p.Monitor, Up: p.Up, Down: p.Down, Unknown: p.Unknown})
	}
	return ts
}

// SelectedBy is whether one Prometheus / Alertmanager CR picks up an object.
type SelectedBy struct {
	Kind      string `json:"kind"`
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Selected  bool   `json:"selected"`
	Detail    string `json:"detail,omitempty"`
	// MatcherStrategy is the Alertmanager's
	// alertmanagerConfigMatcherStrategy.type (AlertmanagerConfigs only).
	MatcherStrategy string `json:"matcherStrategy,omitempty"`
}

// handleSelectedBy answers which Prometheus (or Alertmanager) custom
// resources select a monitor, rule or AlertmanagerConfig, and if not why.
func (h *Handler) handleSelectedBy(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	sel, crKind, ok := selectableFor(q.Get("kind"))
	if !ok {
		writeErr(w, httpx.BadRequest("unsupported kind %q", q.Get("kind")))
		return
	}
	ns, name := q.Get("namespace"), q.Get("name")
	e := h.env()
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	obj, err := e.dyn.Resource(sel.GVR).Namespace(ns).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		writeErr(w, err)
		return
	}
	gvr := PrometheusGVR
	if crKind == "Alertmanager" {
		gvr = AlertmanagerGVR
	}
	crs, err := listCRs(ctx, e.dyn, crKind, gvr)
	if err != nil {
		writeErr(w, err)
		return
	}
	nsLabels := nsLabeler(ctx, e.typed)
	out := []SelectedBy{}
	for _, c := range crs {
		ok, detail := crSelects(c.Spec, c.Namespace, sel, obj.GetNamespace(), obj.GetLabels(), nsLabels)
		sb := SelectedBy{Kind: crKind, Namespace: c.Namespace, Name: c.Name, Selected: ok, Detail: detail}
		if crKind == "Alertmanager" {
			sb.MatcherStrategy = "OnNamespace"
			if m, ok := c.Spec["alertmanagerConfigMatcherStrategy"].(map[string]any); ok && str(m["type"]) != "" {
				sb.MatcherStrategy = str(m["type"])
			}
		}
		out = append(out, sb)
	}
	httpx.WriteJSON(w, 200, map[string]any{"items": out})
}
