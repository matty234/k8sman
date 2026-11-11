package prom

import (
	"cmp"
	"context"
	"fmt"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/matty234/k8sman/backend/internal/httpx"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/kubernetes"
)

// Limits that keep the inspector's answers small on big clusters.
const (
	maxSubjectPods    = 500
	maxObjectTargets  = 200
	maxDroppedPools   = 10
	maxMonitorChecks  = 12
	maxAppliesAlerts  = 100
	maxAppliesRules   = 100
	maxSelectionItems = 300
)

// subject is the object the inspector's Monitoring tab is about, resolved
// to the pods (and Services) Prometheus would scrape for it.
type subject struct {
	Kind, Namespace, Name string
	// Pods are the pod names (the pod itself, or a workload's / Service's pods).
	Pods map[string]bool
	// PodLabels, Annotations and Ports describe one pod (or the pod
	// template) for the monitor checks; nil labels skip PodMonitors.
	PodLabels   map[string]string
	Annotations map[string]string
	Ports       []corev1.ContainerPort
	// Services front the pods (or are the Service itself).
	Services []corev1.Service
	// WorkloadLabel is the alert/metric label naming the workload
	// (deployment, statefulset, ...); "" for pods and Services.
	WorkloadLabel string
}

// workloadLabels: the kube-state-metrics label for each kind.
var workloadLabels = map[string]string{
	"Deployment": "deployment", "StatefulSet": "statefulset", "DaemonSet": "daemonset",
	"ReplicaSet": "replicaset", "Job": "job_name",
}

// resolveSubject loads the object and the pods and Services behind it.
func resolveSubject(ctx context.Context, typed kubernetes.Interface, kind, ns, name string) (*subject, error) {
	s := &subject{Kind: kind, Namespace: ns, Name: name, Pods: map[string]bool{}, WorkloadLabel: workloadLabels[kind]}
	var (
		sel      *metav1.LabelSelector
		template *corev1.PodTemplateSpec
	)
	get := metav1.GetOptions{}
	switch kind {
	case "Pod":
		p, err := typed.CoreV1().Pods(ns).Get(ctx, name, get)
		if err != nil {
			return nil, err
		}
		s.Pods[p.Name] = true
		template = &corev1.PodTemplateSpec{ObjectMeta: p.ObjectMeta, Spec: p.Spec}
	case "Deployment":
		o, err := typed.AppsV1().Deployments(ns).Get(ctx, name, get)
		if err != nil {
			return nil, err
		}
		sel, template = o.Spec.Selector, &o.Spec.Template
	case "StatefulSet":
		o, err := typed.AppsV1().StatefulSets(ns).Get(ctx, name, get)
		if err != nil {
			return nil, err
		}
		sel, template = o.Spec.Selector, &o.Spec.Template
	case "DaemonSet":
		o, err := typed.AppsV1().DaemonSets(ns).Get(ctx, name, get)
		if err != nil {
			return nil, err
		}
		sel, template = o.Spec.Selector, &o.Spec.Template
	case "ReplicaSet":
		o, err := typed.AppsV1().ReplicaSets(ns).Get(ctx, name, get)
		if err != nil {
			return nil, err
		}
		sel, template = o.Spec.Selector, &o.Spec.Template
	case "Job":
		o, err := typed.BatchV1().Jobs(ns).Get(ctx, name, get)
		if err != nil {
			return nil, err
		}
		sel, template = o.Spec.Selector, &o.Spec.Template
	case "Service":
		o, err := typed.CoreV1().Services(ns).Get(ctx, name, get)
		if err != nil {
			return nil, err
		}
		s.Services = []corev1.Service{*o}
		if len(o.Spec.Selector) > 0 {
			sel = &metav1.LabelSelector{MatchLabels: o.Spec.Selector}
		}
	default:
		return nil, httpx.BadRequest("monitoring isn't shown for %s", kind)
	}
	if sel != nil {
		ls, err := metav1.LabelSelectorAsSelector(sel)
		if err == nil && !ls.Empty() {
			pods, err := typed.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: ls.String(), ResourceVersion: "0", Limit: maxSubjectPods})
			if err == nil {
				for i, p := range pods.Items {
					s.Pods[p.Name] = true
					if template == nil && i == 0 {
						template = &corev1.PodTemplateSpec{ObjectMeta: p.ObjectMeta, Spec: p.Spec}
					}
				}
			}
		}
	}
	if template != nil {
		s.PodLabels = nonNil(template.Labels)
		s.Annotations = template.Annotations
		for _, c := range template.Spec.Containers {
			s.Ports = append(s.Ports, c.Ports...)
		}
		// Restartable init containers (sidecars) serve metrics too.
		for _, c := range template.Spec.InitContainers {
			s.Ports = append(s.Ports, c.Ports...)
		}
	}
	if kind != "Service" && s.PodLabels != nil {
		svcs, err := typed.CoreV1().Services(ns).List(ctx, metav1.ListOptions{ResourceVersion: "0"})
		if err == nil {
			for _, sv := range svcs.Items {
				if len(sv.Spec.Selector) > 0 && labels.SelectorFromSet(sv.Spec.Selector).Matches(labels.Set(s.PodLabels)) {
					s.Services = append(s.Services, sv)
				}
			}
		}
	}
	return s, nil
}

