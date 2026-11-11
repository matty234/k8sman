package prom

import (
	"context"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/matty234/k8sman/backend/internal/httpx"
)

// RuleMatch is a rule that (heuristically) concerns the inspected object,
// with the reasons it was picked.
type RuleMatch struct {
	Group  string      `json:"group"`
	File   string      `json:"file,omitempty"`
	Source *RuleSource `json:"source,omitempty"`
	Rule   Rule        `json:"rule"`
	// ActiveAlerts counts the rule's pending/firing alerts for the object.
	ActiveAlerts int      `json:"activeAlerts"`
	Reasons      []string `json:"reasons"`
}

// AppliesResult is the GET /api/prom/applies payload: alerts about the
// object and rules that refer to it.
type AppliesResult struct {
	Prometheus   *Instance `json:"prometheus,omitempty"`
	Alertmanager *Instance `json:"alertmanager,omitempty"`
	// Alerts are firing, pending, silenced or inhibited alerts whose labels
	// name the object (or one of its pods).
	Alerts []Alert `json:"alerts"`
	// Rules mention the object's jobs, namespace or name; a heuristic.
	Rules      []RuleMatch       `json:"rules"`
	RulesTotal int               `json:"rulesTotal"`
	Jobs       []string          `json:"jobs"`
	Errors     map[string]string `json:"errors,omitempty"`
}

// alertConcerns reports whether an alert's labels name the subject. A pod
// label decides on its own (kube-state-metrics alerts about a workload
// carry the exporter's pod label, so a workload label is checked first).
func (s *subject) alertConcerns(l map[string]string, jobs map[string]bool) bool {
	ns := l["namespace"]
	if ns == "" {
		ns = l["exported_namespace"]
	}
	if ns != s.Namespace {
		return false
	}
	if s.WorkloadLabel != "" && l[s.WorkloadLabel] == s.Name {
		return true
	}
	if s.Kind == "Deployment" && strings.HasPrefix(l["replicaset"], s.Name+"-") {
		return true
	}
	if p := l["pod"]; p != "" {
		return s.Pods[p]
	}
	if svc := l["service"]; svc != "" {
		for _, sv := range s.Services {
			if sv.Name == svc {
				return true
			}
		}
		return false
	}
	return l["job"] != "" && jobs[l["job"]]
}

// matcherRe finds `label op "value"` in PromQL (and rule label values).
var matcherRe = regexp.MustCompile(`\b(job|namespace|pod|container|service|deployment|statefulset|daemonset|replicaset|job_name)\s*(=~|!~|!=|=)\s*"((?:[^"\\]|\\.)*)"`)

// trivialRe are regexes that match anything, which say nothing about an object.
func trivialRe(v string) bool {
	switch v {
	case "", ".*", ".+", ".*.*":
		return true
	}
	return false
}

func reMatches(pattern, v string) bool {
	re, err := regexp.Compile("^(?:" + pattern + ")$")
	return err == nil && re.MatchString(v)
}

// ruleReasons says why rule r concerns the subject: it mentions one of the
// object's jobs, its namespace, or its (pods' / workload's) name in a
// matcher. Only positive (= and =~) matchers count.
func (s *subject) ruleReasons(r Rule, jobs map[string]bool) []string {
	var out []string
	seen := map[string]bool{}
	add := func(reason string) {
		if !seen[reason] {
			seen[reason] = true
			out = append(out, reason)
		}
	}
	names := map[string]bool{s.Name: true}
	for p := range s.Pods {
		names[p] = true
	}
	check := func(label, op, val string) {
		if op != "=" && op != "=~" {
			return
		}
		if op == "=~" && trivialRe(val) {
			return
		}
		hit := func(x string) bool {
			if op == "=" {
				return val == x
			}
			return reMatches(val, x)
		}
		switch label {
		case "job":
			for j := range jobs {
				if hit(j) {
					add(`mentions job` + op + `"` + val + `"`)
				}
			}
		case "namespace":
			if hit(s.Namespace) {
				add(`mentions namespace` + op + `"` + val + `"`)
			}
		default:
			if label == "service" {
				for _, sv := range s.Services {
					if hit(sv.Name) {
						add(`mentions service` + op + `"` + val + `"`)
					}
				}
				return
			}
			if label == "container" {
				return // container names are too generic to identify an object
			}
			for n := range names {
				if hit(n) {
					add(`mentions ` + label + op + `"` + val + `"`)
					break
				}
			}
		}
	}
	for _, m := range matcherRe.FindAllStringSubmatch(r.Query, -1) {
		check(m[1], m[2], m[3])
	}
	for _, k := range []string{"job", "namespace", "pod", "service", s.WorkloadLabel} {
		if v, ok := r.Labels[k]; ok && k != "" {
			check(k, "=", v)
		}
	}
	return out
}

