package prom

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/intstr"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/kubernetes"
	kfake "k8s.io/client-go/kubernetes/fake"
	"k8s.io/client-go/rest"
	k8stesting "k8s.io/client-go/testing"
)

// ---- fake API server proxy ---------------------------------------------------

// fakeUpstream emulates the API server's service proxy in front of
// Prometheus/Alertmanager: it serves canned bodies keyed by
// "<service>:<port><path>" and records requests.
type fakeUpstream struct {
	t      *testing.T
	mu     sync.Mutex
	routes map[string]func(w http.ResponseWriter, r *http.Request)
	seen   []string
	bodies map[string]string
}

func newUpstream(t *testing.T) (*fakeUpstream, *httptest.Server) {
	u := &fakeUpstream{t: t, routes: map[string]func(http.ResponseWriter, *http.Request){}, bodies: map[string]string{}}
	srv := httptest.NewServer(http.HandlerFunc(u.serve))
	t.Cleanup(srv.Close)
	return u, srv
}

func (u *fakeUpstream) json(key, body string) {
	u.routes[key] = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, body)
	}
}

func (u *fakeUpstream) serve(w http.ResponseWriter, r *http.Request) {
	// /api/v1/namespaces/<ns>/services/<scheme>:<svc>:<port>/proxy/<path>
	p := r.URL.Path
	const pre = "/api/v1/namespaces/"
	if !strings.HasPrefix(p, pre) {
		http.NotFound(w, r)
		return
	}
	rest := strings.TrimPrefix(p, pre)
	parts := strings.SplitN(rest, "/", 4) // ns, services, scheme:svc:port, proxy/...
	if len(parts) < 4 || parts[1] != "services" || !strings.HasPrefix(parts[3], "proxy") {
		http.NotFound(w, r)
		return
	}
	sp := strings.SplitN(parts[2], ":", 3)
	key := sp[1] + ":" + sp[2] + strings.TrimPrefix(parts[3], "proxy")
	u.mu.Lock()
	u.seen = append(u.seen, r.Method+" "+parts[0]+"/"+key+"?"+r.URL.RawQuery)
	if r.Body != nil {
		b, _ := io.ReadAll(r.Body)
		u.bodies[r.Method+" "+key] = string(b)
	}
	h := u.routes[r.Method+" "+key]
	if h == nil {
		h = u.routes[key]
	}
	u.mu.Unlock()
	if h == nil {
		w.WriteHeader(404)
		_, _ = io.WriteString(w, "404 page not found")
		return
	}
	h(w, r)
}

func restFor(t *testing.T, srv *httptest.Server) rest.Interface {
	t.Helper()
	cs, err := kubernetes.NewForConfig(&rest.Config{Host: srv.URL})
	if err != nil {
		t.Fatal(err)
	}
	return cs.CoreV1().RESTClient()
}

// ---- cluster fixtures --------------------------------------------------------

func cr(gvr schema.GroupVersionResource, kind, ns, name string, spec map[string]any) *unstructured.Unstructured {
	u := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": gvr.Group + "/" + gvr.Version,
		"kind":       kind,
		"metadata":   map[string]any{"namespace": ns, "name": name, "uid": "4cdd29ef-e80e-434c-b72a-91120a282b32"},
		"spec":       spec,
		"status":     map[string]any{"availableReplicas": int64(1)},
	}}
	return u
}

func svc(ns, name string, sel map[string]string, ports ...corev1.ServicePort) *corev1.Service {
	return &corev1.Service{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name}, Spec: corev1.ServiceSpec{Selector: sel, Ports: ports}}
}

func port(name string, p int32) corev1.ServicePort {
	return corev1.ServicePort{Name: name, Port: p, Protocol: corev1.ProtocolTCP, TargetPort: intstr.FromInt32(p)}
}

func dynClient(objs ...runtime.Object) *dynamicfake.FakeDynamicClient {
	return dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{
		PrometheusGVR:     "PrometheusList",
		AlertmanagerGVR:   "AlertmanagerList",
		PrometheusRuleGVR: "PrometheusRuleList",
	}, objs...)
}

