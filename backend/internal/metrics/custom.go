package metrics

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/api/resource"
)

// MetricResource is one resource type that has custom metrics.
type MetricResource struct {
	// Resource is the plural (e.g. "pods"), Group its API group ("" = core).
	Resource   string   `json:"resource"`
	Group      string   `json:"group"`
	Namespaced bool     `json:"namespaced"`
	Metrics    []string `json:"metrics"`
}

// CustomDiscovery lists the custom metrics the adapter advertises.
type CustomDiscovery struct {
	Version   string           `json:"version"`
	Resources []MetricResource `json:"resources"`
}

type apiResourceList struct {
	Resources []struct {
		Name       string `json:"name"`
		Namespaced bool   `json:"namespaced"`
	} `json:"resources"`
}

func (s *Service) groupVersion(ctx context.Context, group string) (string, error) {
	st := s.Status(ctx, false).Of(group)
	if st.State == StateNotInstalled {
		// The cache may be stale (just installed): look again before giving up.
		st = s.Status(ctx, true).Of(group)
	}
	if st.State == StateNotInstalled {
		return "", &UnavailableError{Status: st}
	}
	if st.Version != "" {
		return st.Version, nil
	}
	return versionPreference[group][0], nil
}

// DiscoverCustom lists custom metric names grouped by resource. Discovery
// names look like "pods/http_requests" or "deployments.apps/queue_depth".
func (s *Service) DiscoverCustom(ctx context.Context) (CustomDiscovery, error) {
	v, err := s.groupVersion(ctx, CustomGroup)
	if err != nil {
		return CustomDiscovery{}, err
	}
	raw, err := s.get.Get(ctx, "/apis/"+CustomGroup+"/"+v, nil)
	if err != nil {
		return CustomDiscovery{}, s.explain(ctx, CustomGroup, err)
	}
	var l apiResourceList
	if err := json.Unmarshal(raw, &l); err != nil {
		return CustomDiscovery{}, err
	}
	return CustomDiscovery{Version: v, Resources: groupCustomResources(l)}, nil
}

func groupCustomResources(l apiResourceList) []MetricResource {
	type key struct{ res, group string }
	by := map[key]*MetricResource{}
	for _, r := range l.Resources {
		slash := strings.Index(r.Name, "/")
		if slash <= 0 {
			continue
		}
		gr, metric := r.Name[:slash], r.Name[slash+1:]
		res, group, _ := strings.Cut(gr, ".")
		k := key{res, group}
		mr := by[k]
		if mr == nil {
			mr = &MetricResource{Resource: res, Group: group}
			by[k] = mr
		}
		// Adapters list each metric twice (namespaced and cluster-scoped);
		// remember that it can be namespaced.
		mr.Namespaced = mr.Namespaced || r.Namespaced
		if !slices.Contains(mr.Metrics, metric) {
			mr.Metrics = append(mr.Metrics, metric)
		}
	}
	out := make([]MetricResource, 0, len(by))
	for _, mr := range by {
		sort.Strings(mr.Metrics)
		out = append(out, *mr)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Group != out[j].Group {
			return out[i].Group < out[j].Group
		}
		return out[i].Resource < out[j].Resource
	})
	return out
}

// ObjectRef identifies the object a custom metric describes.
type ObjectRef struct {
	Kind       string `json:"kind"`
	Namespace  string `json:"namespace,omitempty"`
	Name       string `json:"name"`
	APIVersion string `json:"apiVersion,omitempty"`
}

// MetricValue is one custom or external metric sample.
type MetricValue struct {
	// Object is set for custom metrics.
	Object *ObjectRef `json:"object,omitempty"`
	Metric string     `json:"metric"`
	// Labels are an external metric's labels, or a custom metric's selector.
	Labels map[string]string `json:"labels,omitempty"`
	// Value is the quantity as served; Number is the same as a float.
	Value         string  `json:"value"`
	Number        float64 `json:"number"`
	Timestamp     string  `json:"timestamp,omitempty"`
	WindowSeconds *int64  `json:"windowSeconds,omitempty"`
}

