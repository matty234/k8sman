package metrics

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"strings"

	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/matty234/k8sman/backend/internal/kapi"
)

// ---- HPA shapes (kapi.HorizontalPodAutoscalers' version, autoscaling/v2;
// only the fields we read) ----

type hpaTarget struct {
	Type               string `json:"type"`
	AverageUtilization *int32 `json:"averageUtilization"`
	AverageValue       string `json:"averageValue"`
	Value              string `json:"value"`
}

type hpaMetricID struct {
	Name     string                `json:"name"`
	Selector *metav1.LabelSelector `json:"selector"`
}

type hpaMetricSpec struct {
	Type     string `json:"type"`
	Resource *struct {
		Name   string    `json:"name"`
		Target hpaTarget `json:"target"`
	} `json:"resource"`
	ContainerResource *struct {
		Name      string    `json:"name"`
		Container string    `json:"container"`
		Target    hpaTarget `json:"target"`
	} `json:"containerResource"`
	Pods *struct {
		Metric hpaMetricID `json:"metric"`
		Target hpaTarget   `json:"target"`
	} `json:"pods"`
	Object *struct {
		DescribedObject struct {
			APIVersion string `json:"apiVersion"`
			Kind       string `json:"kind"`
			Name       string `json:"name"`
		} `json:"describedObject"`
		Metric hpaMetricID `json:"metric"`
		Target hpaTarget   `json:"target"`
	} `json:"object"`
	External *struct {
		Metric hpaMetricID `json:"metric"`
		Target hpaTarget   `json:"target"`
	} `json:"external"`
}

type hpaObject struct {
	Metadata struct {
		Name      string `json:"name"`
		Namespace string `json:"namespace"`
	} `json:"metadata"`
	Spec struct {
		ScaleTargetRef struct {
			APIVersion string `json:"apiVersion"`
			Kind       string `json:"kind"`
			Name       string `json:"name"`
		} `json:"scaleTargetRef"`
		MinReplicas *int32          `json:"minReplicas"`
		MaxReplicas int32           `json:"maxReplicas"`
		Metrics     []hpaMetricSpec `json:"metrics"`
	} `json:"spec"`
	Status struct {
		CurrentReplicas int32  `json:"currentReplicas"`
		DesiredReplicas *int32 `json:"desiredReplicas"`
	} `json:"status"`
}

func selectorString(ls *metav1.LabelSelector) string {
	if ls == nil {
		return ""
	}
	sel, err := metav1.LabelSelectorAsSelector(ls)
	if err != nil {
		return ""
	}
	return sel.String()
}

func (s *Service) listHPAs(ctx context.Context, namespace string) ([]hpaObject, error) {
	raw, err := s.get.Get(ctx, kapi.HorizontalPodAutoscalers.Path(namespace, ""), nil)
	if err != nil {
		return nil, err
	}
	var l struct {
		Items []hpaObject `json:"items"`
	}
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	return l.Items, nil
}

// ---- HPA analysis ------------------------------------------------------------

// HPAMetric is one spec.metrics entry with its live value read from the
// metrics APIs and the replica count it proposes.
type HPAMetric struct {
	Index     int        `json:"index"`
	Type      string     `json:"type"`
	Name      string     `json:"name"`
	Container string     `json:"container,omitempty"`
	Selector  string     `json:"selector,omitempty"`
	Object    *ObjectRef `json:"object,omitempty"`
	// TargetType is Utilization, AverageValue or Value; Target is the spec value
	// (a percentage for Utilization, else a quantity).
	TargetType string `json:"targetType"`
	Target     string `json:"target"`
	// Current is the live value in the same unit as Target ("" if unknown).
	Current string `json:"current,omitempty"`
	// Utilization (percent of request) for Resource/ContainerResource metrics.
	Utilization *int `json:"utilization,omitempty"`
	// AverageValue per pod for Resource/ContainerResource/Pods metrics.
	AverageValue string `json:"averageValue,omitempty"`
	// Pods is how many pods the value was computed over.
	Pods int `json:"pods,omitempty"`
	// Ratio is current/target (1 = on target).
	Ratio *float64 `json:"ratio,omitempty"`
	// Proposed is the replica count this metric alone asks for (before min/max).
	Proposed *int `json:"proposed,omitempty"`
	// Driving marks the metric(s) that set the HPA's decision (the largest proposal).
	Driving bool   `json:"driving"`
	Error   string `json:"error,omitempty"`
}

