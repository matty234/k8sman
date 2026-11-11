package prom

import (
	"context"
	"fmt"
	"sort"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"

	"github.com/matty234/k8sman/backend/internal/kapi"
)

// More operator resources.
var (
	ServiceMonitorGVR     = kapi.ServiceMonitors.GVR()
	PodMonitorGVR         = kapi.PodMonitors.GVR()
	ProbeGVR              = kapi.Probes.GVR()
	ScrapeConfigGVR       = kapi.ScrapeConfigs.GVR()
	AlertmanagerConfigGVR = kapi.AlertmanagerConfigs.GVR()
)

// selectable describes how a Prometheus (or Alertmanager) custom resource
// picks up one kind of object: spec.<field>Selector and
// spec.<field>NamespaceSelector.
type selectable struct {
	Kind  string
	GVR   schema.GroupVersionResource
	Field string
}

var promSelectables = []selectable{
	{"ServiceMonitor", ServiceMonitorGVR, "serviceMonitor"},
	{"PodMonitor", PodMonitorGVR, "podMonitor"},
	{"Probe", ProbeGVR, "probe"},
	{"ScrapeConfig", ScrapeConfigGVR, "scrapeConfig"},
	{"PrometheusRule", PrometheusRuleGVR, "rule"},
}

var amSelectable = selectable{"AlertmanagerConfig", AlertmanagerConfigGVR, "alertmanagerConfig"}

// selectableFor returns how kind is selected, and by which CR kind.
func selectableFor(kind string) (selectable, string, bool) {
	if strings.EqualFold(kind, amSelectable.Kind) {
		return amSelectable, "Alertmanager", true
	}
	for _, s := range promSelectables {
		if strings.EqualFold(kind, s.Kind) {
			return s, "Prometheus", true
		}
	}
	return selectable{}, "", false
}

// labelSelector reads a LabelSelector at m[key]. present is false when the
// key is absent or null (which the operator treats differently from {}).
func labelSelector(m map[string]any, key string) (sel *metav1.LabelSelector, present bool) {
	raw, ok := m[key].(map[string]any)
	if !ok {
		return nil, false
	}
	sel = &metav1.LabelSelector{}
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(raw, sel); err != nil {
		// An unparseable selector selects nothing.
		return &metav1.LabelSelector{MatchExpressions: []metav1.LabelSelectorRequirement{{Key: "-", Operator: metav1.LabelSelectorOpIn}}}, true
	}
	return sel, true
}

// explainSelector evaluates sel against l and lists the terms that fail,
// e.g. `release=prod (has release=dev)`. A nil or empty selector matches.
func explainSelector(sel *metav1.LabelSelector, l map[string]string) (ok bool, failing []string, passing int) {
	if sel == nil {
		return true, nil, 0
	}
	keys := make([]string, 0, len(sel.MatchLabels))
	for k := range sel.MatchLabels {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		want := sel.MatchLabels[k]
		got, has := l[k]
		switch {
		case has && got == want:
			passing++
		case has:
			failing = append(failing, fmt.Sprintf("%s=%s (has %s)", k, want, got))
		default:
			failing = append(failing, fmt.Sprintf("%s=%s (missing)", k, want))
		}
	}
	for _, e := range sel.MatchExpressions {
		s, err := metav1.LabelSelectorAsSelector(&metav1.LabelSelector{MatchExpressions: []metav1.LabelSelectorRequirement{e}})
		desc := e.Key + " " + strings.ToLower(string(e.Operator))
		if len(e.Values) > 0 {
			desc += " (" + strings.Join(e.Values, ", ") + ")"
		}
		if err == nil && s.Matches(labels.Set(l)) {
			passing++
		} else {
			failing = append(failing, desc)
		}
	}
	return len(failing) == 0, failing, passing
}