func (s *subject) serviceNames() []string {
	out := make([]string, 0, len(s.Services))
	for _, sv := range s.Services {
		out = append(out, sv.Name)
	}
	return out
}

// targetObject is what a scrape target points at: its namespace, pod and
// Service, from the discovered (__meta_kubernetes_*) labels, else the
// target labels the operator's relabelling sets.
func targetObject(t promTarget) (ns, pod, svc string) {
	d := t.DiscoveredLabels
	ns = cmp.Or(d["__meta_kubernetes_namespace"], t.Labels["namespace"])
	pod = cmp.Or(d["__meta_kubernetes_pod_name"], t.Labels["pod"])
	svc = cmp.Or(d["__meta_kubernetes_service_name"], t.Labels["service"])
	return
}

// matches reports whether target t scrapes the subject: one of its pods,
// or (for a Service) any endpoint of the Service.
func (s *subject) matches(t promTarget) bool {
	ns, pod, svc := targetObject(t)
	if ns != s.Namespace {
		return false
	}
	if pod != "" && s.Pods[pod] {
		return true
	}
	return s.Kind == "Service" && svc == s.Name
}

// ObjectTarget is a scrape target of the inspected object, with the config
// that produced it.
type ObjectTarget struct {
	Target
	Job     string   `json:"job"`
	Monitor *Monitor `json:"monitor,omitempty"`
}

// DroppedPool is a scrape pool whose service discovery found the object
// but whose relabelling dropped it (no active target from that pool).
type DroppedPool struct {
	ScrapePool string   `json:"scrapePool"`
	Monitor    *Monitor `json:"monitor,omitempty"`
	// Ports are the port names discovery offered (endpoint or container).
	Ports    []string `json:"ports,omitempty"`
	Services []string `json:"services,omitempty"`
	Count    int      `json:"count"`
}

// Check is one condition of a monitor picking up the object.
type Check struct {
	Name   string `json:"name"` // namespace | selector | port | prometheus
	OK     bool   `json:"ok"`
	Detail string `json:"detail,omitempty"`
}

// MonitorCheck is how one ServiceMonitor / PodMonitor relates to the object:
// whether it matches it, and if not, which checks fail.
type MonitorCheck struct {
	Kind      string `json:"kind"`
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	// Via is the Service a ServiceMonitor was checked against.
	Via *ObjectRef `json:"via,omitempty"`
	// Matches: every check passes.
	Matches bool `json:"matches"`
	// Scraping: Prometheus has active targets from it for the object.
	Scraping bool    `json:"scraping"`
	Checks   []Check `json:"checks"`
}