// kubePromStack mirrors what kube-prometheus-stack creates.
func kubePromStack() (*dynamicfake.FakeDynamicClient, *kfake.Clientset) {
	dyn := dynClient(
		cr(PrometheusGVR, "Prometheus", "monitoring", "kps-prometheus", map[string]any{"replicas": int64(1), "version": "v3.0.0"}),
		cr(AlertmanagerGVR, "Alertmanager", "monitoring", "kps-alertmanager", map[string]any{"routePrefix": "/am/"}),
		cr(PrometheusRuleGVR, "PrometheusRule", "demo", "k8sman-demo", map[string]any{"groups": []any{map[string]any{"name": "k8sman-demo.alerts"}}}),
	)
	typed := kfake.NewSimpleClientset(
		svc("monitoring", "prometheus-operated", map[string]string{"app.kubernetes.io/name": "prometheus"}, port("http-web", 9090)),
		svc("monitoring", "kps-prometheus", map[string]string{"app.kubernetes.io/name": "prometheus", "operator.prometheus.io/name": "kps-prometheus"}, port("http-web", 9090), port("reloader-web", 8080)),
		svc("monitoring", "alertmanager-operated", map[string]string{"app.kubernetes.io/name": "alertmanager"}, port("http-web", 9093), port("tcp-mesh", 9094)),
		svc("monitoring", "kps-alertmanager", map[string]string{"app.kubernetes.io/name": "alertmanager", "alertmanager": "kps-alertmanager"}, port("http-web", 9093)),
		svc("monitoring", "kps-grafana", map[string]string{"app.kubernetes.io/name": "grafana"}, port("http-web", 80)),
	)
	return dyn, typed
}

const (
	promBuildinfo = `{"status":"success","data":{"version":"3.0.1"}}`
	amStatus      = `{"versionInfo":{"version":"0.28.0"},"cluster":{"status":"ready"}}`
	amAlertsJSON  = `[
 {"labels":{"alertname":"KubePodCrashLooping","severity":"warning","namespace":"demo","pod":"crashy","container":"app","job":"kube-state-metrics"},
  "annotations":{"summary":"Pod is crash looping.","description":"Pod demo/crashy (app) is in waiting state (reason: \"CrashLoopBackOff\").","runbook_url":"https://runbooks.prometheus-operator.dev/runbooks/kubernetes/kubepodcrashlooping"},
  "startsAt":"2026-11-03T11:00:00Z","endsAt":"2026-11-03T13:00:00Z","updatedAt":"2026-11-03T12:00:00Z","fingerprint":"aaa1",
  "receivers":[{"name":"null"}],"status":{"state":"active","silencedBy":[],"inhibitedBy":[]}},
 {"labels":{"alertname":"KubePodCrashLooping","severity":"warning","namespace":"shop","pod":"api-0","container":"api"},
  "annotations":{"summary":"Pod is crash looping."},"startsAt":"2026-11-03T11:30:00Z","fingerprint":"aaa2",
  "status":{"state":"suppressed","silencedBy":["sil-1"],"inhibitedBy":[]}},
 {"labels":{"alertname":"K8smanDemoPodCrashLooping","severity":"critical","namespace":"demo","pod":"crashy"},
  "annotations":{"summary":"Pod demo/crashy is crash looping"},"startsAt":"2026-11-03T11:45:00Z","fingerprint":"bbb1",
  "status":{"state":"active","silencedBy":[],"inhibitedBy":[]}},
 {"labels":{"alertname":"KubeDeploymentRolloutStuck","severity":"warning","namespace":"shop","deployment":"web","pod":"kube-state-metrics-abc"},
  "annotations":{},"startsAt":"2026-11-03T10:00:00Z","fingerprint":"ccc1","status":{"state":"suppressed","silencedBy":[],"inhibitedBy":["ddd1"]}},
 {"labels":{"alertname":"Watchdog","severity":"none"},"annotations":{},"startsAt":"2026-11-03T09:00:00Z","fingerprint":"eee1",
  "status":{"state":"active","silencedBy":[],"inhibitedBy":[]}}
]`
	promAlertsJSON = `{"status":"success","data":{"alerts":[
 {"labels":{"alertname":"K8smanTestAlert","severity":"warning","namespace":"demo"},"annotations":{"summary":"Test"},"state":"pending","activeAt":"2026-11-03T11:59:30Z","value":"1e+00"},
 {"labels":{"alertname":"KubePodCrashLooping","severity":"warning","namespace":"demo","pod":"crashy"},"annotations":{},"state":"firing","activeAt":"2026-11-03T10:59:00Z","value":"1e+00"}
]}}`
)