// crSelects reports whether the Prometheus/Alertmanager spec selects an
// object of sel's kind with labels objLabels in namespace objNS. crNS is the
// custom resource's namespace; nsLabels returns a namespace's labels.
// Operator semantics: a missing <kind>Selector selects nothing and {}
// everything; a missing namespace selector means the CR's own namespace.
func crSelects(spec map[string]any, crNS string, sel selectable, objNS string, objLabels map[string]string, nsLabels func(string) map[string]string) (bool, string) {
	s, present := labelSelector(spec, sel.Field+"Selector")
	if !present {
		return false, sel.Field + "Selector is not set, so no " + sel.Kind + " is selected"
	}
	if ok, failing, _ := explainSelector(s, objLabels); !ok {
		return false, sel.Field + "Selector wants " + strings.Join(failing, ", ")
	}
	nsSel, present := labelSelector(spec, sel.Field+"NamespaceSelector")
	if !present {
		if objNS != crNS {
			return false, sel.Field + "NamespaceSelector is not set, so only " + crNS + " is watched"
		}
		return true, ""
	}
	if ok, failing, _ := explainSelector(nsSel, nsLabels(objNS)); !ok {
		return false, sel.Field + "NamespaceSelector wants " + strings.Join(failing, ", ")
	}
	return true, ""
}

// crObject is the slice of a custom resource the analysis needs.
type crObject struct {
	Kind, Namespace, Name string
	Labels                map[string]string
	Spec                  map[string]any
}

func toCR(kind string, u *unstructured.Unstructured) crObject {
	spec, _ := u.Object["spec"].(map[string]any)
	if spec == nil {
		spec = map[string]any{}
	}
	return crObject{Kind: kind, Namespace: u.GetNamespace(), Name: u.GetName(), Labels: u.GetLabels(), Spec: spec}
}

func listCRs(ctx context.Context, dyn dynamic.Interface, kind string, gvr schema.GroupVersionResource) ([]crObject, error) {
	l, err := dyn.Resource(gvr).Namespace("").List(ctx, metav1.ListOptions{ResourceVersion: "0"})
	if err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, err
	}
	out := make([]crObject, 0, len(l.Items))
	for i := range l.Items {
		out = append(out, toCR(kind, &l.Items[i]))
	}
	return out, nil
}

// nsLabeler returns namespace labels, listing namespaces once on first use.
func nsLabeler(ctx context.Context, typed kubernetes.Interface) func(string) map[string]string {
	var cache map[string]map[string]string
	return func(ns string) map[string]string {
		if cache == nil {
			cache = map[string]map[string]string{}
			if l, err := typed.CoreV1().Namespaces().List(ctx, metav1.ListOptions{ResourceVersion: "0"}); err == nil {
				for _, n := range l.Items {
					cache[n.Name] = n.Labels
				}
			}
		}
		if l, ok := cache[ns]; ok {
			return l
		}
		// Unknown (or unlistable): the label every namespace carries.
		return map[string]string{"kubernetes.io/metadata.name": ns}
	}
}

// monitorNamespaces reports whether a monitor's spec.namespaceSelector
// (`any`, `matchNames`, else its own namespace) covers ns.
func monitorCoversNamespace(spec map[string]any, monNS, ns string) (bool, string) {
	sel, _ := spec["namespaceSelector"].(map[string]any)
	if any, _ := sel["any"].(bool); any {
		return true, "any namespace"
	}
	if names, ok := sel["matchNames"].([]any); ok && len(names) > 0 {
		var l []string
		for _, n := range names {
			s := fmt.Sprint(n)
			l = append(l, s)
			if s == ns {
				return true, "namespaces " + strings.Join(namesOf(names), ", ")
			}
		}
		return false, "only looks in " + strings.Join(l, ", ")
	}
	if monNS == ns {
		return true, "its own namespace"
	}
	return false, "only looks in its own namespace, " + monNS
}

func namesOf(l []any) []string {
	out := make([]string, len(l))
	for i, v := range l {
		out[i] = fmt.Sprint(v)
	}
	return out
}