// CustomQuery selects custom metric values.
type CustomQuery struct {
	Group, Resource, Namespace string
	// Name of one object; empty means all objects (optionally filtered by Selector).
	Name     string
	Selector string
	Metric   string
	// MetricSelector filters series by metric labels (metricLabelSelector).
	MetricSelector string
}

type customValueList struct {
	Items []struct {
		DescribedObject ObjectRef `json:"describedObject"`
		// v1beta2
		Metric struct {
			Name     string `json:"name"`
			Selector *struct {
				MatchLabels map[string]string `json:"matchLabels"`
			} `json:"selector"`
		} `json:"metric"`
		// v1beta1
		MetricName    string `json:"metricName"`
		Timestamp     string `json:"timestamp"`
		WindowSeconds *int64 `json:"windowSeconds"`
		Window        *int64 `json:"window"` // v1beta1
		Value         string `json:"value"`
	} `json:"items"`
}

// CustomPath builds the custom.metrics.k8s.io path for a query.
func CustomPath(version string, q CustomQuery) string {
	gr := q.Resource
	if q.Group != "" {
		gr += "." + q.Group
	}
	name := q.Name
	if name == "" {
		name = "*"
	}
	base := "/apis/" + CustomGroup + "/" + version
	// Metrics about namespaces themselves: /namespaces/{ns}/metrics/{metric}.
	if q.Resource == "namespaces" && q.Group == "" {
		ns := q.Name
		if ns == "" {
			ns = q.Namespace
		}
		return base + "/namespaces/" + url.PathEscape(ns) + "/metrics/" + url.PathEscape(q.Metric)
	}
	if q.Namespace != "" {
		base += "/namespaces/" + url.PathEscape(q.Namespace)
	}
	if name != "*" {
		name = url.PathEscape(name)
	}
	return base + "/" + url.PathEscape(gr) + "/" + name + "/" + url.PathEscape(q.Metric)
}

// Custom returns custom metric values.
func (s *Service) Custom(ctx context.Context, q CustomQuery) ([]MetricValue, error) {
	if q.Resource == "" || q.Metric == "" {
		return nil, fmt.Errorf("resource and metric are required")
	}
	v, err := s.groupVersion(ctx, CustomGroup)
	if err != nil {
		return nil, err
	}
	params := url.Values{}
	if q.Selector != "" && q.Name == "" {
		params.Set("labelSelector", q.Selector)
	}
	if q.MetricSelector != "" {
		params.Set("metricLabelSelector", q.MetricSelector)
	}
	raw, err := s.get.Get(ctx, CustomPath(v, q), params)
	if err != nil {
		return nil, s.explain(ctx, CustomGroup, err)
	}
	return parseCustomValues(raw)
}

func parseCustomValues(raw []byte) ([]MetricValue, error) {
	// A single-object request may return a MetricValueList with one item;
	// some adapters return a bare MetricValue. Accept both.
	var l customValueList
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	if l.Items == nil {
		var one struct {
			Kind string `json:"kind"`
		}
		_ = json.Unmarshal(raw, &one)
		if one.Kind == "MetricValue" {
			wrapped := append(append([]byte(`{"items":[`), raw...), []byte("]}")...)
			if err := json.Unmarshal(wrapped, &l); err != nil {
				return nil, err
			}
		}
	}
	out := make([]MetricValue, 0, len(l.Items))
	for _, it := range l.Items {
		obj := it.DescribedObject
		mv := MetricValue{Object: &obj, Metric: it.Metric.Name, Value: it.Value, Number: quantityFloat(it.Value), Timestamp: it.Timestamp, WindowSeconds: it.WindowSeconds}
		if mv.Metric == "" {
			mv.Metric = it.MetricName
		}
		if mv.WindowSeconds == nil {
			mv.WindowSeconds = it.Window
		}
		if it.Metric.Selector != nil && len(it.Metric.Selector.MatchLabels) > 0 {
			mv.Labels = it.Metric.Selector.MatchLabels
		}
		out = append(out, mv)
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i].Object, out[j].Object
		if a.Namespace != b.Namespace {
			return a.Namespace < b.Namespace
		}
		return a.Name < b.Name
	})
	return out, nil
}

