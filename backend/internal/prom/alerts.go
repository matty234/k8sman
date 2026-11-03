package prom

import (
	"cmp"
	"context"
	"encoding/json"
	"net/url"
	"sort"
	"time"
)

// Alert states as shown in the UI.
const (
	StateFiring    = "firing"
	StatePending   = "pending"
	StateSilenced  = "silenced"
	StateInhibited = "inhibited"
)

// ObjectRef points at the Kubernetes object an alert is about.
type ObjectRef struct {
	Group     string `json:"group"`
	Kind      string `json:"kind"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name"`
}

// Alert is one alert instance (one label set).
type Alert struct {
	Fingerprint  string            `json:"fingerprint"`
	Name         string            `json:"alertname"`
	State        string            `json:"state"`
	Severity     string            `json:"severity"`
	Labels       map[string]string `json:"labels"`
	Annotations  map[string]string `json:"annotations"`
	StartsAt     string            `json:"startsAt,omitempty"`
	EndsAt       string            `json:"endsAt,omitempty"`
	UpdatedAt    string            `json:"updatedAt,omitempty"`
	GeneratorURL string            `json:"generatorURL,omitempty"`
	SilencedBy   []string          `json:"silencedBy,omitempty"`
	InhibitedBy  []string          `json:"inhibitedBy,omitempty"`
	Receivers    []string          `json:"receivers,omitempty"`
	// Source is "alertmanager", or "prometheus" for pending alerts (and
	// firing ones when no Alertmanager is reachable).
	Source string `json:"source"`
	// Value is the expression value for Prometheus-sourced alerts.
	Value  string     `json:"value,omitempty"`
	Target *ObjectRef `json:"target,omitempty"`
}

// AlertGroup is every instance of one alertname.
type AlertGroup struct {
	Name     string `json:"alertname"`
	Severity string `json:"severity"` // the most severe instance's
	// State is the "loudest" state of the group (firing > pending > silenced > inhibited).
	State  string         `json:"state"`
	Counts map[string]int `json:"counts"`
	// Summary is the first instance's summary (or description) annotation.
	Summary string  `json:"summary,omitempty"`
	Alerts  []Alert `json:"alerts"`
}

// AlertSummary counts alerts across groups.
type AlertSummary struct {
	Firing    int `json:"firing"`
	Pending   int `json:"pending"`
	Silenced  int `json:"silenced"`
	Inhibited int `json:"inhibited"`
	// Critical counts firing alerts with severity=critical (the nav badge).
	Critical int `json:"critical"`
}

// AlertsResult is the GET /api/prom/alerts payload.
type AlertsResult struct {
	Alertmanager *Instance         `json:"alertmanager,omitempty"`
	Prometheus   *Instance         `json:"prometheus,omitempty"`
	Summary      AlertSummary      `json:"summary"`
	Groups       []AlertGroup      `json:"groups"`
	Errors       map[string]string `json:"errors,omitempty"`
}

// ---- Alertmanager v2 ----------------------------------------------------

type amAlert struct {
	Annotations  map[string]string `json:"annotations"`
	Labels       map[string]string `json:"labels"`
	StartsAt     string            `json:"startsAt"`
	EndsAt       string            `json:"endsAt"`
	UpdatedAt    string            `json:"updatedAt"`
	Fingerprint  string            `json:"fingerprint"`
	GeneratorURL string            `json:"generatorURL"`
	Receivers    []struct {
		Name string `json:"name"`
	} `json:"receivers"`
	Status struct {
		State       string   `json:"state"` // active | suppressed | unprocessed
		SilencedBy  []string `json:"silencedBy"`
		InhibitedBy []string `json:"inhibitedBy"`
		MutedBy     []string `json:"mutedBy"`
	} `json:"status"`
}

func fetchAMAlerts(ctx context.Context, r requester, am *Instance) ([]Alert, error) {
	var raw []amAlert
	if err := getJSON(ctx, r, am, "/api/v2/alerts", url.Values{"silenced": {"true"}, "inhibited": {"true"}, "active": {"true"}}, &raw); err != nil {
		return nil, err
	}
	return convertAMAlerts(raw), nil
}