// ScrapeResult is the GET /api/prom/scrape payload: is this object
// scraped, by what, and if not, why.
type ScrapeResult struct {
	Prometheus *Instance `json:"prometheus,omitempty"`
	Kind       string    `json:"kind"`
	Namespace  string    `json:"namespace"`
	Name       string    `json:"name"`
	Pods       int       `json:"pods"`
	Services   []string  `json:"services"`
	Up         int       `json:"up"`
	Down       int       `json:"down"`
	Unknown    int       `json:"unknown"`
	// Total is the number of matching targets; Targets holds at most
	// maxObjectTargets of them, down first.
	Total    int            `json:"total"`
	Targets  []ObjectTarget `json:"targets"`
	Jobs     []string       `json:"jobs"`
	Dropped  []DroppedPool  `json:"dropped"`
	Monitors []MonitorCheck `json:"monitors"`
	// Hints are plain-language notes (e.g. "no Service selects this pod").
	Hints  []string          `json:"hints"`
	Errors map[string]string `json:"errors,omitempty"`
}

// MatchTargets returns the subject's active targets (down first, capped)
// with their monitors, and the totals.
func MatchTargets(raw []promTarget, s *subject, res *ScrapeResult) {
	jobs := map[string]bool{}
	for _, t := range raw {
		if !s.matches(t) {
			continue
		}
		res.Total++
		switch t.Health {
		case "up":
			res.Up++
		case "down":
			res.Down++
		default:
			res.Unknown++
		}
		labels := nonNil(t.Labels)
		job := labels["job"]
		if job != "" {
			jobs[job] = true
		}
		res.Targets = append(res.Targets, ObjectTarget{
			Target: Target{
				ScrapePool: t.ScrapePool, ScrapeURL: t.ScrapeURL, Health: t.Health, LastError: t.LastError,
				LastScrape: t.LastScrape, LastScrapeDuration: t.LastScrapeDuration, ScrapeInterval: t.ScrapeInterval,
				Labels: labels, Target: scrapeTargetRef(labels),
			},
			Job: job, Monitor: MonitorForPool(t.ScrapePool),
		})
	}
	sort.SliceStable(res.Targets, func(i, j int) bool {
		x, y := res.Targets[i], res.Targets[j]
		if (x.Health == "down") != (y.Health == "down") {
			return x.Health == "down"
		}
		if x.ScrapePool != y.ScrapePool {
			return x.ScrapePool < y.ScrapePool
		}
		return x.ScrapeURL < y.ScrapeURL
	})
	if len(res.Targets) > maxObjectTargets {
		res.Targets = res.Targets[:maxObjectTargets]
	}
	for j := range jobs {
		res.Jobs = append(res.Jobs, j)
	}
	sort.Strings(res.Jobs)
}

// MatchDropped lists pools that discovered the subject but dropped it, other
// than pools that scrape it anyway (endpoint discovery offers every port and
// relabelling keeps only the monitor's, so a scraped pod is also "dropped"
// on its other ports).
func MatchDropped(raw []promTarget, s *subject, res *ScrapeResult) {
	active := map[string]bool{}
	for _, t := range res.Targets {
		active[t.ScrapePool] = true
	}
	byPool := map[string]*DroppedPool{}
	for _, t := range raw {
		if t.ScrapePool == "" || active[t.ScrapePool] || !s.matches(t) {
			continue
		}
		p := byPool[t.ScrapePool]
		if p == nil {
			p = &DroppedPool{ScrapePool: t.ScrapePool, Monitor: MonitorForPool(t.ScrapePool)}
			byPool[t.ScrapePool] = p
		}
		p.Count++
		d := t.DiscoveredLabels
		if port := cmp.Or(d["__meta_kubernetes_endpoint_port_name"], d["__meta_kubernetes_pod_container_port_name"], d["__meta_kubernetes_pod_container_port_number"]); port != "" && !slices.Contains(p.Ports, port) {
			p.Ports = append(p.Ports, port)
		}
		if svc := d["__meta_kubernetes_service_name"]; svc != "" && !slices.Contains(p.Services, svc) {
			p.Services = append(p.Services, svc)
		}
	}
	for _, p := range byPool {
		sort.Strings(p.Ports)
		sort.Strings(p.Services)
		res.Dropped = append(res.Dropped, *p)
	}
	sort.Slice(res.Dropped, func(i, j int) bool { return res.Dropped[i].ScrapePool < res.Dropped[j].ScrapePool })
	if len(res.Dropped) > maxDroppedPools {
		res.Dropped = res.Dropped[:maxDroppedPools]
	}
}

