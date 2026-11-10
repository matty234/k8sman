package plugins

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// Related objects and metrics are declared per kind and looked up by the
// host, never by plugin code (docs/PLUGINS.md §6): Lookup is the only way
// a plugin reaches cluster data beyond its object. The server implements
// it over the shared watch cache (kcache) and the Prometheus module;
// `plugin test` over fixtures.

// Lookup reads what related objects and metrics need.
type Lookup interface {
	// List returns the objects of kind key (group/Kind) in namespace ns
	// ("" = every namespace; ignored for cluster-scoped kinds), narrowed
	// to labelSelector and name when they are set. ErrNotServed when the
	// cluster doesn't serve the kind. Objects may be shared: don't modify.
	List(ctx context.Context, kindKey, ns, labelSelector, name string) ([]map[string]any, error)
	// Query runs an instant PromQL query (instance "" = the default
	// Prometheus). ErrNoPrometheus when there is none.
	Query(ctx context.Context, instance, query string) ([]Sample, error)
}

// Sample is one series of an instant query.
type Sample struct {
	Labels map[string]string `json:"labels" yaml:"labels"`
	Value  float64           `json:"value" yaml:"value"`
}

// ErrNotServed means the cluster doesn't serve a related kind.
var ErrNotServed = errors.New("the cluster doesn't serve this kind")

// ErrNoPrometheus means there is no Prometheus to query (none found, or the
// Prometheus integration is off).
var ErrNoPrometheus = errors.New("no Prometheus is available")

// lookupTimeout bounds the lookups of one render (a cold related kind
// costs one LIST; later renders read the warm stream).
const lookupTimeout = 5 * time.Second

// Env is what an evaluation runs in.
type Env struct {
	// Context is the kube context's name (the `context` variable).
	Context string
	// Now is the time the evaluation sees (zero = the current time).
	Now time.Time
	// Lookup serves related objects and metrics (nil = none: related
	// objects are absent and metrics empty, with a note).
	Lookup Lookup
}

func (e Env) now() time.Time {
	if e.Now.IsZero() {
		return time.Now()
	}
	return e.Now
}

// notes collects what a render couldn't look up, shown in the panel.
type notes []string

func (n *notes) add(format string, args ...any) {
	s := fmt.Sprintf(format, args...)
	if !slices.Contains(*n, s) {
		*n = append(*n, s)
	}
}

// resolveRelated fills r.act.related with the relations need names.
func (r *renderer) resolveRelated(kp *kindProgs, need refSet, env Env, ns *notes) {
	out := map[string]any{}
	r.act.related = out
	if need.empty() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), lookupTimeout)
	defer cancel()
	uid, _ := nestedString(r.act.object, "metadata", "uid")
	for _, rp := range kp.related {
		if !need.has(rp.name) {
			continue
		}
		rel := rp.rel
		if rel.IsList() {
			out[rp.name] = []any{}
		}
		if ok, err := r.cond(rp.when); err != nil || !ok {
			if err != nil {
				ns.add("related.%s: %v", rp.name, err)
			}
			continue
		}
		if env.Lookup == nil {
			ns.add("Related objects aren't available here.")
			continue
		}
		namespace := r.act.namespace
		if rp.nsP != nil {
			v, err := r.eval(rp.nsP)
			if err != nil {
				ns.add("related.%s: %v", rp.name, err)
				continue
			}
			namespace, _ = v.(string)
		}
		var items []map[string]any
		var err error
		switch {
		case rel.Name.IsSet():
			var v any
			if v, err = r.eval(rp.nameP); err == nil {
				name, _ := v.(string)
				if name == "" {
					continue
				}
				items, err = env.Lookup.List(ctx, rel.Kind, namespace, "", name)
				items = slices.DeleteFunc(slices.Clone(items), func(o map[string]any) bool {
					n, _ := nestedString(o, "metadata", "name")
					return n != name
				})
			}
		case rel.Owner:
			if uid == "" {
				continue
			}
			items, err = env.Lookup.List(ctx, rel.Kind, namespace, "", "")
			items = slices.DeleteFunc(slices.Clone(items), func(o map[string]any) bool { return !ownedBy(o, uid) })
		case rel.Selector.IsSet():
			var v any
			var sel string
			if v, err = r.eval(rp.selector); err == nil {
				if sel, err = selectorString(v); err == nil && sel != "" {
					items, err = env.Lookup.List(ctx, rel.Kind, namespace, sel, "")
				}
			}
		default:
			// filter alone: every object of the kind in the namespace.
			items, err = env.Lookup.List(ctx, rel.Kind, namespace, "", "")
		}
		if err == nil && rp.filter != nil && len(items) > 0 {
			items, err = r.filter(rp, items)
		}
		if err != nil {
			switch {
			case errors.Is(err, ErrNotServed):
				ns.add("%s aren't served by this cluster.", kindName(rel.Kind))
			default:
				ns.add("related.%s: %v", rp.name, err)
			}
			continue
		}
		if !rel.IsList() {
			if len(items) > 0 {
				out[rp.name] = prepareObject(rel.Kind, items[0])
			}
			continue
		}
		sortObjects(items)
		if len(items) > relatedLimit {
			ns.add("related.%s: showing the first %d of %d", rp.name, relatedLimit, len(items))
			items = items[:relatedLimit]
		}
		list := make([]any, len(items))
		for i, o := range items {
			list[i] = prepareObject(rel.Kind, o)
		}
		out[rp.name] = list
	}
}