// ExternalMetric is a discovered external metric name, with where it came
// from: the adapter's discovery document, or an HPA that references it
// (adapters like KEDA only advertise a generic "externalmetrics" resource,
// so HPAs are where the real names and selectors live).
type ExternalMetric struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace,omitempty"`
	Selector  string `json:"selector,omitempty"`
	Source    string `json:"source"` // "discovery" | "hpa"
	HPA       string `json:"hpa,omitempty"`
}

// ExternalDiscovery lists external metric names.
type ExternalDiscovery struct {
	Version string           `json:"version"`
	Metrics []ExternalMetric `json:"metrics"`
}

// DiscoverExternal lists external metric names from discovery, plus those
// referenced by HPAs in namespace ("" = all).
func (s *Service) DiscoverExternal(ctx context.Context, namespace string) (ExternalDiscovery, error) {
	v, err := s.groupVersion(ctx, ExternalGroup)
	if err != nil {
		return ExternalDiscovery{}, err
	}
	raw, err := s.get.Get(ctx, "/apis/"+ExternalGroup+"/"+v, nil)
	if err != nil {
		return ExternalDiscovery{}, s.explain(ctx, ExternalGroup, err)
	}
	var l apiResourceList
	if err := json.Unmarshal(raw, &l); err != nil {
		return ExternalDiscovery{}, err
	}
	out := ExternalDiscovery{Version: v, Metrics: []ExternalMetric{}}
	for _, r := range l.Resources {
		if r.Name == "externalmetrics" || strings.Contains(r.Name, "/") {
			continue // KEDA's generic placeholder
		}
		out.Metrics = append(out.Metrics, ExternalMetric{Name: r.Name, Source: "discovery"})
	}
	if refs, err := s.hpaMetricRefs(ctx, namespace); err == nil {
		for _, r := range refs {
			if r.Type == "External" {
				out.Metrics = append(out.Metrics, ExternalMetric{Name: r.Metric, Namespace: r.Namespace, Selector: r.Selector, Source: "hpa", HPA: r.HPA})
			}
		}
	}
	sort.SliceStable(out.Metrics, func(i, j int) bool {
		a, b := out.Metrics[i], out.Metrics[j]
		if a.Name != b.Name {
			return a.Name < b.Name
		}
		return a.Namespace < b.Namespace
	})
	return out, nil
}

// ExternalQuery selects external metric values.
type ExternalQuery struct {
	Namespace, Metric, Selector string
}

type externalValueList struct {
	Items []struct {
		MetricName    string            `json:"metricName"`
		MetricLabels  map[string]string `json:"metricLabels"`
		Timestamp     string            `json:"timestamp"`
		WindowSeconds *int64            `json:"window"`
		Value         string            `json:"value"`
	} `json:"items"`
}

// External returns external metric values.
func (s *Service) External(ctx context.Context, q ExternalQuery) ([]MetricValue, error) {
	if q.Metric == "" || q.Namespace == "" {
		return nil, fmt.Errorf("namespace and metric are required")
	}
	v, err := s.groupVersion(ctx, ExternalGroup)
	if err != nil {
		return nil, err
	}
	var params url.Values
	if q.Selector != "" {
		params = url.Values{"labelSelector": {q.Selector}}
	}
	path := "/apis/" + ExternalGroup + "/" + v + "/namespaces/" + url.PathEscape(q.Namespace) + "/" + url.PathEscape(q.Metric)
	raw, err := s.get.Get(ctx, path, params)
	if err != nil {
		return nil, s.explain(ctx, ExternalGroup, err)
	}
	var l externalValueList
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	out := make([]MetricValue, 0, len(l.Items))
	for _, it := range l.Items {
		name := it.MetricName
		if name == "" {
			name = q.Metric
		}
		out = append(out, MetricValue{Metric: name, Labels: it.MetricLabels, Value: it.Value, Number: quantityFloat(it.Value), Timestamp: it.Timestamp, WindowSeconds: it.WindowSeconds})
	}
	return out, nil
}

// quantityFloat parses a quantity ("500m", "12", "1Ki") to a float64.
func quantityFloat(s string) float64 {
	q, err := resource.ParseQuantity(s)
	if err != nil {
		return 0
	}
	return q.AsApproximateFloat64()
}
