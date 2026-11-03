package prom

import (
	"context"
	"encoding/json"
	"net/url"
	"path"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/dynamic"
)

// RuleSource is the PrometheusRule (or other file) a rule group came from.
type RuleSource struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
}

// RuleAlert is an active (pending/firing) alert of an alerting rule.
type RuleAlert struct {
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations,omitempty"`
	State       string            `json:"state"`
	ActiveAt    string            `json:"activeAt,omitempty"`
	Value       string            `json:"value,omitempty"`
}

// Rule is one alerting or recording rule with its live state.
type Rule struct {
	Type string `json:"type"` // alerting | recording
	Name string `json:"name"`
	// Query is the PromQL expression.
	Query string `json:"query"`
	// Duration is the alerting rule's `for`, in seconds.
	Duration       float64           `json:"duration,omitempty"`
	KeepFiringFor  float64           `json:"keepFiringFor,omitempty"`
	Labels         map[string]string `json:"labels,omitempty"`
	Annotations    map[string]string `json:"annotations,omitempty"`
	State          string            `json:"state,omitempty"` // inactive | pending | firing (alerting only)
	Health         string            `json:"health"`          // ok | err | unknown
	LastError      string            `json:"lastError,omitempty"`
	LastEvaluation string            `json:"lastEvaluation,omitempty"`
	EvaluationTime float64           `json:"evaluationTime,omitempty"`
	Alerts         []RuleAlert       `json:"alerts,omitempty"`
}

// RuleGroup is a Prometheus rule group.
type RuleGroup struct {
	Name           string      `json:"name"`
	File           string      `json:"file"`
	Interval       float64     `json:"interval"`
	LastEvaluation string      `json:"lastEvaluation,omitempty"`
	EvaluationTime float64     `json:"evaluationTime,omitempty"`
	Source         *RuleSource `json:"source,omitempty"`
	Rules          []Rule      `json:"rules"`
}

// RulesResult is the GET /api/prom/rules payload.
type RulesResult struct {
	Prometheus *Instance   `json:"prometheus"`
	Groups     []RuleGroup `json:"groups"`
	Counts     struct {
		Firing   int `json:"firing"`
		Pending  int `json:"pending"`
		Inactive int `json:"inactive"`
		Errors   int `json:"errors"`
	} `json:"counts"`
}

func fetchRules(ctx context.Context, r requester, p *Instance) ([]RuleGroup, error) {
	data, _, err := promGet(ctx, r, p, "/api/v1/rules", url.Values{})
	if err != nil {
		return nil, err
	}
	var d struct {
		Groups []RuleGroup `json:"groups"`
	}
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, &UpstreamError{Status: 502, Message: "decode prometheus rules: " + err.Error()}
	}
	return d.Groups, nil
}

// promRuleRef is a PrometheusRule we can match rule files against.
type promRuleRef struct {
	Namespace, Name, UID string
	Groups               []string
}

func listPrometheusRules(ctx context.Context, dyn dynamic.Interface, ns string) ([]promRuleRef, error) {
	l, err := dyn.Resource(PrometheusRuleGVR).Namespace(ns).List(ctx, metav1.ListOptions{ResourceVersion: "0"})
	if err != nil {
		return nil, err
	}
	out := make([]promRuleRef, 0, len(l.Items))
	for _, it := range l.Items {
		ref := promRuleRef{Namespace: it.GetNamespace(), Name: it.GetName(), UID: string(it.GetUID())}
		if spec, ok := it.Object["spec"].(map[string]any); ok {
			if gs, ok := spec["groups"].([]any); ok {
				for _, g := range gs {
					if gm, ok := g.(map[string]any); ok {
						if n, ok := gm["name"].(string); ok {
							ref.Groups = append(ref.Groups, n)
						}
					}
				}
			}
		}
		out = append(out, ref)
	}
	return out, nil
}

// MapRuleSources fills each group's Source. The operator writes each
// PrometheusRule to `<ruleFilesDir>/<namespace>-<name>-<uid>.yaml`, so the
// file name identifies it exactly; failing that, a group name that only one
// PrometheusRule defines is used.
func MapRuleSources(groups []RuleGroup, rules []promRuleRef) {
	byFile := map[string]promRuleRef{}
	byGroup := map[string][]promRuleRef{}
	for _, r := range rules {
		byFile[r.Namespace+"-"+r.Name+"-"+r.UID] = r
		for _, g := range r.Groups {
			byGroup[g] = append(byGroup[g], r)
		}
	}
	for i := range groups {
		g := &groups[i]
		base := strings.TrimSuffix(strings.TrimSuffix(path.Base(g.File), ".yaml"), ".yml")
		if r, ok := byFile[base]; ok {
			g.Source = &RuleSource{Namespace: r.Namespace, Name: r.Name}
			continue
		}
		if c := byGroup[g.Name]; len(c) == 1 {
			g.Source = &RuleSource{Namespace: c[0].Namespace, Name: c[0].Name}
			continue
		}
		// Without UIDs (RBAC, or a non-operator setup) still try the
		// "<namespace>-<name>-" prefix for each candidate.
		for _, r := range rules {
			if strings.HasPrefix(base, r.Namespace+"-"+r.Name+"-") && len(base) == len(r.Namespace)+len(r.Name)+2+36 {
				g.Source = &RuleSource{Namespace: r.Namespace, Name: r.Name}
				break
			}
		}
	}
}

// FilterRuleGroups keeps groups from one PrometheusRule (namespace/name),
// or from any rule in a namespace when name is empty.
func FilterRuleGroups(groups []RuleGroup, ns, name string) []RuleGroup {
	if ns == "" && name == "" {
		return groups
	}
	out := []RuleGroup{}
	for _, g := range groups {
		if g.Source == nil {
			continue
		}
		if (ns == "" || g.Source.Namespace == ns) && (name == "" || g.Source.Name == name) {
			out = append(out, g)
		}
	}
	return out
}

func countRules(res *RulesResult) {
	for _, g := range res.Groups {
		for _, r := range g.Rules {
			if r.Health == "err" {
				res.Counts.Errors++
			}
			if r.Type != "alerting" {
				continue
			}
			switch r.State {
			case StateFiring:
				res.Counts.Firing++
			case StatePending:
				res.Counts.Pending++
			default:
				res.Counts.Inactive++
			}
		}
	}
}