// filter keeps the candidates for which rp's filter is true, each seen
// as `item` (never modifying the shared list).
func (r *renderer) filter(rp relProg, items []map[string]any) ([]map[string]any, error) {
	var out []map[string]any
	r.act.hasItem = true
	defer func() { r.act.item, r.act.hasItem = nil, false }()
	for _, o := range items {
		r.act.item = prepareObject(rp.rel.Kind, o)
		ok, err := r.cond(rp.filter)
		if err != nil {
			return nil, err
		}
		if ok {
			out = append(out, o)
		}
	}
	return out, nil
}

// resolveMetrics fills r.act.metrics with the metrics need names.
func (r *renderer) resolveMetrics(kp *kindProgs, need refSet, env Env, ns *notes) {
	out := map[string]any{}
	r.act.metrics = out
	if need.empty() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), lookupTimeout)
	defer cancel()
	for _, mp := range kp.metrics {
		if !need.has(mp.name) {
			continue
		}
		out[mp.name] = []any{}
		if env.Lookup == nil {
			ns.add("Prometheus isn't available here: metrics are empty.")
			continue
		}
		v, err := r.eval(mp.query)
		if err != nil {
			ns.add("metrics.%s: %v", mp.name, err)
			continue
		}
		q, _ := v.(string)
		samples, err := env.Lookup.Query(ctx, mp.metric.Instance, q)
		if err != nil {
			if errors.Is(err, ErrNoPrometheus) {
				ns.add("Prometheus isn't available: metrics are empty.")
			} else {
				ns.add("metrics.%s: %v", mp.name, err)
			}
			continue
		}
		list := make([]any, len(samples))
		for i, s := range samples {
			labels := make(map[string]any, len(s.Labels))
			for k, v := range s.Labels {
				labels[k] = v
			}
			list[i] = map[string]any{"labels": labels, "value": s.Value}
		}
		out[mp.name] = list
	}
}

// selectorString turns a selector expression's value (a matchLabels map
// or a LabelSelector object) into a label selector string.
func selectorString(v any) (string, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return "", fmt.Errorf("selector must be a map of labels or a LabelSelector, got %T", v)
	}
	var ls metav1.LabelSelector
	_, hasLabels := m["matchLabels"]
	_, hasExprs := m["matchExpressions"]
	if hasLabels || hasExprs {
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(m, &ls); err != nil {
			return "", fmt.Errorf("selector: %v", err)
		}
	} else {
		ls.MatchLabels = map[string]string{}
		for k, val := range m {
			s, ok := val.(string)
			if !ok {
				return "", fmt.Errorf("selector: label %s must be a string", k)
			}
			ls.MatchLabels[k] = s
		}
	}
	sel, err := metav1.LabelSelectorAsSelector(&ls)
	if err != nil {
		return "", fmt.Errorf("selector: %v", err)
	}
	// An empty selector would match everything: a relation reads nothing.
	return sel.String(), nil
}

func ownedBy(obj map[string]any, uid string) bool {
	md, _ := obj["metadata"].(map[string]any)
	refs, _ := md["ownerReferences"].([]any)
	for _, r := range refs {
		if m, ok := r.(map[string]any); ok && m["uid"] == uid {
			return true
		}
	}
	return false
}

// sortObjects orders objects by namespace and name, so results don't
// depend on the cache's order.
func sortObjects(items []map[string]any) {
	slices.SortStableFunc(items, func(a, b map[string]any) int {
		an, _ := nestedString(a, "metadata", "namespace")
		bn, _ := nestedString(b, "metadata", "namespace")
		if c := strings.Compare(an, bn); c != 0 {
			return c
		}
		a1, _ := nestedString(a, "metadata", "name")
		b1, _ := nestedString(b, "metadata", "name")
		return strings.Compare(a1, b1)
	})
}

// kindName is a kind key's plural for messages: "Secrets",
// "CertificateRequests".
func kindName(key string) string {
	k := key[strings.LastIndexByte(key, '/')+1:]
	switch {
	case strings.HasSuffix(k, "s"):
		return k + "es"
	case strings.HasSuffix(k, "y"):
		return k[:len(k)-1] + "ies"
	}
	return k + "s"
}