func convertAMAlerts(raw []amAlert) []Alert {
	out := make([]Alert, 0, len(raw))
	for _, a := range raw {
		state := StateFiring
		switch {
		case len(a.Status.SilencedBy) > 0:
			state = StateSilenced
		case len(a.Status.InhibitedBy) > 0:
			state = StateInhibited
		case a.Status.State == "suppressed":
			state = StateSilenced // muted by a time interval
		}
		al := Alert{
			Fingerprint:  a.Fingerprint,
			Name:         a.Labels["alertname"],
			State:        state,
			Severity:     a.Labels["severity"],
			Labels:       nonNil(a.Labels),
			Annotations:  nonNil(a.Annotations),
			StartsAt:     a.StartsAt,
			EndsAt:       a.EndsAt,
			UpdatedAt:    a.UpdatedAt,
			GeneratorURL: a.GeneratorURL,
			SilencedBy:   a.Status.SilencedBy,
			InhibitedBy:  a.Status.InhibitedBy,
			Source:       KindAlertmanager,
		}
		for _, rc := range a.Receivers {
			al.Receivers = append(al.Receivers, rc.Name)
		}
		al.Target = TargetFor(al.Labels)
		out = append(out, al)
	}
	return out
}

func nonNil(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}

// ---- Prometheus /api/v1/alerts --------------------------------------------

type promAlert struct {
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
	State       string            `json:"state"` // pending | firing
	ActiveAt    string            `json:"activeAt"`
	Value       string            `json:"value"`
}

// fetchPromAlerts returns Prometheus' pending alerts, plus firing ones when
// includeFiring (no Alertmanager to ask).
func fetchPromAlerts(ctx context.Context, r requester, p *Instance, includeFiring bool) ([]Alert, error) {
	data, _, err := promGet(ctx, r, p, "/api/v1/alerts", nil)
	if err != nil {
		return nil, err
	}
	var d struct {
		Alerts []promAlert `json:"alerts"`
	}
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, &UpstreamError{Status: 502, Message: "decode prometheus alerts: " + err.Error()}
	}
	return convertPromAlerts(d.Alerts, includeFiring), nil
}

func convertPromAlerts(raw []promAlert, includeFiring bool) []Alert {
	out := []Alert{}
	for _, a := range raw {
		if a.State != StatePending && !(includeFiring && a.State == StateFiring) {
			continue
		}
		al := Alert{
			Fingerprint: labelsFingerprint(a.Labels),
			Name:        a.Labels["alertname"],
			State:       a.State,
			Severity:    a.Labels["severity"],
			Labels:      nonNil(a.Labels),
			Annotations: nonNil(a.Annotations),
			StartsAt:    a.ActiveAt,
			Value:       a.Value,
			Source:      KindPrometheus,
		}
		al.Target = TargetFor(al.Labels)
		out = append(out, al)
	}
	return out
}