// HPAAnalysis is an HPA with live metric values.
type HPAAnalysis struct {
	Namespace       string    `json:"namespace"`
	Name            string    `json:"name"`
	Target          ObjectRef `json:"target"`
	Selector        string    `json:"selector,omitempty"`
	CurrentReplicas int       `json:"currentReplicas"`
	DesiredReplicas *int      `json:"desiredReplicas,omitempty"`
	MinReplicas     int       `json:"minReplicas"`
	MaxReplicas     int       `json:"maxReplicas"`
	Proposed        *int      `json:"proposed,omitempty"`
	// LimitedBy is "min" or "max" when the bounds, not a metric, set Proposed.
	LimitedBy string      `json:"limitedBy,omitempty"`
	Metrics   []HPAMetric `json:"metrics"`
	Errors    []string    `json:"errors,omitempty"`
}

// tolerance is the HPA controller's default (--horizontal-pod-autoscaler-tolerance).
const tolerance = 0.1

// AnalyzeHPA reads an HPA, resolves its scale target's pods and evaluates
// each metric against the live metrics APIs.
func (s *Service) AnalyzeHPA(ctx context.Context, namespace, name string) (HPAAnalysis, error) {
	raw, err := s.get.Get(ctx, kapi.HorizontalPodAutoscalers.Path(namespace, name), nil)
	if err != nil {
		return HPAAnalysis{}, err
	}
	var h hpaObject
	if err := json.Unmarshal(raw, &h); err != nil {
		return HPAAnalysis{}, err
	}
	a := HPAAnalysis{
		Namespace:       namespace,
		Name:            name,
		Target:          ObjectRef{Kind: h.Spec.ScaleTargetRef.Kind, Name: h.Spec.ScaleTargetRef.Name, APIVersion: h.Spec.ScaleTargetRef.APIVersion, Namespace: namespace},
		CurrentReplicas: int(h.Status.CurrentReplicas),
		MinReplicas:     1,
		MaxReplicas:     int(h.Spec.MaxReplicas),
		Metrics:         []HPAMetric{},
	}
	if h.Spec.MinReplicas != nil {
		a.MinReplicas = int(*h.Spec.MinReplicas)
	}
	if h.Status.DesiredReplicas != nil {
		d := int(*h.Status.DesiredReplicas)
		a.DesiredReplicas = &d
	}
	sel, err := s.scaleSelector(ctx, namespace, h.Spec.ScaleTargetRef.APIVersion, h.Spec.ScaleTargetRef.Kind, h.Spec.ScaleTargetRef.Name)
	if err != nil {
		a.Errors = append(a.Errors, "scale target: "+err.Error())
	}
	a.Selector = sel

	// Pods and their usage are shared by every Resource metric.
	var pods *podSet
	loadPods := func() (*podSet, error) {
		if pods != nil {
			return pods, nil
		}
		if sel == "" {
			return nil, fmt.Errorf("scale target has no selector")
		}
		p, err := s.loadPodSet(ctx, namespace, sel)
		if err != nil {
			return nil, err
		}
		pods = p
		return p, nil
	}

	for i, m := range h.Spec.Metrics {
		hm := s.evalMetric(ctx, a, i, m, sel, loadPods)
		a.Metrics = append(a.Metrics, hm)
	}

	best := -1
	for _, m := range a.Metrics {
		if m.Proposed != nil && *m.Proposed > best {
			best = *m.Proposed
		}
	}
	if best >= 0 {
		for i := range a.Metrics {
			if p := a.Metrics[i].Proposed; p != nil && *p == best {
				a.Metrics[i].Driving = true
			}
		}
		p := min(max(best, a.MinReplicas), a.MaxReplicas)
		a.Proposed = &p
		switch {
		case best < a.MinReplicas:
			a.LimitedBy = "min"
		case best > a.MaxReplicas:
			a.LimitedBy = "max"
		}
	}
	return a, nil
}