// monitorInputs are the custom resources the monitor checks read.
type monitorInputs struct {
	ServiceMonitors, PodMonitors, Prometheuses []crObject
	NSLabels                                   func(string) map[string]string
}

// CheckMonitors evaluates every ServiceMonitor and PodMonitor against the
// subject, keeping those that match and those that come close (their
// selector matches, or shares a label with the object, in a namespace they
// watch). Matches come first, then the closest misses.
func CheckMonitors(in monitorInputs, s *subject, scrapedBy map[string]bool) []MonitorCheck {
	var out []MonitorCheck
	consider := func(c MonitorCheck, close bool) {
		c.Scraping = scrapedBy[c.Kind+"/"+c.Namespace+"/"+c.Name]
		c.Matches = true
		for _, ch := range c.Checks {
			c.Matches = c.Matches && ch.OK
		}
		if c.Matches || c.Scraping || close {
			out = append(out, c)
		}
	}
	for _, m := range in.ServiceMonitors {
		var best *MonitorCheck
		bestScore, bestClose := -1, false
		nsOK, nsDetail := monitorCoversNamespace(m.Spec, m.Namespace, s.Namespace)
		sel, _ := labelSelector(m.Spec, "selector")
		for _, sv := range s.Services {
			selOK, failing, passing := explainSelector(sel, sv.Labels)
			portOK, portDetail := serviceMonitorPorts(m.Spec, &sv, s.Ports)
			c := MonitorCheck{Kind: m.Kind, Namespace: m.Namespace, Name: m.Name, Via: &ObjectRef{Kind: "Service", Namespace: sv.Namespace, Name: sv.Name}}
			c.Checks = append(c.Checks,
				Check{Name: "namespace", OK: nsOK, Detail: nsDetail},
				selectorCheck("Service "+sv.Name, selOK, failing),
				Check{Name: "port", OK: portOK, Detail: portDetail},
			)
			score := btoi(nsOK) + 2*btoi(selOK) + btoi(portOK)
			if score > bestScore {
				c := c
				best, bestScore, bestClose = &c, score, nsOK && (selOK || passing > 0)
			}
		}
		if best != nil {
			best.Checks = append(best.Checks, prometheusCheck(in, promSelectables[0], m))
			consider(*best, bestClose)
		}
	}
	if s.PodLabels != nil {
		for _, m := range in.PodMonitors {
			nsOK, nsDetail := monitorCoversNamespace(m.Spec, m.Namespace, s.Namespace)
			sel, _ := labelSelector(m.Spec, "selector")
			selOK, failing, passing := explainSelector(sel, s.PodLabels)
			portOK, portDetail := podMonitorPorts(m.Spec, s.Ports)
			c := MonitorCheck{Kind: m.Kind, Namespace: m.Namespace, Name: m.Name}
			c.Checks = []Check{
				{Name: "namespace", OK: nsOK, Detail: nsDetail},
				selectorCheck("the pod", selOK, failing),
				{Name: "port", OK: portOK, Detail: portDetail},
				prometheusCheck(in, promSelectables[1], m),
			}
			consider(c, nsOK && (selOK || passing > 0))
		}
	}
	score := func(c MonitorCheck) int {
		n := 0
		for _, ch := range c.Checks {
			n += btoi(ch.OK)
		}
		return n + 10*btoi(c.Matches) + 20*btoi(c.Scraping)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if a, b := score(out[i]), score(out[j]); a != b {
			return a > b
		}
		return out[i].Kind+out[i].Namespace+out[i].Name < out[j].Kind+out[j].Namespace+out[j].Name
	})
	if len(out) > maxMonitorChecks {
		out = out[:maxMonitorChecks]
	}
	return out
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}