func testHandler(t *testing.T, readOnly bool) (*Handler, *fakeUpstream) {
	t.Helper()
	up, srv := newUpstream(t)
	up.json("kps-prometheus:http-web/api/v1/status/buildinfo", promBuildinfo)
	up.json("kps-alertmanager:http-web/am/api/v2/status", amStatus)
	dyn, typed := kubePromStack()
	e := env{key: "test", dyn: dyn, typed: typed, req: restRequester{rc: restFor(t, srv)}}
	h := &Handler{env: func() env { return e }, disc: newDiscoverer(), readOnly: readOnly, now: func() time.Time { return time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC) }}
	return h, up
}

func serve(t *testing.T, h *Handler, method, target, body string) *httptest.ResponseRecorder {
	t.Helper()
	mux := http.NewServeMux()
	h.register(mux)
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(method, target, rd))
	return rec
}

func decode[T any](t *testing.T, rec *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatalf("decode %q: %v", rec.Body.String(), err)
	}
	return v
}

// ---- discovery -----------------------------------------------------------

func TestDiscoveryViaCRDs(t *testing.T) {
	h, up := testHandler(t, false)
	rec := serve(t, h, "GET", "/api/prom/status", "")
	if rec.Code != 200 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	s := decode[Status](t, rec)
	if !s.OperatorCRDs || len(s.Prometheus) != 1 || len(s.Alertmanager) != 1 {
		t.Fatalf("unexpected discovery: %+v", s)
	}
	p, am := s.Prometheus[0], s.Alertmanager[0]
	// The instance-specific service wins over the governing *-operated one.
	if p.Service != "kps-prometheus" || p.Port != "http-web" || p.Source != "crd" || !p.Reachable || p.Version != "3.0.1" || !p.Default {
		t.Errorf("prometheus = %+v", p)
	}
	if am.Service != "kps-alertmanager" || am.PathPrefix != "/am" || !am.Reachable || am.Version != "0.28.0" {
		t.Errorf("alertmanager = %+v", am)
	}
	// Route prefix is honoured on the proxied path.
	found := false
	for _, s := range up.seen {
		if strings.Contains(s, "monitoring/kps-alertmanager:http-web/am/api/v2/status") {
			found = true
		}
	}
	if !found {
		t.Errorf("alertmanager status not requested under its route prefix: %v", up.seen)
	}
}

func TestDiscoveryFallbackToServices(t *testing.T) {
	up, srv := newUpstream(t)
	up.json("prometheus-server:http/api/v1/status/buildinfo", promBuildinfo)
	dyn := dynClient()
	dyn.PrependReactor("list", "*", func(a k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, apierrors.NewNotFound(schema.GroupResource{Group: "monitoring.coreos.com", Resource: a.GetResource().Resource}, "")
	})
	typed := kfake.NewSimpleClientset(
		svc("observability", "prometheus-server", map[string]string{"app": "prometheus"}, port("http", 80)),
		svc("observability", "prometheus-alertmanager", map[string]string{"app": "am"}, port("http", 9093)),
	)
	s := discover(context.Background(), env{key: "x", dyn: dyn, typed: typed, req: restRequester{rc: restFor(t, srv)}})
	if s.OperatorCRDs {
		t.Error("operatorCRDs should be false")
	}
	if len(s.Prometheus) != 1 || s.Prometheus[0].Source != "service" || s.Prometheus[0].Port != "http" || !s.Prometheus[0].Reachable {
		t.Fatalf("prometheus = %+v", *s.Prometheus[0])
	}
	if len(s.Alertmanager) != 1 || s.Alertmanager[0].Reachable || s.Alertmanager[0].Error == "" {
		t.Fatalf("alertmanager should be found but unreachable: %+v", s.Alertmanager)
	}
	if !s.Alertmanager[0].Default {
		t.Error("the only instance is the default even when unreachable")
	}
}

func TestDefaultPrefersReachableMonitoring(t *testing.T) {
	l := []*Instance{
		{ID: "a/x", Namespace: "a", Reachable: true},
		{ID: "monitoring/y", Namespace: "monitoring", Reachable: false},
		{ID: "monitoring/z", Namespace: "monitoring", Reachable: true},
	}
	pickDefault(l)
	if !l[2].Default || l[0].Default || l[1].Default {
		t.Errorf("defaults: %v %v %v", l[0].Default, l[1].Default, l[2].Default)
	}
	s := &Status{Prometheus: l}
	if s.Default(KindPrometheus, "a/x") != l[0] || s.Default(KindPrometheus, "") != l[2] || s.Default(KindPrometheus, "nope") != nil {
		t.Error("Status.Default lookup")
	}
}