func (s *Service) evalMetric(ctx context.Context, a HPAAnalysis, i int, m hpaMetricSpec, sel string, loadPods func() (*podSet, error)) HPAMetric {
	hm := HPAMetric{Index: i, Type: m.Type}
	cur := a.CurrentReplicas
	fail := func(err error) HPAMetric {
		hm.Error = err.Error()
		return hm
	}
	switch {
	case m.Resource != nil || m.ContainerResource != nil:
		var res, container string
		var t hpaTarget
		if m.Resource != nil {
			res, t = m.Resource.Name, m.Resource.Target
		} else {
			res, container, t = m.ContainerResource.Name, m.ContainerResource.Container, m.ContainerResource.Target
			hm.Container = container
		}
		hm.Name = res
		setTarget(&hm, t)
		ps, err := loadPods()
		if err != nil {
			return fail(err)
		}
		usage, request, n, missing := ps.sum(res, container)
		hm.Pods = n
		if n == 0 {
			return fail(fmt.Errorf("no metrics for the target's pods yet"))
		}
		avg := usage / float64(n)
		hm.AverageValue = formatResource(res, avg)
		if missing == "" && request > 0 {
			u := int(math.Round(usage / request * 100))
			hm.Utilization = &u
		}
		switch t.Type {
		case "Utilization":
			if hm.Utilization == nil {
				return fail(fmt.Errorf("missing %s request on pod %s", res, missing))
			}
			hm.Current = fmt.Sprintf("%d", *hm.Utilization)
			proposeRatio(&hm, float64(*hm.Utilization), float64(derefInt32(t.AverageUtilization)), n, cur)
		default:
			hm.Current = hm.AverageValue
			proposeRatio(&hm, avg, resourceTargetFloat(res, t.AverageValue), n, cur)
		}
	case m.Pods != nil:
		hm.Name = m.Pods.Metric.Name
		hm.Selector = selectorString(m.Pods.Metric.Selector)
		setTarget(&hm, m.Pods.Target)
		if sel == "" {
			return fail(fmt.Errorf("scale target has no selector"))
		}
		vals, err := s.Custom(ctx, CustomQuery{Resource: "pods", Namespace: a.Namespace, Selector: sel, Metric: hm.Name, MetricSelector: hm.Selector})
		if err != nil {
			return fail(err)
		}
		if len(vals) == 0 {
			return fail(fmt.Errorf("no values for the target's pods"))
		}
		sum := 0.0
		for _, v := range vals {
			sum += v.Number
		}
		hm.Pods = len(vals)
		avg := sum / float64(len(vals))
		hm.AverageValue = formatNumber(avg)
		hm.Current = hm.AverageValue
		proposeRatio(&hm, avg, quantityFloat(m.Pods.Target.AverageValue), len(vals), cur)
	case m.Object != nil:
		d := m.Object.DescribedObject
		hm.Name = m.Object.Metric.Name
		hm.Selector = selectorString(m.Object.Metric.Selector)
		hm.Object = &ObjectRef{Kind: d.Kind, Name: d.Name, APIVersion: d.APIVersion, Namespace: a.Namespace}
		setTarget(&hm, m.Object.Target)
		group := ""
		if gv := strings.SplitN(d.APIVersion, "/", 2); len(gv) == 2 {
			group = gv[0]
		}
		vals, err := s.Custom(ctx, CustomQuery{Group: group, Resource: pluralize(d.Kind), Namespace: a.Namespace, Name: d.Name, Metric: hm.Name, MetricSelector: hm.Selector})
		if err != nil {
			return fail(err)
		}
		if len(vals) == 0 {
			return fail(fmt.Errorf("no value for %s/%s", d.Kind, d.Name))
		}
		v := vals[0].Number
		hm.Current = formatNumber(v)
		if m.Object.Target.Type == "AverageValue" {
			proposeTotal(&hm, v, quantityFloat(m.Object.Target.AverageValue), cur)
		} else {
			proposeRatio(&hm, v, quantityFloat(m.Object.Target.Value), cur, cur)
		}
	case m.External != nil:
		hm.Name = m.External.Metric.Name
		hm.Selector = selectorString(m.External.Metric.Selector)
		setTarget(&hm, m.External.Target)
		vals, err := s.External(ctx, ExternalQuery{Namespace: a.Namespace, Metric: hm.Name, Selector: hm.Selector})
		if err != nil {
			return fail(err)
		}
		if len(vals) == 0 {
			return fail(fmt.Errorf("no values for %s", hm.Name))
		}
		sum := 0.0
		for _, v := range vals {
			sum += v.Number
		}
		if m.External.Target.Type == "AverageValue" {
			// Shown per pod, like the HPA's status.
			if cur > 0 {
				hm.AverageValue = formatNumber(sum / float64(cur))
			}
			hm.Current = hm.AverageValue
			proposeTotal(&hm, sum, quantityFloat(m.External.Target.AverageValue), cur)
		} else {
			hm.Current = formatNumber(sum)
			proposeRatio(&hm, sum, quantityFloat(m.External.Target.Value), cur, cur)
		}
	default:
		return fail(fmt.Errorf("unsupported metric type %q", m.Type))
	}
	return hm
}