func selectorCheck(what string, ok bool, failing []string) Check {
	if ok {
		return Check{Name: "selector", OK: true, Detail: "selects " + what}
	}
	return Check{Name: "selector", Detail: "wants " + strings.Join(failing, ", ")}
}

// prometheusCheck: does any Prometheus custom resource select monitor m?
// Without Prometheus CRs (a non-operator setup) the check is left out by
// passing; the targets then tell the story.
func prometheusCheck(in monitorInputs, sel selectable, m crObject) Check {
	if len(in.Prometheuses) == 0 {
		return Check{Name: "prometheus", OK: true, Detail: "no Prometheus custom resource to check"}
	}
	var why []string
	for _, p := range in.Prometheuses {
		ok, detail := crSelects(p.Spec, p.Namespace, sel, m.Namespace, m.Labels, in.NSLabels)
		if ok {
			return Check{Name: "prometheus", OK: true, Detail: "selected by Prometheus " + p.Namespace + "/" + p.Name}
		}
		why = append(why, p.Namespace+"/"+p.Name+": "+detail)
	}
	return Check{Name: "prometheus", Detail: "not selected: " + strings.Join(why, "; ")}
}

// serviceMonitorPorts: does any endpoint's port (a Service port name) or
// targetPort exist on Service sv?
func serviceMonitorPorts(spec map[string]any, sv *corev1.Service, cports []corev1.ContainerPort) (bool, string) {
	eps, _ := spec["endpoints"].([]any)
	var names []string
	for _, p := range sv.Spec.Ports {
		names = append(names, cmp.Or(p.Name, strconv.Itoa(int(p.Port))))
	}
	var wants []string
	for _, e := range eps {
		em, _ := e.(map[string]any)
		if port, ok := em["port"].(string); ok && port != "" {
			wants = append(wants, `"`+port+`"`)
			for _, p := range sv.Spec.Ports {
				if p.Name == port {
					return true, "Service port " + port
				}
			}
			continue
		}
		if tp, ok := em["targetPort"]; ok && tp != nil {
			v := fmt.Sprint(tp)
			wants = append(wants, "targetPort "+v)
			for _, p := range sv.Spec.Ports {
				if p.TargetPort.String() == v {
					return true, "targetPort " + v
				}
			}
			for _, c := range cports {
				if c.Name == v || strconv.Itoa(int(c.ContainerPort)) == v {
					return true, "targetPort " + v
				}
			}
			continue
		}
		return true, "every Service port"
	}
	if len(wants) == 0 {
		return false, "no endpoints"
	}
	return false, "wants port " + strings.Join(wants, ", ") + "; Service " + sv.Name + " has " + cmp.Or(strings.Join(names, ", "), "no ports")
}

