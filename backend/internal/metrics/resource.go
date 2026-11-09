package metrics

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/url"
	"sort"

	"k8s.io/apimachinery/pkg/api/resource"
)

// ErrNoData means the API answered but has no samples yet (metrics-server
// returns empty lists until its first successful scrape).
var ErrNoData = errors.New("no metrics reported yet")

func isNoData(err error) bool { return errors.Is(err, ErrNoData) }

// Usage is a CPU/memory sample. CPU is a millicore quantity string ("12m")
// and Memory a byte count string, plus the same as numbers.
type Usage struct {
	CPU         string `json:"cpu"`
	Memory      string `json:"memory"`
	CPUMillis   int64  `json:"cpuMillis"`
	MemoryBytes int64  `json:"memoryBytes"`
}

// NodeUsage is one node's current usage.
type NodeUsage struct {
	Name      string `json:"name"`
	Timestamp string `json:"timestamp,omitempty"`
	Window    string `json:"window,omitempty"`
	Usage
}

// ContainerUsage is one container's current usage.
type ContainerUsage struct {
	Name string `json:"name"`
	Usage
}

// PodUsage is one pod's current usage (sum of its containers).
type PodUsage struct {
	Name       string           `json:"name"`
	Namespace  string           `json:"namespace"`
	Timestamp  string           `json:"timestamp,omitempty"`
	Window     string           `json:"window,omitempty"`
	Containers []ContainerUsage `json:"containers"`
	Usage
}

type rawUsage map[string]string

type nodeMetricsList struct {
	Items []struct {
		Metadata struct {
			Name string `json:"name"`
		} `json:"metadata"`
		Timestamp string   `json:"timestamp"`
		Window    string   `json:"window"`
		Usage     rawUsage `json:"usage"`
	} `json:"items"`
}

type podMetricsList struct {
	Items []struct {
		Metadata struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
		} `json:"metadata"`
		Timestamp  string `json:"timestamp"`
		Window     string `json:"window"`
		Containers []struct {
			Name  string   `json:"name"`
			Usage rawUsage `json:"usage"`
		} `json:"containers"`
	} `json:"items"`
}

// MakeUsage builds a Usage from millicores and bytes.
func MakeUsage(cpuMillis, memBytes int64) Usage {
	return Usage{CPU: fmt.Sprintf("%dm", cpuMillis), Memory: fmt.Sprintf("%d", memBytes), CPUMillis: cpuMillis, MemoryBytes: memBytes}
}

func (r rawUsage) parse() Usage {
	var cpu, mem int64
	if q, err := resource.ParseQuantity(r["cpu"]); err == nil {
		cpu = q.MilliValue() // rounds up, like kubectl top
	}
	if q, err := resource.ParseQuantity(r["memory"]); err == nil {
		mem = q.Value()
	}
	return MakeUsage(cpu, mem)
}

// Add sums two usages.
func (u Usage) Add(o Usage) Usage {
	return MakeUsage(u.CPUMillis+o.CPUMillis, u.MemoryBytes+o.MemoryBytes)
}

// Nodes returns current node usage (cached for UsageTTL).
func (s *Service) Nodes(ctx context.Context) ([]NodeUsage, error) {
	s.mu.Lock()
	if c := s.nodes; c != nil && s.now().Sub(c.at) < s.UsageTTL {
		s.mu.Unlock()
		return c.items, c.err
	}
	s.mu.Unlock()
	items, err := s.fetchNodes(ctx)
	err = s.explain(ctx, ResourceGroup, err)
	if ctx.Err() == nil {
		s.mu.Lock()
		s.nodes = &cachedNodes{at: s.now(), items: items, err: err}
		s.mu.Unlock()
	}
	return items, err
}