func TestProxyPath(t *testing.T) {
	in := &Instance{Namespace: "monitoring", Service: "am", Port: "web", Scheme: "https", PathPrefix: "/alertmanager"}
	if got := in.ProxyPath("/api/v2/alerts"); got != "/api/v1/namespaces/monitoring/services/https:am:web/proxy/alertmanager/api/v2/alerts" {
		t.Errorf("ProxyPath = %s", got)
	}
	in.PathPrefix, in.Scheme = "", ""
	if got := in.ProxyPath("/api/v1/query"); got != "/api/v1/namespaces/monitoring/services/http:am:web/proxy/api/v1/query" {
		t.Errorf("ProxyPath = %s", got)
	}
}

// ---- alerts -------------------------------------------------------------------

func TestAlertsGroupedWithPending(t *testing.T) {
	h, up := testHandler(t, false)
	up.json("kps-alertmanager:http-web/am/api/v2/alerts", amAlertsJSON)
	up.json("kps-prometheus:http-web/api/v1/alerts", promAlertsJSON)
	rec := serve(t, h, "GET", "/api/prom/alerts", "")
	if rec.Code != 200 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	res := decode[AlertsResult](t, rec)
	if res.Errors != nil {
		t.Fatalf("errors: %v", res.Errors)
	}
	want := AlertSummary{Firing: 3, Pending: 1, Silenced: 1, Inhibited: 1, Critical: 1}
	if res.Summary != want {
		t.Errorf("summary = %+v, want %+v", res.Summary, want)
	}
	var names []string
	for _, g := range res.Groups {
		names = append(names, g.Name)
	}
	// Firing first (critical before warning before none), then pending, then inhibited.
	if got := strings.Join(names, ","); got != "K8smanDemoPodCrashLooping,KubePodCrashLooping,Watchdog,K8smanTestAlert,KubeDeploymentRolloutStuck" {
		t.Errorf("group order = %s", got)
	}
	crash := res.Groups[1]
	if len(crash.Alerts) != 2 || crash.Counts[StateFiring] != 1 || crash.Counts[StateSilenced] != 1 || crash.State != StateFiring {
		t.Errorf("KubePodCrashLooping group = %+v", crash)
	}
	a := crash.Alerts[0]
	if a.State != StateFiring || a.Fingerprint != "aaa1" || a.Annotations["runbook_url"] == "" || a.Receivers[0] != "null" || a.Source != KindAlertmanager {
		t.Errorf("first instance = %+v", a)
	}
	if a.Target == nil || a.Target.Kind != "Pod" || a.Target.Name != "crashy" || a.Target.Namespace != "demo" {
		t.Errorf("target = %+v", a.Target)
	}
	if crash.Alerts[1].State != StateSilenced || crash.Alerts[1].SilencedBy[0] != "sil-1" {
		t.Errorf("silenced instance = %+v", crash.Alerts[1])
	}
	stuck := res.Groups[4]
	if stuck.State != StateInhibited || stuck.Alerts[0].Target.Kind != "Deployment" {
		t.Errorf("rollout group = %+v", stuck)
	}
	pend := res.Groups[3]
	if pend.Alerts[0].Source != KindPrometheus || pend.Alerts[0].State != StatePending || pend.Alerts[0].Fingerprint == "" || pend.Summary != "Test" {
		t.Errorf("pending = %+v", pend)
	}
}

func TestAlertsFallBackToPrometheusWhenAlertmanagerDown(t *testing.T) {
	h, up := testHandler(t, false)
	up.routes["kps-alertmanager:http-web/am/api/v2/alerts"] = func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
		_, _ = io.WriteString(w, "no endpoints available for service")
	}
	up.json("kps-prometheus:http-web/api/v1/alerts", promAlertsJSON)
	res := decode[AlertsResult](t, serve(t, h, "GET", "/api/prom/alerts", ""))
	if !strings.Contains(res.Errors["alertmanager"], "no endpoints") {
		t.Errorf("errors = %v", res.Errors)
	}
	if res.Summary.Firing != 1 || res.Summary.Pending != 1 {
		t.Errorf("summary = %+v", res.Summary)
	}
}