func setTarget(hm *HPAMetric, t hpaTarget) {
	hm.TargetType = t.Type
	switch t.Type {
	case "Utilization":
		hm.Target = fmt.Sprintf("%d", derefInt32(t.AverageUtilization))
	case "AverageValue":
		hm.Target = t.AverageValue
	default:
		hm.Target = t.Value
	}
}

// proposeRatio: replicas = ceil(ratio * base), unless within tolerance.
func proposeRatio(hm *HPAMetric, current, target float64, base, currentReplicas int) {
	if target <= 0 {
		return
	}
	r := current / target
	hm.Ratio = &r
	p := currentReplicas
	if math.Abs(r-1) > tolerance {
		p = int(math.Ceil(r * float64(base)))
	}
	hm.Proposed = &p
}

// proposeTotal: replicas = ceil(total / perPodTarget) (AverageValue on Object/External).
func proposeTotal(hm *HPAMetric, total, perPod float64, currentReplicas int) {
	if perPod <= 0 {
		return
	}
	p := currentReplicas
	if currentReplicas > 0 {
		r := total / (perPod * float64(currentReplicas))
		hm.Ratio = &r
		if math.Abs(r-1) > tolerance {
			p = int(math.Ceil(total / perPod))
		}
	} else {
		p = int(math.Ceil(total / perPod))
	}
	hm.Proposed = &p
}

func derefInt32(p *int32) int {
	if p == nil {
		return 0
	}
	return int(*p)
}

func formatNumber(v float64) string {
	return resource.NewMilliQuantity(int64(math.Round(v*1000)), resource.DecimalSI).String()
}

// formatResource renders a per-pod resource value like the HPA does: CPU in
// millicores, memory in bytes.
func formatResource(res string, v float64) string {
	if res == "cpu" {
		return fmt.Sprintf("%dm", int64(math.Round(v)))
	}
	return resource.NewQuantity(int64(math.Round(v)), resource.BinarySI).String()
}

// resourceTargetFloat parses an averageValue target in the units podSet.sum uses.
func resourceTargetFloat(res, q string) float64 {
	qq, err := resource.ParseQuantity(q)
	if err != nil {
		return 0
	}
	if res == "cpu" {
		return float64(qq.MilliValue())
	}
	return float64(qq.Value())
}