// labelsFingerprint is a stable id for a label set (Prometheus doesn't give one).
func labelsFingerprint(l map[string]string) string {
	keys := make([]string, 0, len(l))
	for k := range l {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var h uint64 = 14695981039346656037
	for _, k := range keys {
		for _, s := range []string{k, "\xff", l[k], "\xfe"} {
			for i := 0; i < len(s); i++ {
				h ^= uint64(s[i])
				h *= 1099511628211
			}
		}
	}
	const hex = "0123456789abcdef"
	b := make([]byte, 16)
	for i := 15; i >= 0; i-- {
		b[i] = hex[h&0xf]
		h >>= 4
	}
	return string(b)
}

// ---- grouping ---------------------------------------------------------------

var severityOrder = map[string]int{"critical": 0, "error": 1, "warning": 2, "info": 3, "": 4, "none": 5}

func sevRank(s string) int {
	if r, ok := severityOrder[s]; ok {
		return r
	}
	return 3 // unknown labels rank like info
}

var stateOrder = map[string]int{StateFiring: 0, StatePending: 1, StateSilenced: 2, StateInhibited: 3}

// GroupAlerts groups alerts by alertname. Groups are ordered by state
// (firing first), then severity, then size; instances by state, severity,
// then most recent.
func GroupAlerts(alerts []Alert) ([]AlertGroup, AlertSummary) {
	var sum AlertSummary
	byName := map[string]*AlertGroup{}
	var order []string
	for _, a := range alerts {
		switch a.State {
		case StateFiring:
			sum.Firing++
			if a.Severity == "critical" {
				sum.Critical++
			}
		case StatePending:
			sum.Pending++
		case StateSilenced:
			sum.Silenced++
		case StateInhibited:
			sum.Inhibited++
		}
		g := byName[a.Name]
		if g == nil {
			g = &AlertGroup{Name: a.Name, Severity: a.Severity, State: a.State, Counts: map[string]int{}}
			byName[a.Name] = g
			order = append(order, a.Name)
		}
		g.Counts[a.State]++
		if sevRank(a.Severity) < sevRank(g.Severity) {
			g.Severity = a.Severity
		}
		if stateOrder[a.State] < stateOrder[g.State] {
			g.State = a.State
		}
		g.Alerts = append(g.Alerts, a)
	}
	groups := make([]AlertGroup, 0, len(order))
	for _, n := range order {
		g := byName[n]
		sort.SliceStable(g.Alerts, func(i, j int) bool {
			x, y := g.Alerts[i], g.Alerts[j]
			if stateOrder[x.State] != stateOrder[y.State] {
				return stateOrder[x.State] < stateOrder[y.State]
			}
			if sevRank(x.Severity) != sevRank(y.Severity) {
				return sevRank(x.Severity) < sevRank(y.Severity)
			}
			if x.StartsAt != y.StartsAt {
				return parseTime(x.StartsAt).After(parseTime(y.StartsAt))
			}
			return x.Fingerprint < y.Fingerprint
		})
		g.Summary = cmp.Or(g.Alerts[0].Annotations["summary"], g.Alerts[0].Annotations["description"], g.Alerts[0].Annotations["message"])
		groups = append(groups, *g)
	}
	sort.SliceStable(groups, func(i, j int) bool {
		x, y := groups[i], groups[j]
		if stateOrder[x.State] != stateOrder[y.State] {
			return stateOrder[x.State] < stateOrder[y.State]
		}
		if sevRank(x.Severity) != sevRank(y.Severity) {
			return sevRank(x.Severity) < sevRank(y.Severity)
		}
		if len(x.Alerts) != len(y.Alerts) {
			return len(x.Alerts) > len(y.Alerts)
		}
		return x.Name < y.Name
	})
	return groups, sum
}

func parseTime(s string) time.Time {
	t, _ := time.Parse(time.RFC3339Nano, s)
	return t
}

// ---- label → object ------------------------------------------------------

// targetLabels maps alert labels to the object they identify, most specific
// first. All but node need a namespace label.
var targetLabels = []struct {
	label, group, kind string
}{
	// Workload labels first: kube-state-metrics alerts about a Deployment
	// also carry pod=<the kube-state-metrics pod> from the scrape target.
	{"deployment", "apps", "Deployment"},
	{"statefulset", "apps", "StatefulSet"},
	{"daemonset", "apps", "DaemonSet"},
	{"replicaset", "apps", "ReplicaSet"},
	{"job_name", "batch", "Job"},
	{"cronjob", "batch", "CronJob"},
	{"horizontalpodautoscaler", "autoscaling", "HorizontalPodAutoscaler"},
	{"persistentvolumeclaim", "", "PersistentVolumeClaim"},
	{"poddisruptionbudget", "policy", "PodDisruptionBudget"},
	{"pod", "", "Pod"},
	{"service", "", "Service"},
}

// TargetFor returns the Kubernetes object an alert's labels identify, or nil.
// Namespaced objects need a namespace label; a node label maps to a Node;
// a bare namespace label maps to the Namespace.
func TargetFor(l map[string]string) *ObjectRef {
	ns := l["namespace"]
	if ns == "" {
		ns = l["exported_namespace"]
	}
	if ns != "" {
		for _, t := range targetLabels {
			if v := l[t.label]; v != "" {
				// TargetDown and friends carry service=<scrape service>, which is
				// still the most useful link when nothing more specific exists.
				return &ObjectRef{Group: t.group, Kind: t.kind, Namespace: ns, Name: v}
			}
		}
	}
	if n := l["node"]; n != "" {
		return &ObjectRef{Kind: "Node", Name: n}
	}
	if pv := l["persistentvolume"]; pv != "" {
		return &ObjectRef{Kind: "PersistentVolume", Name: pv}
	}
	if ns != "" {
		return &ObjectRef{Kind: "Namespace", Name: ns}
	}
	return nil
}