func TestTargetFor(t *testing.T) {
	cases := []struct {
		labels map[string]string
		want   string
	}{
		{map[string]string{"namespace": "demo", "pod": "crashy", "container": "app"}, "/Pod demo/crashy"},
		{map[string]string{"namespace": "shop", "deployment": "web", "pod": "ksm-1"}, "apps/Deployment shop/web"},
		{map[string]string{"namespace": "shop", "statefulset": "db"}, "apps/StatefulSet shop/db"},
		{map[string]string{"namespace": "shop", "job_name": "migrate"}, "batch/Job shop/migrate"},
		{map[string]string{"namespace": "shop", "persistentvolumeclaim": "data"}, "/PersistentVolumeClaim shop/data"},
		{map[string]string{"namespace": "monitoring", "service": "kps-kubelet", "job": "kubelet"}, "/Service monitoring/kps-kubelet"},
		{map[string]string{"node": "kind-control-plane", "instance": "10.0.0.1:9100"}, "/Node /kind-control-plane"},
		{map[string]string{"pod": "orphan"}, ""}, // a pod without a namespace isn't addressable
		{map[string]string{"namespace": "demo"}, "/Namespace /demo"},
		{map[string]string{"alertname": "Watchdog"}, ""},
	}
	for _, c := range cases {
		got := ""
		if r := TargetFor(c.labels); r != nil {
			got = r.Group + "/" + r.Kind + " " + r.Namespace + "/" + r.Name
		}
		if got != c.want {
			t.Errorf("TargetFor(%v) = %q, want %q", c.labels, got, c.want)
		}
	}
}

// ---- silences -------------------------------------------------------------------

func TestSilencesListSorted(t *testing.T) {
	h, up := testHandler(t, false)
	up.json("kps-alertmanager:http-web/am/api/v2/silences", `[
	 {"id":"old","status":{"state":"expired"},"matchers":[{"name":"alertname","value":"A","isRegex":false,"isEqual":true}],"startsAt":"2026-11-01T00:00:00Z","endsAt":"2026-11-02T00:00:00Z","createdBy":"me","comment":"x"},
	 {"id":"late","status":{"state":"active"},"matchers":[],"startsAt":"2026-11-03T00:00:00Z","endsAt":"2026-11-04T00:00:00Z","createdBy":"k8sman","comment":"y"},
	 {"id":"soon","status":{"state":"active"},"matchers":[],"startsAt":"2026-11-03T00:00:00Z","endsAt":"2026-11-03T12:30:00Z","createdBy":"k8sman","comment":"z"}]`)
	res := decode[struct{ Silences []Silence }](t, serve(t, h, "GET", "/api/prom/silences", ""))
	var ids []string
	for _, s := range res.Silences {
		ids = append(ids, s.ID)
	}
	if strings.Join(ids, ",") != "soon,late,old" {
		t.Errorf("order = %v", ids)
	}
}

func TestCreateSilence(t *testing.T) {
	h, up := testHandler(t, false)
	up.json("POST kps-alertmanager:http-web/am/api/v2/silences", `{"silenceID":"new-id"}`)
	rec := serve(t, h, "POST", "/api/prom/silences", `{"matchers":[{"name":"alertname","value":"KubePodCrashLooping"},{"name":"namespace","value":"demo"}],"duration":"4h","comment":"deploying a fix"}`)
	if rec.Code != 200 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	if got := decode[map[string]any](t, rec)["silenceID"]; got != "new-id" {
		t.Errorf("silenceID = %v", got)
	}
	var sent map[string]any
	if err := json.Unmarshal([]byte(up.bodies["POST kps-alertmanager:http-web/am/api/v2/silences"]), &sent); err != nil {
		t.Fatal(err)
	}
	if sent["createdBy"] != "k8sman" || sent["startsAt"] != "2026-11-03T12:00:00Z" || sent["endsAt"] != "2026-11-03T16:00:00Z" || sent["comment"] != "deploying a fix" {
		t.Errorf("payload = %v", sent)
	}
	ms := sent["matchers"].([]any)
	if len(ms) != 2 || ms[0].(map[string]any)["isEqual"] != true {
		t.Errorf("matchers = %v", ms)
	}
}