var irregularPlurals = map[string]string{"Endpoints": "endpoints", "Ingress": "ingresses", "NetworkPolicy": "networkpolicies"}

func pluralize(kind string) string {
	if p, ok := irregularPlurals[kind]; ok {
		return p
	}
	k := strings.ToLower(kind)
	switch {
	case strings.HasSuffix(k, "s"):
		return k + "es"
	case strings.HasSuffix(k, "y"):
		return k[:len(k)-1] + "ies"
	}
	return k + "s"
}

// scaleSelector reads the target's /scale subresource for its pod selector.
func (s *Service) scaleSelector(ctx context.Context, namespace, apiVersion, kind, name string) (string, error) {
	prefix := "/apis/" + apiVersion
	if !strings.Contains(apiVersion, "/") {
		prefix = "/api/" + apiVersion
	}
	path := prefix + "/namespaces/" + url.PathEscape(namespace) + "/" + pluralize(kind) + "/" + url.PathEscape(name) + "/scale"
	raw, err := s.get.Get(ctx, path, nil)
	if err != nil {
		return "", err
	}
	var sc struct {
		Status struct {
			Selector string `json:"selector"`
		} `json:"status"`
	}
	if err := json.Unmarshal(raw, &sc); err != nil {
		return "", err
	}
	return sc.Status.Selector, nil
}

// podSet is the target's running pods with their requests and usage.
type podSet struct {
	pods  []podReq
	usage map[string]PodUsage
}

type podReq struct {
	name     string
	requests map[string]map[string]float64 // container → resource → value (cpu millis, bytes)
}

func (s *Service) loadPodSet(ctx context.Context, namespace, selector string) (*podSet, error) {
	raw, err := s.get.Get(ctx, kapi.Pods.Path(namespace, ""), url.Values{"labelSelector": {selector}})
	if err != nil {
		return nil, err
	}
	var l struct {
		Items []struct {
			Metadata struct {
				Name              string `json:"name"`
				DeletionTimestamp string `json:"deletionTimestamp"`
			} `json:"metadata"`
			Spec struct {
				Containers []struct {
					Name      string `json:"name"`
					Resources struct {
						Requests map[string]string `json:"requests"`
					} `json:"resources"`
				} `json:"containers"`
			} `json:"spec"`
			Status struct {
				Phase string `json:"phase"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	usage, err := s.PodsSelected(ctx, namespace, selector)
	if err != nil {
		return nil, err
	}
	ps := &podSet{usage: map[string]PodUsage{}}
	for _, u := range usage {
		ps.usage[u.Name] = u
	}
	for _, p := range l.Items {
		if p.Status.Phase != "Running" || p.Metadata.DeletionTimestamp != "" {
			continue
		}
		pr := podReq{name: p.Metadata.Name, requests: map[string]map[string]float64{}}
		for _, c := range p.Spec.Containers {
			m := map[string]float64{}
			for k, v := range c.Resources.Requests {
				m[k] = resourceTargetFloat(k, v)
			}
			pr.requests[c.Name] = m
		}
		ps.pods = append(ps.pods, pr)
	}
	return ps, nil
}

// sum returns total usage and requests of res over pods that have metrics
// (optionally one container), the pod count, and the first pod missing a
// request ("" if none).
func (ps *podSet) sum(res, container string) (usage, request float64, n int, missing string) {
	for _, p := range ps.pods {
		u, ok := ps.usage[p.name]
		if !ok {
			continue
		}
		podUsage, podReq := 0.0, 0.0
		hasReq := true
		for _, c := range u.Containers {
			if container != "" && c.Name != container {
				continue
			}
			if res == "cpu" {
				podUsage += float64(c.CPUMillis)
			} else {
				podUsage += float64(c.MemoryBytes)
			}
			r, ok := p.requests[c.Name][res]
			if !ok {
				hasReq = false
			}
			podReq += r
		}
		if !hasReq && missing == "" {
			missing = p.name
		}
		usage += podUsage
		request += podReq
		n++
	}
	return usage, request, n, missing
}