func (s *Service) fetchNodes(ctx context.Context) ([]NodeUsage, error) {
	raw, err := s.get.Get(ctx, "/apis/metrics.k8s.io/v1beta1/nodes", nil)
	if err != nil {
		return nil, err
	}
	var l nodeMetricsList
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	if len(l.Items) == 0 {
		// Every cluster has a node: an empty list means no scrape yet.
		return nil, ErrNoData
	}
	out := make([]NodeUsage, 0, len(l.Items))
	for _, it := range l.Items {
		out = append(out, NodeUsage{Name: it.Metadata.Name, Timestamp: it.Timestamp, Window: it.Window, Usage: it.Usage.parse()})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Pods returns current pod usage in a namespace ("" = all), cached for
// UsageTTL. A fresh all-namespaces snapshot also serves single namespaces.
func (s *Service) Pods(ctx context.Context, namespace string) ([]PodUsage, error) {
	s.mu.Lock()
	if c := s.pods[namespace]; c != nil && s.now().Sub(c.at) < s.UsageTTL {
		s.mu.Unlock()
		return c.items, c.err
	}
	if c := s.pods[""]; namespace != "" && c != nil && c.err == nil && s.now().Sub(c.at) < s.UsageTTL {
		s.mu.Unlock()
		var out []PodUsage
		for _, p := range c.items {
			if p.Namespace == namespace {
				out = append(out, p)
			}
		}
		return out, nil
	}
	s.mu.Unlock()
	items, err := s.fetchPods(ctx, namespace, "")
	err = s.explain(ctx, ResourceGroup, err)
	if ctx.Err() == nil {
		s.mu.Lock()
		s.pods[namespace] = &cachedPods{at: s.now(), items: items, err: err}
		s.mu.Unlock()
	}
	return items, err
}

// PodsSelected returns pod usage filtered by a label selector (not cached).
func (s *Service) PodsSelected(ctx context.Context, namespace, labelSelector string) ([]PodUsage, error) {
	if labelSelector == "" {
		return s.Pods(ctx, namespace)
	}
	items, err := s.fetchPods(ctx, namespace, labelSelector)
	return items, s.explain(ctx, ResourceGroup, err)
}

func (s *Service) fetchPods(ctx context.Context, namespace, labelSelector string) ([]PodUsage, error) {
	path := "/apis/metrics.k8s.io/v1beta1/pods"
	if namespace != "" {
		path = "/apis/metrics.k8s.io/v1beta1/namespaces/" + url.PathEscape(namespace) + "/pods"
	}
	var params url.Values
	if labelSelector != "" {
		params = url.Values{"labelSelector": {labelSelector}}
	}
	raw, err := s.get.Get(ctx, path, params)
	if err != nil {
		return nil, err
	}
	var l podMetricsList
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	out := make([]PodUsage, 0, len(l.Items))
	for _, it := range l.Items {
		p := PodUsage{Name: it.Metadata.Name, Namespace: it.Metadata.Namespace, Timestamp: it.Timestamp, Window: it.Window, Containers: []ContainerUsage{}}
		for _, c := range it.Containers {
			cu := ContainerUsage{Name: c.Name, Usage: c.Usage.parse()}
			p.Containers = append(p.Containers, cu)
			p.Usage = p.Usage.Add(cu.Usage)
		}
		if len(it.Containers) == 0 {
			p.Usage = MakeUsage(0, 0)
		}
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Namespace != out[j].Namespace {
			return out[i].Namespace < out[j].Namespace
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}

// ---- table enrichment ------------------------------------------------------

// UsageKey is the reserved top-level key added to objects before column
// evaluation: `.k8sman.usage`.
const UsageKey = "k8sman"

// Decorator returns a copy of obj with `.k8sman.usage` set. It never mutates obj.
type Decorator func(obj map[string]any) map[string]any

// UsageDecorator fetches one usage snapshot (cached ~10s) for pods or nodes
// and returns a Decorator that merges it into objects. It returns nil for
// other resources or when resource metrics are unavailable, so callers can
// skip enrichment entirely.
func (s *Service) UsageDecorator(ctx context.Context, group, res, namespace string) Decorator {
	if group != "" || (res != "pods" && res != "nodes") {
		return nil
	}
	if s.Status(ctx, false).Resource.State == StateNotInstalled {
		return nil
	}
	switch res {
	case "nodes":
		items, err := s.Nodes(ctx)
		if err != nil {
			return nil
		}
		by := make(map[string]Usage, len(items))
		for _, n := range items {
			by[n.Name] = n.Usage
		}
		return func(obj map[string]any) map[string]any {
			name, _ := nested(obj, "metadata", "name").(string)
			u, ok := by[name]
			if !ok {
				return obj
			}
			m := usageMap(u)
			alloc, _ := nested(obj, "status", "allocatable").(map[string]any)
			if q, ok := quantityOf(alloc["cpu"]); ok {
				m["cpuAllocatableMillis"] = int(q.MilliValue())
				setBase(m, "cpu", "allocatable", float64(u.CPUMillis), float64(q.MilliValue()), 1000)
			}
			if q, ok := quantityOf(alloc["memory"]); ok {
				m["memoryAllocatableBytes"] = int(q.Value())
				setBase(m, "memory", "allocatable", float64(u.MemoryBytes), float64(q.Value()), 1)
			}
			return withUsage(obj, m)
		}
	default:
		items, err := s.Pods(ctx, namespace)
		if err != nil {
			return nil
		}
		by := make(map[string]PodUsage, len(items))
		for _, p := range items {
			by[p.Namespace+"/"+p.Name] = p
		}
		return func(obj map[string]any) map[string]any {
			ns, _ := nested(obj, "metadata", "namespace").(string)
			name, _ := nested(obj, "metadata", "name").(string)
			p, ok := by[ns+"/"+name]
			if !ok {
				return obj
			}
			m := usageMap(p.Usage)
			cs := make(map[string]any, len(p.Containers))
			for _, c := range p.Containers {
				cs[c.Name] = usageMap(c.Usage)
			}
			m["containers"] = cs
			podBases(m, obj, p.Usage)
			if p.Window != "" {
				m["window"] = p.Window
			}
			if p.Timestamp != "" {
				m["timestamp"] = p.Timestamp
			}
			return withUsage(obj, m)
		}
	}
}

// usageMap is the jq-friendly form (gojq accepts int, float64, string, maps).
func usageMap(u Usage) map[string]any {
	return map[string]any{"cpu": u.CPU, "memory": u.Memory, "cpuMillis": int(u.CPUMillis), "memoryBytes": int(u.MemoryBytes)}
}

// withUsage shallow-copies obj and adds .k8sman.usage. Other top-level values
// are shared, never modified.
func withUsage(obj map[string]any, usage map[string]any) map[string]any {
	out := make(map[string]any, len(obj)+1)
	for k, v := range obj {
		out[k] = v
	}
	k8sman := map[string]any{}
	if prev, ok := obj[UsageKey].(map[string]any); ok {
		for k, v := range prev {
			k8sman[k] = v
		}
	}
	k8sman["usage"] = usage
	out[UsageKey] = k8sman
	return out
}

func nested(obj map[string]any, path ...string) any {
	var cur any = obj
	for _, p := range path {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = m[p]
	}
	return cur
}

func quantityOf(v any) (resource.Quantity, bool) {
	s, ok := v.(string)
	if !ok {
		return resource.Quantity{}, false
	}
	q, err := resource.ParseQuantity(s)
	return q, err == nil
}

// setBase records what a usage figure is measured against (for the table's
// usage cells): <res>Basis ("limit", "request" or "allocatable"), <res>Base
// in display units (cores or bytes; total/div) and <res>Percent, used/total
// as a percentage with one decimal.
func setBase(m map[string]any, res, basis string, used, total, div float64) {
	if total <= 0 {
		return
	}
	m[res+"Basis"] = basis
	m[res+"Base"] = total / div
	m[res+"Percent"] = math.Round(used/total*1000) / 10
}

// podBases adds the pod's summed container limits and requests
// (cpuLimitMillis, cpuRequestMillis, memoryLimitBytes, memoryRequestBytes)
// and measures usage against the limit, else the request. A limit counts
// only when every container has one (otherwise the pod is unbounded); a
// request is the sum of those set. Init containers are ignored.
func podBases(m map[string]any, obj map[string]any, u Usage) {
	cs, _ := nested(obj, "spec", "containers").([]any)
	if len(cs) == 0 {
		return
	}
	type sum struct {
		total int64
		all   bool
	}
	lim := map[string]*sum{"cpu": {all: true}, "memory": {all: true}}
	req := map[string]*sum{"cpu": {}, "memory": {}}
	for _, c := range cs {
		cm, _ := c.(map[string]any)
		for kind, by := range map[string]map[string]*sum{"limits": lim, "requests": req} {
			rs, _ := nested(cm, "resources", kind).(map[string]any)
			for res, s := range by {
				q, ok := quantityOf(rs[res])
				if !ok {
					s.all = false
					continue
				}
				if res == "cpu" {
					s.total += q.MilliValue()
				} else {
					s.total += q.Value()
				}
			}
		}
	}
	used := map[string]float64{"cpu": float64(u.CPUMillis), "memory": float64(u.MemoryBytes)}
	div := map[string]float64{"cpu": 1000, "memory": 1}
	key := map[string][2]string{"cpu": {"cpuLimitMillis", "cpuRequestMillis"}, "memory": {"memoryLimitBytes", "memoryRequestBytes"}}
	for _, res := range []string{"cpu", "memory"} {
		l, r := lim[res], req[res]
		if r.total > 0 {
			m[key[res][1]] = int(r.total)
		}
		if l.all && l.total > 0 {
			m[key[res][0]] = int(l.total)
			setBase(m, res, "limit", used[res], float64(l.total), div[res])
		} else if r.total > 0 {
			setBase(m, res, "request", used[res], float64(r.total), div[res])
		}
	}
}