// MatchRules picks rules that concern the subject: those with an active
// alert for it, then those mentioning its jobs, namespace or name.
func MatchRules(groups []RuleGroup, s *subject, jobs map[string]bool) ([]RuleMatch, int) {
	var out []RuleMatch
	for _, g := range groups {
		for _, r := range g.Rules {
			reasons := s.ruleReasons(r, jobs)
			active := 0
			for _, a := range r.Alerts {
				if s.alertConcerns(a.Labels, jobs) {
					active++
				}
			}
			if active > 0 {
				reasons = append([]string{"has an alert for this " + strings.ToLower(s.Kind)}, reasons...)
			}
			if len(reasons) == 0 {
				continue
			}
			rr := r
			rr.Alerts = nil
			out = append(out, RuleMatch{Group: g.Name, File: g.File, Source: g.Source, Rule: rr, ActiveAlerts: active, Reasons: reasons})
		}
	}
	rank := func(m RuleMatch) int {
		switch {
		case m.ActiveAlerts > 0 && m.Rule.State == StateFiring:
			return 0
		case m.ActiveAlerts > 0:
			return 1
		case m.Rule.Type == "alerting":
			return 2
		}
		return 3
	}
	sort.SliceStable(out, func(i, j int) bool {
		if a, b := rank(out[i]), rank(out[j]); a != b {
			return a < b
		}
		if out[i].Group != out[j].Group {
			return out[i].Group < out[j].Group
		}
		return out[i].Rule.Name < out[j].Rule.Name
	})
	total := len(out)
	if total > maxAppliesRules {
		out = out[:maxAppliesRules]
	}
	return out, total
}

// applies builds the GET /api/prom/applies answer.
func (h *Handler) applies(ctx context.Context, e env, kind, ns, name, instance string) (*AppliesResult, error) {
	s, err := resolveSubject(ctx, e.typed, kind, ns, name)
	if err != nil {
		return nil, err
	}
	res := &AppliesResult{Alerts: []Alert{}, Rules: []RuleMatch{}, Jobs: []string{}, Errors: map[string]string{}}
	st := h.disc.get(ctx, e, false)
	p := st.Default(KindPrometheus, instance)
	res.Prometheus = p

	var (
		wg      sync.WaitGroup
		targets []promTarget
		groups  []RuleGroup
		alerts  *AlertsResult
		tErr    error
		rErr    error
	)
	if p != nil {
		wg.Add(2)
		go func() { defer wg.Done(); targets, tErr = cachedTargets(ctx, e, p) }()
		go func() { defer wg.Done(); groups, rErr = cachedRules(ctx, e, p) }()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		alerts, _ = cachedResult(ctx, &alertsCache, e.key+"|alerts|"+instance, func(ctx context.Context) (*AlertsResult, error) {
			return h.alerts(ctx, e, "", instance), nil
		})
	}()
	wg.Wait()

	// The object's jobs come from its scrape targets.
	jobs := map[string]bool{}
	if tErr == nil && p != nil {
		var sr ScrapeResult
		MatchTargets(targets, s, &sr)
		for _, j := range sr.Jobs {
			jobs[j] = true
		}
		res.Jobs = append(res.Jobs, sr.Jobs...)
	}
	if alerts != nil {
		res.Alertmanager = alerts.Alertmanager
		for k, v := range alerts.Errors {
			res.Errors["alerts."+k] = v
		}
		for _, g := range alerts.Groups {
			for _, a := range g.Alerts {
				if s.alertConcerns(a.Labels, jobs) {
					res.Alerts = append(res.Alerts, a)
				}
			}
		}
		if len(res.Alerts) > maxAppliesAlerts {
			res.Alerts = res.Alerts[:maxAppliesAlerts]
		}
	}
	switch {
	case p == nil:
		res.Errors["prometheus"] = "no Prometheus found in the cluster"
	case rErr != nil:
		res.Errors["rules"] = rErr.Error()
	default:
		res.Rules, res.RulesTotal = MatchRules(groups, s, jobs)
		if res.Rules == nil {
			res.Rules = []RuleMatch{}
		}
	}
	if len(res.Errors) == 0 {
		res.Errors = nil
	}
	return res, nil
}

func (h *Handler) handleApplies(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	kind, ns, name := q.Get("kind"), q.Get("namespace"), q.Get("name")
	if kind == "" || ns == "" || name == "" {
		writeErr(w, httpx.BadRequest("kind, namespace and name are required"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	res, err := h.applies(ctx, h.env(), kind, ns, name, q.Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, res)
}
