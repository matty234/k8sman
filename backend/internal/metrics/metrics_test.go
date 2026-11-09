package metrics

import (
	"context"
	"encoding/json"
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

func TestCustomValues(t *testing.T) {
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