func TestSilenceValidation(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	f := false
	bad := map[string]SilenceRequest{
		"no matchers":   {Duration: "1h", Comment: "x"},
		"match all":     {Matchers: []Matcher{{Name: "alertname", Value: ".*", IsRegex: true}}, Duration: "1h", Comment: "x"},
		"only negative": {Matchers: []Matcher{{Name: "alertname", Value: "A", IsEqual: &f}}, Duration: "1h", Comment: "x"},
		"bad regex":     {Matchers: []Matcher{{Name: "pod", Value: "(", IsRegex: true}}, Duration: "1h", Comment: "x"},
		"no comment":    {Matchers: []Matcher{{Name: "alertname", Value: "A"}}, Duration: "1h"},
		"no duration":   {Matchers: []Matcher{{Name: "alertname", Value: "A"}}, Comment: "x"},
		"too long":      {Matchers: []Matcher{{Name: "alertname", Value: "A"}}, Duration: "100d", Comment: "x"},
		"in the past":   {Matchers: []Matcher{{Name: "alertname", Value: "A"}}, EndsAt: "2026-11-03T11:00:00Z", Comment: "x"},
	}
	for name, req := range bad {
		if _, err := req.build(now); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	p, err := SilenceRequest{Matchers: []Matcher{{Name: "alertname", Value: "A"}}, Duration: "1d", Comment: " ok "}.build(now)
	if err != nil || p["endsAt"] != "2026-11-04T12:00:00Z" || p["comment"] != "ok" {
		t.Errorf("1d silence: %v %v", p, err)
	}
}

func TestExpireSilenceAndReadOnly(t *testing.T) {
	h, up := testHandler(t, false)
	up.json("DELETE kps-alertmanager:http-web/am/api/v2/silence/abc-123", ``)
	if rec := serve(t, h, "DELETE", "/api/prom/silences/abc-123", ""); rec.Code != 200 {
		t.Fatalf("expire: %d %s", rec.Code, rec.Body)
	}
	if rec := serve(t, h, "DELETE", "/api/prom/silences/..%2Fetc", ""); rec.Code != 400 {
		t.Errorf("bad id: %d", rec.Code)
	}

	ro, _ := testHandler(t, true)
	if rec := serve(t, ro, "POST", "/api/prom/silences", `{"matchers":[{"name":"alertname","value":"A"}],"duration":"1h","comment":"x"}`); rec.Code != 403 {
		t.Errorf("read-only create: %d", rec.Code)
	}
	if rec := serve(t, ro, "DELETE", "/api/prom/silences/abc", ""); rec.Code != 403 {
		t.Errorf("read-only expire: %d", rec.Code)
	}
}

// ---- rules & targets -------------------------------------------------------

const rulesJSON = `{"status":"success","data":{"groups":[
 {"name":"k8sman-demo.alerts","file":"/etc/prometheus/rules/prometheus-kps-prometheus-rulefiles-0/demo-k8sman-demo-4cdd29ef-e80e-434c-b72a-91120a282b32.yaml","interval":30,
  "rules":[{"type":"alerting","name":"K8smanTestAlert","query":"vector(1)","duration":60,"labels":{"severity":"warning"},"annotations":{"summary":"Test"},"state":"firing","health":"ok","alerts":[{"labels":{"alertname":"K8smanTestAlert"},"state":"firing","activeAt":"2026-11-03T11:00:00Z","value":"1e+00"}]},
           {"type":"recording","name":"x:sum","query":"sum(x)","health":"err","lastError":"many-to-many matching not allowed"}]},
 {"name":"node-exporter","file":"/etc/prometheus/rules/prometheus-kps-prometheus-rulefiles-0/monitoring-kps-node-exporter-11111111-2222-3333-4444-555555555555.yaml","interval":30,
  "rules":[{"type":"alerting","name":"NodeDown","query":"up == 0","state":"inactive","health":"ok"}]}
]}}`

func TestRulesMappedToPrometheusRule(t *testing.T) {
	h, up := testHandler(t, false)
	up.json("kps-prometheus:http-web/api/v1/rules", rulesJSON)
	res := decode[RulesResult](t, serve(t, h, "GET", "/api/prom/rules?namespace=demo&name=k8sman-demo", ""))
	if len(res.Groups) != 1 || res.Groups[0].Source == nil || res.Groups[0].Source.Name != "k8sman-demo" {
		t.Fatalf("groups = %+v", res.Groups)
	}
	r := res.Groups[0].Rules
	if r[0].State != StateFiring || r[0].Duration != 60 || len(r[0].Alerts) != 1 || r[1].Health != "err" || r[1].LastError == "" {
		t.Errorf("rules = %+v", r)
	}
	if res.Counts.Firing != 1 || res.Counts.Errors != 1 {
		t.Errorf("counts = %+v", res.Counts)
	}
	all := decode[RulesResult](t, serve(t, h, "GET", "/api/prom/rules", ""))
	if len(all.Groups) != 2 || all.Groups[1].Source != nil {
		t.Errorf("unfiltered = %+v", all.Groups)
	}
}

func TestMapRuleSourcesFallbacks(t *testing.T) {
	groups := []RuleGroup{
		{Name: "only-here", File: "/rules/whatever.yaml"},
		{Name: "shared", File: "/rules/team-a-alerts-0b1d0d2e-0000-4000-8000-000000000000.yaml"},
		{Name: "shared", File: "/rules/unrelated.yaml"},
	}
	MapRuleSources(groups, []promRuleRef{
		{Namespace: "x", Name: "one", Groups: []string{"only-here"}},
		{Namespace: "team-a", Name: "alerts", Groups: []string{"shared"}},
		{Namespace: "team-b", Name: "alerts", Groups: []string{"shared"}},
	})
	if s := groups[0].Source; s == nil || s.Name != "one" {
		t.Errorf("group name fallback: %+v", s)
	}
	if s := groups[1].Source; s == nil || s.Namespace != "team-a" {
		t.Errorf("file prefix without uid: %+v", s)
	}
	if groups[2].Source != nil {
		t.Errorf("ambiguous group should stay unmapped: %+v", groups[2].Source)
	}
}

const targetsJSON = `{"status":"success","data":{"activeTargets":[
 {"labels":{"job":"web","namespace":"demo","pod":"web-1","service":"web"},"scrapePool":"serviceMonitor/demo/web/0","scrapeUrl":"http://10.0.0.5:8080/metrics","lastError":"","health":"up","scrapeInterval":"30s"},
 {"labels":{"job":"web","namespace":"demo","pod":"web-2","service":"web"},"scrapePool":"serviceMonitor/demo/web/0","scrapeUrl":"http://10.0.0.6:8080/metrics","lastError":"connection refused","health":"down","scrapeInterval":"30s"},
 {"labels":{"job":"agent","namespace":"demo","pod":"agent-x"},"scrapePool":"podMonitor/demo/agent/1","scrapeUrl":"http://10.0.0.7:9000/metrics","health":"up"},
 {"labels":{"job":"prometheus"},"scrapePool":"prometheus","scrapeUrl":"http://localhost:9090/metrics","health":"unknown"}
]}}`

func TestTargetsMappedToMonitors(t *testing.T) {
	h, up := testHandler(t, false)
	up.json("kps-prometheus:http-web/api/v1/targets", targetsJSON)
	all := decode[TargetsResult](t, serve(t, h, "GET", "/api/prom/targets", ""))
	if all.Up != 2 || all.Down != 1 || all.Unknown != 1 || len(all.Pools) != 3 {
		t.Fatalf("all = %+v", all)
	}
	// Pools with failures sort first; down targets first within a pool.
	web := all.Pools[0]
	if web.ScrapePool != "serviceMonitor/demo/web/0" || web.Monitor == nil || web.Monitor.Kind != "ServiceMonitor" || web.Down != 1 || web.Targets[0].LastError != "connection refused" {
		t.Errorf("web pool = %+v", web)
	}
	if web.Targets[0].Target == nil || web.Targets[0].Target.Name != "web-2" {
		t.Errorf("target ref = %+v", web.Targets[0].Target)
	}
	pm := decode[TargetsResult](t, serve(t, h, "GET", "/api/prom/targets?kind=PodMonitor&namespace=demo&name=agent", ""))
	if len(pm.Pools) != 1 || pm.Pools[0].Monitor.Endpoint != 1 || pm.Up != 1 {
		t.Errorf("podmonitor filter = %+v", pm)
	}
	if m := MonitorForPool("prometheus"); m != nil {
		t.Errorf("non-operator pool mapped: %+v", m)
	}
}

// ---- queries ---------------------------------------------------------------

func TestQueryRangeLimitsAndPassThrough(t *testing.T) {
	h, up := testHandler(t, false)
	var got url.Values
	up.routes["kps-prometheus:http-web/api/v1/query_range"] = func(w http.ResponseWriter, r *http.Request) {
		got = r.URL.Query()
		_, _ = io.WriteString(w, `{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"pod":"a"},"values":[[1793700000,"0.5"]]}]}}`)
	}
	rec := serve(t, h, "GET", "/api/prom/query_range?query="+url.QueryEscape(`rate(x[5m])`)+"&start=-7d", "")
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	res := decode[QueryResult](t, rec)
	if res.ResultType != "matrix" || res.Series != 1 || res.Prometheus != "monitoring/kps-prometheus" {
		t.Errorf("result = %+v", res)
	}
	// 7d at the default 240 points = 42m steps; never more than maxPoints.
	if res.Step != 2520 || got.Get("step") != "2520" || got.Get("query") != "rate(x[5m])" {
		t.Errorf("step %v, upstream query %v", res.Step, got)
	}
	if rec := serve(t, h, "GET", "/api/prom/query_range?query=up&start=-60d", ""); rec.Code != 400 {
		t.Errorf("range > 31d: %d", rec.Code)
	}
	if rec := serve(t, h, "GET", "/api/prom/query_range?query=", ""); rec.Code != 400 {
		t.Errorf("empty query: %d", rec.Code)
	}
}

func TestParseRangeCapsPoints(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	p, err := ParseRange(url.Values{"start": {"-24h"}, "step": {"1s"}}, now)
	if err != nil {
		t.Fatal(err)
	}
	if pts := p.End.Sub(p.Start) / p.Step; pts > maxPoints {
		t.Errorf("%d points", pts)
	}
	p, _ = ParseRange(url.Values{"start": {"1799996400"}, "end": {"1800000000"}, "step": {"60"}}, now)
	if p.Step != time.Minute || p.End.Sub(p.Start) != time.Hour {
		t.Errorf("explicit = %+v", p)
	}
	if _, err := ParseRange(url.Values{"start": {"now"}, "end": {"-1h"}}, now); err == nil {
		t.Error("end before start should fail")
	}
}

func TestQueryErrorsAndMissingPrometheus(t *testing.T) {
	h, up := testHandler(t, false)
	up.routes["kps-prometheus:http-web/api/v1/query"] = func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		_, _ = io.WriteString(w, `{"status":"error","errorType":"bad_data","error":"parse error: unexpected end of input"}`)
	}
	rec := serve(t, h, "GET", "/api/prom/query?query=up%7B", "")
	if rec.Code != 422 || !strings.Contains(rec.Body.String(), "unexpected end of input") {
		t.Errorf("bad query: %d %s", rec.Code, rec.Body)
	}
	rec = serve(t, h, "GET", "/api/prom/query?query=up&instance=other/prom", "")
	if rec.Code != 404 || decode[apiError](t, rec).Reason != "NotFound" {
		t.Errorf("unknown instance: %d %s", rec.Code, rec.Body)
	}
}