// podMonitorPorts: does any podMetricsEndpoint's port (a container port
// name), portNumber or targetPort exist on the pod?
func podMonitorPorts(spec map[string]any, cports []corev1.ContainerPort) (bool, string) {
	eps, _ := spec["podMetricsEndpoints"].([]any)
	var names []string
	for _, c := range cports {
		names = append(names, cmp.Or(c.Name, strconv.Itoa(int(c.ContainerPort))))
	}
	var wants []string
	for _, e := range eps {
		em, _ := e.(map[string]any)
		if port, ok := em["port"].(string); ok && port != "" {
			wants = append(wants, `"`+port+`"`)
			for _, c := range cports {
				if c.Name == port {
					return true, "container port " + port
				}
			}
			continue
		}
		if n, ok := em["portNumber"]; ok && n != nil {
			v := fmt.Sprint(n)
			wants = append(wants, "port "+v)
			for _, c := range cports {
				if strconv.Itoa(int(c.ContainerPort)) == v {
					return true, "container port " + v
				}
			}
			continue
		}
		if tp, ok := em["targetPort"]; ok && tp != nil {
			v := fmt.Sprint(tp)
			wants = append(wants, "targetPort "+v)
			for _, c := range cports {
				if c.Name == v || strconv.Itoa(int(c.ContainerPort)) == v {
					return true, "targetPort " + v
				}
			}
			continue
		}
		return true, "every container port"
	}
	if len(wants) == 0 {
		return false, "no podMetricsEndpoints"
	}
	return false, "wants port " + strings.Join(wants, ", ") + "; the pod declares " + cmp.Or(strings.Join(names, ", "), "no container ports")
}

// scrape builds the GET /api/prom/scrape answer.
func (h *Handler) scrape(ctx context.Context, e env, kind, ns, name, instance string) (*ScrapeResult, error) {
	s, err := resolveSubject(ctx, e.typed, kind, ns, name)
	if err != nil {
		return nil, err
	}
	res := &ScrapeResult{Kind: kind, Namespace: ns, Name: name, Pods: len(s.Pods), Services: s.serviceNames(),
		Targets: []ObjectTarget{}, Jobs: []string{}, Dropped: []DroppedPool{}, Monitors: []MonitorCheck{}, Hints: []string{}, Errors: map[string]string{}}
	st := h.disc.get(ctx, e, false)
	p := st.Default(KindPrometheus, instance)
	res.Prometheus = p

	var (
		wg               sync.WaitGroup
		active, dropped  []promTarget
		aErr, dErr       error
		in               monitorInputs
		smErr, pmErr, pr error
	)
	if p != nil {
		wg.Add(2)
		go func() { defer wg.Done(); active, aErr = cachedTargets(ctx, e, p) }()
		go func() { defer wg.Done(); dropped, dErr = cachedDropped(ctx, e, p) }()
	}
	wg.Add(3)
	go func() {
		defer wg.Done()
		in.ServiceMonitors, smErr = listCRs(ctx, e.dyn, "ServiceMonitor", ServiceMonitorGVR)
	}()
	go func() { defer wg.Done(); in.PodMonitors, pmErr = listCRs(ctx, e.dyn, "PodMonitor", PodMonitorGVR) }()
	go func() { defer wg.Done(); in.Prometheuses, pr = listCRs(ctx, e.dyn, "Prometheus", PrometheusGVR) }()
	wg.Wait()
	in.NSLabels = nsLabeler(ctx, e.typed)

	switch {
	case p == nil:
		res.Errors["prometheus"] = "no Prometheus found in the cluster"
	case aErr != nil:
		res.Errors["prometheus"] = aErr.Error()
	default:
		MatchTargets(active, s, res)
		if dErr == nil {
			MatchDropped(dropped, s, res)
		}
	}
	for k, err := range map[string]error{"servicemonitors": smErr, "podmonitors": pmErr, "prometheuses": pr} {
		if err != nil {
			res.Errors[k] = err.Error()
		}
	}
	scrapedBy := map[string]bool{}
	for _, t := range res.Targets {
		if m := t.Monitor; m != nil {
			scrapedBy[m.Kind+"/"+m.Namespace+"/"+m.Name] = true
		}
	}
	res.Monitors = CheckMonitors(in, s, scrapedBy)
	if res.Monitors == nil {
		res.Monitors = []MonitorCheck{}
	}
	res.Dropped = relevantDropped(res.Dropped, res.Monitors)
	res.Hints = scrapeHints(s, res)
	if res.Total == 0 {
		if n := watchingMonitors(in, s.Namespace, res.Monitors); n > 0 {
			res.Hints = append(res.Hints, fmt.Sprintf("%d other ServiceMonitors and PodMonitors watch %s but select different labels.", n, s.Namespace))
		}
	}
	if len(res.Errors) == 0 {
		res.Errors = nil
	}
	return res, nil
}

