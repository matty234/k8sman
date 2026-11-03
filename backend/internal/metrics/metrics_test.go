package metrics

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// fakeAPI serves canned responses by "path?query" (query optional) through a
// real httptest server, so requests go through client-go's REST client.
type fakeAPI struct {
	t      *testing.T
	routes map[string]string // key → testdata file name, or inline JSON when it starts with '{'
	status map[string]int    // key → HTTP status (with an apimachinery Status body)
	hits   map[string]*atomic.Int32
}

func newFake(t *testing.T) *fakeAPI {
	return &fakeAPI{t: t, routes: map[string]string{}, status: map[string]int{}, hits: map[string]*atomic.Int32{}}
}

func (f *fakeAPI) on(key, body string) *fakeAPI {
	f.routes[key] = body
	f.hits[key] = &atomic.Int32{}
	return f
}
func (f *fakeAPI) fail(key string, code int) *fakeAPI {
	f.status[key] = code
	f.hits[key] = &atomic.Int32{}
	return f
}

func (f *fakeAPI) serve(w http.ResponseWriter, r *http.Request) {
	keys := []string{r.URL.Path}
	if r.URL.RawQuery != "" {
		keys = append([]string{r.URL.Path + "?" + r.URL.Query().Encode()}, keys...)
	}
	for _, k := range keys {
		if code, ok := f.status[k]; ok {
			f.hits[k].Add(1)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(code)
			reason := map[int]string{404: "NotFound", 503: "ServiceUnavailable", 403: "Forbidden"}[code]
			_ = json.NewEncoder(w).Encode(map[string]any{"kind": "Status", "apiVersion": "v1", "status": "Failure", "code": code, "reason": reason, "message": "the server could not find the requested resource"})
			return
		}
		if body, ok := f.routes[k]; ok {
			f.hits[k].Add(1)
			if !strings.HasPrefix(body, "{") {
				b, err := os.ReadFile("testdata/" + body)
				if err != nil {
					f.t.Fatalf("testdata: %v", err)
				}
				body = string(b)
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(body))
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(404)
	_ = json.NewEncoder(w).Encode(map[string]any{"kind": "Status", "apiVersion": "v1", "status": "Failure", "code": 404, "reason": "NotFound", "message": "no route " + r.URL.String()})
}

func (f *fakeAPI) service() *Service {
	srv := httptest.NewServer(http.HandlerFunc(f.serve))
	f.t.Cleanup(srv.Close)
	cs, err := kubernetes.NewForConfig(&rest.Config{Host: srv.URL})
	if err != nil {
		f.t.Fatal(err)
	}
	return New(RESTGetter{RC: cs.Discovery().RESTClient()})
}

const apiservicesPath = "/apis/apiregistration.k8s.io/v1/apiservices"

// healthy is the dev cluster: metrics-server + KEDA, no custom metrics adapter.
func healthy(t *testing.T) *fakeAPI {
	return newFake(t).
		on(apiservicesPath, "apiservices.json").
		on("/apis/metrics.k8s.io/v1beta1/nodes", "nodes.json").
		on("/apis/metrics.k8s.io/v1beta1/namespaces/demo/pods", "pods-demo.json").
		on("/apis/metrics.k8s.io/v1beta1/namespaces/demo/pods?labelSelector=app%3Dweb", "pods-web.json").
		on("/apis/external.metrics.k8s.io/v1beta1", "external-discovery.json").
		on("/apis/external.metrics.k8s.io/v1beta1/namespaces/demo/s1-cron-Etc-UTC-0xxxx-30xxxx?labelSelector=scaledobject.keda.sh%2Fname%3Dweb", "external-cron.json").
		on("/apis/autoscaling/v2/namespaces/demo/horizontalpodautoscalers", "hpas-demo.json").
		on("/apis/autoscaling/v2/namespaces/demo/horizontalpodautoscalers/web", "hpa-web.json").
		on("/apis/apps/v1/namespaces/demo/deployments/web/scale", "scale-web.json").
		on("/api/v1/namespaces/demo/pods?labelSelector=app%3Dweb", "podlist-web.json")
}

func TestStatusFromAPIServices(t *testing.T) {
	s := healthy(t).service()
	st := s.Status(context.Background(), false)
	if st.Resource.State != StateAvailable || st.Resource.Service == nil || st.Resource.Service.Name != "metrics-server" {
		t.Fatalf("resource: %+v", st.Resource)
	}
	if st.External.State != StateAvailable || st.External.Service.Namespace != "keda" {
		t.Fatalf("external: %+v", st.External)
	}
	if st.Custom.State != StateNotInstalled {
		t.Fatalf("custom: %+v", st.Custom)
	}
}

func TestStatusNotReadyAndVersionPreference(t *testing.T) {
	list := `{"items":[
	 {"metadata":{"name":"v1beta1.metrics.k8s.io"},"spec":{"group":"metrics.k8s.io","version":"v1beta1","service":{"namespace":"kube-system","name":"metrics-server"}},
	  "status":{"conditions":[{"type":"Available","status":"False","reason":"MissingEndpoints","message":"endpoints for service/metrics-server in \"kube-system\" have no addresses"}]}},
	 {"metadata":{"name":"v1beta1.custom.metrics.k8s.io"},"spec":{"group":"custom.metrics.k8s.io","version":"v1beta1","service":{"namespace":"monitoring","name":"prometheus-adapter"}},"status":{"conditions":[{"type":"Available","status":"True"}]}},
	 {"metadata":{"name":"v1beta2.custom.metrics.k8s.io"},"spec":{"group":"custom.metrics.k8s.io","version":"v1beta2","service":{"namespace":"monitoring","name":"prometheus-adapter"}},"status":{"conditions":[{"type":"Available","status":"True"}]}}
	]}`
	f := newFake(t).on(apiservicesPath, list).fail("/apis/metrics.k8s.io/v1beta1/nodes", 503)
	s := f.service()
	st := s.Status(context.Background(), false)
	if st.Resource.State != StateNotReady || st.Resource.Reason != "MissingEndpoints" {
		t.Fatalf("resource: %+v", st.Resource)
	}
	if st.Custom.Version != "v1beta2" || len(st.Custom.Versions) != 2 {
		t.Fatalf("custom should prefer v1beta2: %+v", st.Custom)
	}
	_, err := s.Nodes(context.Background())
	var ue *UnavailableError
	if !errors.As(err, &ue) || ue.Status.State != StateNotReady {
		t.Fatalf("want notReady error, got %v", err)
	}
	if !strings.Contains(err.Error(), "not ready yet") {
		t.Fatalf("message: %v", err)
	}
}

func TestNotInstalled(t *testing.T) {
	s := newFake(t).on(apiservicesPath, `{"items":[]}`).service()
	_, err := s.Nodes(context.Background())
	var ue *UnavailableError
	if !errors.As(err, &ue) || ue.Status.State != StateNotInstalled {
		t.Fatalf("want notInstalled, got %v", err)
	}
	if d := s.UsageDecorator(context.Background(), "", "pods", "demo"); d != nil {
		t.Fatal("decorator should be nil without metrics-server")
	}
	if _, err := s.DiscoverCustom(context.Background()); !errors.As(err, &ue) || ue.Status.State != StateNotInstalled {
		t.Fatalf("custom discover: %v", err)
	}
}

func TestEmptyNodeListIsNoData(t *testing.T) {
	s := newFake(t).on(apiservicesPath, "apiservices.json").
		on("/apis/metrics.k8s.io/v1beta1/nodes", `{"kind":"NodeMetricsList","items":[]}`).service()
	_, err := s.Nodes(context.Background())
	var ue *UnavailableError
	if !errors.As(err, &ue) || ue.Status.State != StateNotReady {
		t.Fatalf("empty list should read as not ready, got %v", err)
	}
}

func TestStatusFallsBackToDiscovery(t *testing.T) {
	s := newFake(t).fail(apiservicesPath, 403).
		on("/apis/metrics.k8s.io/v1beta1", `{"kind":"APIResourceList"}`).
		fail("/apis/external.metrics.k8s.io/v1beta1", 503).
		service()
	st := s.Status(context.Background(), false)
	if st.Resource.State != StateAvailable || st.External.State != StateNotReady || st.Custom.State != StateNotInstalled {
		t.Fatalf("got %+v", st)
	}
}

func TestNodesAndPodsParse(t *testing.T) {
	s := healthy(t).service()
	nodes, err := s.Nodes(context.Background())
	if err != nil || len(nodes) != 1 {
		t.Fatalf("nodes: %v %v", nodes, err)
	}
	n := nodes[0]
	// 3454908092n → 3455m (rounded up); 5687780Ki → bytes.
	if n.CPUMillis != 3455 || n.CPU != "3455m" || n.MemoryBytes != 5687780*1024 || n.Memory != "5824286720" {
		t.Fatalf("node usage: %+v", n)
	}
	pods, err := s.PodsSelected(context.Background(), "demo", "app=web")
	if err != nil || len(pods) != 2 {
		t.Fatalf("pods: %v %v", pods, err)
	}
	p := pods[0]
	if p.Name != "web-6fd47b8fcb-442dt" || len(p.Containers) != 2 {
		t.Fatalf("pod: %+v", p)
	}
	// log-sidecar 6489274n → 7m, nginx 206320n → 1m.
	if p.CPUMillis != 8 || p.MemoryBytes != (580+6556)*1024 {
		t.Fatalf("pod total: %+v", p.Usage)
	}
}

func TestUsageCacheAndAllNamespaces(t *testing.T) {
	f := healthy(t).on("/apis/metrics.k8s.io/v1beta1/pods", "pods-demo.json")
	s := f.service()
	now := time.Unix(1000, 0)
	s.now = func() time.Time { return now }
	ctx := context.Background()
	for range 3 {
		if _, err := s.Nodes(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if got := f.hits["/apis/metrics.k8s.io/v1beta1/nodes"].Load(); got != 1 {
		t.Fatalf("nodes fetched %d times within TTL", got)
	}
	now = now.Add(11 * time.Second)
	_, _ = s.Nodes(ctx)
	if got := f.hits["/apis/metrics.k8s.io/v1beta1/nodes"].Load(); got != 2 {
		t.Fatalf("nodes not refetched after TTL: %d", got)
	}
	// An all-namespaces snapshot serves a single namespace.
	if _, err := s.Pods(ctx, ""); err != nil {
		t.Fatal(err)
	}
	demo, err := s.Pods(ctx, "demo")
	if err != nil || len(demo) == 0 {
		t.Fatalf("demo: %v %v", demo, err)
	}
	if got := f.hits["/apis/metrics.k8s.io/v1beta1/namespaces/demo/pods"].Load(); got != 0 {
		t.Fatalf("namespace fetched although all-namespaces snapshot was fresh")
	}
}

func TestUsageDecoratorCopies(t *testing.T) {
	s := healthy(t).service()
	ctx := context.Background()
	d := s.UsageDecorator(ctx, "", "nodes", "")
	if d == nil {
		t.Fatal("nil decorator")
	}
	node := map[string]any{
		"metadata": map[string]any{"name": "k8sman-dev-control-plane"},
		"status":   map[string]any{"allocatable": map[string]any{"cpu": "10", "memory": "8025100Ki"}},
	}
	out := d(node)
	if _, mutated := node[UsageKey]; mutated {
		t.Fatal("decorator mutated the original object")
	}
	u := out[UsageKey].(map[string]any)["usage"].(map[string]any)
	if u["cpu"] != "3455m" || u["cpuMillis"] != 3455 || u["cpuPercent"] != 35 || u["memoryPercent"] != 71 {
		t.Fatalf("usage: %v", u)
	}
	// Unknown objects pass through unchanged (rendered as "—").
	other := map[string]any{"metadata": map[string]any{"name": "nope"}}
	if got := d(other); got[UsageKey] != nil {
		t.Fatal("unknown node got usage")
	}

	pd := s.UsageDecorator(ctx, "", "pods", "demo")
	pod := map[string]any{"metadata": map[string]any{"name": "redis-0", "namespace": "demo"}}
	pu := pd(pod)[UsageKey].(map[string]any)["usage"].(map[string]any)
	cs := pu["containers"].(map[string]any)
	if _, ok := cs["redis"]; !ok || pu["window"] == nil {
		t.Fatalf("pod usage: %v", pu)
	}
	if s.UsageDecorator(ctx, "apps", "deployments", "") != nil {
		t.Fatal("deployments should not be decorated")
	}
}

func TestCustomDiscoveryAndValues(t *testing.T) {
	apis := `{"items":[{"metadata":{"name":"v1beta2.custom.metrics.k8s.io"},"spec":{"group":"custom.metrics.k8s.io","version":"v1beta2","service":{"namespace":"monitoring","name":"prometheus-adapter"}},"status":{"conditions":[{"type":"Available","status":"True"}]}}]}`
	disc := `{"kind":"APIResourceList","groupVersion":"custom.metrics.k8s.io/v1beta2","resources":[
	 {"name":"pods/http_requests_per_second","namespaced":true,"kind":"MetricValueList","verbs":["get"]},
	 {"name":"pods/http_requests_per_second","namespaced":false,"kind":"MetricValueList","verbs":["get"]},
	 {"name":"pods/memory_rss","namespaced":true,"kind":"MetricValueList","verbs":["get"]},
	 {"name":"namespaces/http_requests_per_second","namespaced":false,"kind":"MetricValueList","verbs":["get"]},
	 {"name":"deployments.apps/queue_depth","namespaced":true,"kind":"MetricValueList","verbs":["get"]}]}`
	values := `{"kind":"MetricValueList","apiVersion":"custom.metrics.k8s.io/v1beta2","items":[
	 {"describedObject":{"kind":"Pod","namespace":"demo","name":"web-b","apiVersion":"/v1"},"metric":{"name":"http_requests_per_second","selector":null},"timestamp":"2026-11-03T12:00:00Z","windowSeconds":60,"value":"2500m"},
	 {"describedObject":{"kind":"Pod","namespace":"demo","name":"web-a","apiVersion":"/v1"},"metric":{"name":"http_requests_per_second","selector":null},"timestamp":"2026-11-03T12:00:00Z","windowSeconds":60,"value":"1"}]}`
	one := `{"kind":"MetricValueList","apiVersion":"custom.metrics.k8s.io/v1beta2","items":[
	 {"describedObject":{"kind":"Deployment","namespace":"demo","name":"web","apiVersion":"apps/v1"},"metric":{"name":"queue_depth"},"timestamp":"2026-11-03T12:00:00Z","value":"42"}]}`
	s := newFake(t).on(apiservicesPath, apis).
		on("/apis/custom.metrics.k8s.io/v1beta2", disc).
		on("/apis/custom.metrics.k8s.io/v1beta2/namespaces/demo/pods/*/http_requests_per_second?labelSelector=app%3Dweb", values).
		on("/apis/custom.metrics.k8s.io/v1beta2/namespaces/demo/deployments.apps/web/queue_depth", one).
		service()
	ctx := context.Background()
	d, err := s.DiscoverCustom(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if d.Version != "v1beta2" || len(d.Resources) != 3 {
		t.Fatalf("discovery: %+v", d)
	}
	pods := d.Resources[1] // sorted: core namespaces, core pods, apps deployments
	if d.Resources[0].Resource != "namespaces" || pods.Resource != "pods" || !pods.Namespaced || len(pods.Metrics) != 2 {
		t.Fatalf("pods: %+v", d.Resources)
	}
	if d.Resources[2].Group != "apps" || d.Resources[2].Metrics[0] != "queue_depth" {
		t.Fatalf("deployments: %+v", d.Resources[2])
	}

	vals, err := s.Custom(ctx, CustomQuery{Resource: "pods", Namespace: "demo", Selector: "app=web", Metric: "http_requests_per_second"})
	if err != nil {
		t.Fatal(err)
	}
	if len(vals) != 2 || vals[0].Object.Name != "web-a" || vals[1].Number != 2.5 || *vals[1].WindowSeconds != 60 {
		t.Fatalf("values: %+v", vals)
	}
	obj, err := s.Custom(ctx, CustomQuery{Group: "apps", Resource: "deployments", Namespace: "demo", Name: "web", Metric: "queue_depth"})
	if err != nil || len(obj) != 1 || obj[0].Number != 42 {
		t.Fatalf("object: %+v %v", obj, err)
	}
}

func TestCustomPath(t *testing.T) {
	cases := map[string]CustomQuery{
		"/apis/custom.metrics.k8s.io/v1beta2/namespaces/demo/pods/*/rps":             {Resource: "pods", Namespace: "demo", Metric: "rps"},
		"/apis/custom.metrics.k8s.io/v1beta2/namespaces/demo/deployments.apps/web/q": {Group: "apps", Resource: "deployments", Namespace: "demo", Name: "web", Metric: "q"},
		"/apis/custom.metrics.k8s.io/v1beta2/nodes/n1/load":                          {Resource: "nodes", Name: "n1", Metric: "load"},
		"/apis/custom.metrics.k8s.io/v1beta2/namespaces/demo/metrics/rps":            {Resource: "namespaces", Name: "demo", Metric: "rps"},
	}
	for want, q := range cases {
		if got := CustomPath("v1beta2", q); got != want {
			t.Errorf("CustomPath(%+v) = %s, want %s", q, got, want)
		}
	}
}

func TestCustomV1beta1Shape(t *testing.T) {
	raw := []byte(`{"kind":"MetricValueList","items":[{"describedObject":{"kind":"Pod","namespace":"demo","name":"a"},"metricName":"rps","timestamp":"2026-11-03T12:00:00Z","window":30,"value":"750m"}]}`)
	vals, err := parseCustomValues(raw)
	if err != nil || len(vals) != 1 || vals[0].Metric != "rps" || vals[0].Number != 0.75 || *vals[0].WindowSeconds != 30 {
		t.Fatalf("%+v %v", vals, err)
	}
}

func TestExternalDiscoveryAndValues(t *testing.T) {
	s := healthy(t).service()
	ctx := context.Background()
	d, err := s.DiscoverExternal(ctx, "demo")
	if err != nil {
		t.Fatal(err)
	}
	// KEDA only advertises "externalmetrics"; the real name comes from the HPA.
	if len(d.Metrics) != 1 || d.Metrics[0].Source != "hpa" || d.Metrics[0].Selector != "scaledobject.keda.sh/name=web" || d.Metrics[0].HPA != "web" {
		t.Fatalf("discovery: %+v", d)
	}
	vals, err := s.External(ctx, ExternalQuery{Namespace: "demo", Metric: d.Metrics[0].Name, Selector: d.Metrics[0].Selector})
	if err != nil || len(vals) != 1 || vals[0].Number != 1 {
		t.Fatalf("values: %+v %v", vals, err)
	}
}

func TestAnalyzeHPA(t *testing.T) {
	s := healthy(t).service()
	a, err := s.AnalyzeHPA(context.Background(), "demo", "web")
	if err != nil {
		t.Fatal(err)
	}
	if a.Selector != "app=web" || a.CurrentReplicas != 2 || a.MinReplicas != 2 || a.MaxReplicas != 5 || len(a.Metrics) != 2 {
		t.Fatalf("analysis: %+v", a)
	}
	ext, cpu := a.Metrics[0], a.Metrics[1]
	if ext.Type != "External" || ext.Error != "" || ext.TargetType != "AverageValue" || ext.Current != "500m" || *ext.Proposed != 1 {
		t.Fatalf("external: %+v", ext)
	}
	// usage 7m+1m + 1m+4m = 13m over requests 2×55m → 12%.
	if cpu.Type != "Resource" || cpu.Utilization == nil || *cpu.Utilization != 12 || cpu.Pods != 2 || *cpu.Proposed != 1 {
		t.Fatalf("cpu: %+v", cpu)
	}
	if *a.Proposed != 2 || a.LimitedBy != "min" {
		t.Fatalf("proposed %v limitedBy %q", *a.Proposed, a.LimitedBy)
	}
}

func TestProposals(t *testing.T) {
	var m HPAMetric
	proposeRatio(&m, 140, 70, 3, 3) // 2× target over 3 pods → 6
	if *m.Proposed != 6 {
		t.Fatalf("ratio: %d", *m.Proposed)
	}
	proposeRatio(&m, 75, 70, 3, 3) // within 10% tolerance → keep 3
	if *m.Proposed != 3 {
		t.Fatalf("tolerance: %d", *m.Proposed)
	}
	proposeTotal(&m, 30, 4, 2) // 30 total / 4 per pod → 8
	if *m.Proposed != 8 {
		t.Fatalf("total: %d", *m.Proposed)
	}
	if pluralize("Deployment") != "deployments" || pluralize("Ingress") != "ingresses" || pluralize("Policy") != "policies" {
		t.Fatal("pluralize")
	}
}

func TestHandlersErrorStates(t *testing.T) {
	s := newFake(t).on(apiservicesPath, `{"items":[]}`).service()
	mux := http.NewServeMux()
	(&handlers{svc: func() *Service { return s }}).register(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	get := func(path string) (int, map[string]any) {
		res, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var body map[string]any
		_ = json.NewDecoder(res.Body).Decode(&body)
		return res.StatusCode, body
	}
	if code, body := get("/api/metrics/nodes"); code != 404 || body["state"] != StateNotInstalled || body["group"] != ResourceGroup {
		t.Fatalf("nodes: %d %v", code, body)
	}
	if code, _ := get("/api/metrics/custom?resource=pods"); code != 400 {
		t.Fatalf("custom without metric: %d", code)
	}
	if code, _ := get("/api/metrics/external?metric=x"); code != 400 {
		t.Fatalf("external without namespace: %d", code)
	}
	if code, body := get("/api/metrics/status"); code != 200 || body["resource"].(map[string]any)["state"] != StateNotInstalled {
		t.Fatalf("status: %d %v", code, body)
	}
}