func TestShapeResultTruncates(t *testing.T) {
	var series []string
	for i := 0; i < maxSeries+5; i++ {
		series = append(series, `{"metric":{},"value":[0,"1"]}`)
	}
	data := json.RawMessage(`{"resultType":"vector","result":[` + strings.Join(series, ",") + `]}`)
	res, err := shapeResult(data, nil, &Instance{ID: "x"})
	if err != nil || !res.Truncated || res.Series != maxSeries {
		t.Errorf("truncate: %+v %v", res, err)
	}
}

func TestDiscoveryIsCached(t *testing.T) {
	h, up := testHandler(t, false)
	serve(t, h, "GET", "/api/prom/status", "")
	n := len(up.seen)
	serve(t, h, "GET", "/api/prom/status", "")
	if len(up.seen) != n {
		t.Errorf("second status call probed again (%d → %d requests)", n, len(up.seen))
	}
	serve(t, h, "GET", "/api/prom/status?refresh=true", "")
	if len(up.seen) == n {
		t.Error("refresh=true should re-probe")
	}
}

func TestManualInstanceWithPathPrefix(t *testing.T) {
	h, up := testHandler(t, false)
	// Mimir-style: no buildinfo, the API lives under /prometheus.
	up.json("mimir-qf:8080/prometheus/api/v1/query", `{"status":"success","data":{"resultType":"vector","result":[]}}`)
	e := h.env()
	e.settings = Settings{Prometheus: &Endpoint{Namespace: "mimir", Service: "mimir-qf", Port: "8080", PathPrefix: "prometheus/"}}
	h.env = func() env { return e }
	s := decode[Status](t, serve(t, h, "GET", "/api/prom/status", ""))
	if len(s.Prometheus) != 2 || s.Prometheus[0].ID != "mimir/mimir-qf" || !s.Prometheus[0].Default || !s.Prometheus[0].Reachable || s.Prometheus[1].Default {
		t.Fatalf("instances = %+v", s.Prometheus)
	}
	if rec := serve(t, h, "GET", "/api/prom/query?query=up", ""); rec.Code != 200 {
		t.Fatalf("query: %d %s", rec.Code, rec.Body)
	}
	if !slices.ContainsFunc(up.seen, func(r string) bool {
		return strings.HasPrefix(r, "GET mimir/mimir-qf:8080/prometheus/api/v1/query?query=up")
	}) {
		t.Errorf("query not sent under the prefix: %v", up.seen)
	}
}