// relevantDropped keeps the dropped pools worth showing: those of a monitor
// whose selector picks the object (relabelling then dropped it, usually on
// the port) and those of plain scrape configs (an annotation-driven job
// that skipped it). Every PodMonitor in a namespace "discovers" each of its
// pods and drops the ones its selector doesn't match; those are noise.
func relevantDropped(dropped []DroppedPool, monitors []MonitorCheck) []DroppedPool {
	selects := map[string]bool{}
	for _, m := range monitors {
		for _, c := range m.Checks {
			if c.Name == "selector" && c.OK {
				selects[m.Kind+"/"+m.Namespace+"/"+m.Name] = true
			}
		}
	}
	out := []DroppedPool{}
	for _, d := range dropped {
		if m := d.Monitor; m == nil || selects[m.Kind+"/"+m.Namespace+"/"+m.Name] {
			out = append(out, d)
		}
	}
	return out
}

// watchingMonitors counts monitors that watch ns but weren't listed.
func watchingMonitors(in monitorInputs, ns string, listed []MonitorCheck) int {
	seen := map[string]bool{}
	for _, m := range listed {
		seen[m.Kind+"/"+m.Namespace+"/"+m.Name] = true
	}
	n := 0
	for _, l := range [][]crObject{in.ServiceMonitors, in.PodMonitors} {
		for _, m := range l {
			if ok, _ := monitorCoversNamespace(m.Spec, m.Namespace, ns); ok && !seen[m.Kind+"/"+m.Namespace+"/"+m.Name] {
				n++
			}
		}
	}
	return n
}

// scrapeHints explains, in a line or two, why an object isn't scraped.
func scrapeHints(s *subject, res *ScrapeResult) []string {
	hints := []string{}
	if res.Total > 0 {
		return hints
	}
	if s.Kind != "Service" && len(s.Pods) == 0 {
		hints = append(hints, "It has no pods, so there is nothing to scrape.")
	}
	if len(s.Services) == 0 && s.Kind != "Service" {
		hints = append(hints, "No Service selects its pods, so ServiceMonitors can't find them; only a PodMonitor or a scrape config can.")
	}
	if s.Kind == "Service" && len(s.Services) == 1 && len(s.Services[0].Spec.Selector) == 0 {
		hints = append(hints, "The Service has no selector; its endpoints are managed by hand.")
	}
	if len(s.Ports) == 0 && s.Kind != "Service" {
		hints = append(hints, "Its containers declare no ports. PodMonitors match container port names, so give the metrics port a name.")
	}
	if v := s.Annotations["prometheus.io/scrape"]; v == "true" {
		hints = append(hints, "It has the prometheus.io/scrape annotation. The operator's monitors ignore it; only a scrape config written for these annotations reads it.")
	}
	anyMatch := false
	for _, m := range res.Monitors {
		anyMatch = anyMatch || m.Matches
	}
	if anyMatch && res.Prometheus != nil && res.Errors["prometheus"] == "" {
		hints = append(hints, "A monitor matches, but Prometheus has no target from it yet: the operator may still be reloading the config, or relabelling dropped it.")
	}
	if len(res.Monitors) == 0 && len(res.Dropped) == 0 {
		hints = append(hints, "No ServiceMonitor or PodMonitor comes close to matching it.")
	}
	return hints
}

func (h *Handler) handleScrape(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	kind, ns, name := q.Get("kind"), q.Get("namespace"), q.Get("name")
	if kind == "" || ns == "" || name == "" {
		writeErr(w, httpx.BadRequest("kind, namespace and name are required"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	res, err := h.scrape(ctx, h.env(), kind, ns, name, q.Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, res)
}
