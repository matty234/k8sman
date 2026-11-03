package argoapi

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes"
	kfake "k8s.io/client-go/kubernetes/fake"
	"k8s.io/client-go/rest"

	"github.com/bargrove/k8sman/backend/internal/settings"
)

const (
	goodToken    = "good-token"
	sessionToken = "session-token"
	adminPass    = "s3cret-pass"
)

// fakeArgo emulates the API server's service proxy in front of
// argocd-server. It checks the argocd.token cookie like Argo does.
type fakeArgo struct {
	mu        sync.Mutex
	seen      []string
	cookies   []string
	auths     []string
	sessions  int
	resources string // managed-resources body
	insecure  bool   // serve only on http
	forbidden bool   // Argo RBAC denies the app
}

func (f *fakeArgo) serve(w http.ResponseWriter, r *http.Request) {
	// /api/v1/namespaces/<ns>/services/<scheme>:<svc>:<port>/proxy/<path>
	parts := strings.SplitN(strings.TrimPrefix(r.URL.Path, "/api/v1/namespaces/"), "/", 4)
	if len(parts) < 4 || parts[1] != "services" {
		http.NotFound(w, r)
		return
	}
	sp := strings.SplitN(parts[2], ":", 3)
	full := strings.TrimPrefix(parts[3], "proxy")
	p := strings.TrimPrefix(full, "/argo")
	f.mu.Lock()
	f.seen = append(f.seen, r.Method+" "+parts[0]+"/"+parts[2]+full+"?"+r.URL.RawQuery)
	f.cookies = append(f.cookies, r.Header.Get("Cookie"))
	f.auths = append(f.auths, r.Header.Get("Authorization"))
	f.mu.Unlock()
	if f.insecure != (sp[0] == "http") {
		// The real thing: https on an insecure server fails, http on a TLS
		// one redirects in a loop. The API server reports a Status.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(503)
		_, _ = io.WriteString(w, `{"kind":"Status","apiVersion":"v1","status":"Failure","message":"error trying to reach service","reason":"ServiceUnavailable","code":503}`)
		return
	}
	tok := ""
	if c, err := r.Cookie(tokenCookie); err == nil {
		tok = c.Value
	}
	authed := tok == goodToken || tok == sessionToken
	argoErr := func(code int, msg string) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": msg, "message": msg, "code": 16})
	}
	switch {
	case p == "/api/version":
		_, _ = io.WriteString(w, `{"Version":"v3.5.7"}`)
	case p == "/api/v1/session/userinfo":
		if authed {
			_, _ = io.WriteString(w, `{"loggedIn":true,"username":"admin","iss":"argocd"}`)
		} else {
			_, _ = io.WriteString(w, `{}`)
		}
	case p == "/api/v1/session" && r.Method == "POST":
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["username"] != "admin" || body["password"] != adminPass {
			argoErr(401, "Invalid username or password")
			return
		}
		f.mu.Lock()
		f.sessions++
		f.mu.Unlock()
		_, _ = io.WriteString(w, `{"token":"`+sessionToken+`"}`)
	case strings.HasSuffix(p, "/managed-resources"):
		if !authed {
			argoErr(401, "no session information")
			return
		}
		if f.forbidden {
			argoErr(403, "permission denied")
			return
		}
		_, _ = io.WriteString(w, f.resources)
	default:
		http.NotFound(w, r)
	}
}

func argoService(ns string) *corev1.Service {
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: "argocd-server", Labels: map[string]string{"app.kubernetes.io/name": "argocd-server"}},
		Spec: corev1.ServiceSpec{Ports: []corev1.ServicePort{
			{Name: "http", Port: 80},
			{Name: "https", Port: 443},
		}},
	}
}

func adminSecret(ns string) *corev1.Secret {
	return &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: initialAdminName}, Data: map[string][]byte{"password": []byte(adminPass)}}
}

type testRig struct {
	h     *Handler
	argo  *fakeArgo
	mux   *http.ServeMux
	store *settings.Store
	path  string
}

func newRig(t *testing.T, argo *fakeArgo, objs ...runtime.Object) *testRig {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(argo.serve))
	t.Cleanup(srv.Close)
	cs, err := kubernetes.NewForConfig(&rest.Config{Host: srv.URL, BearerToken: "kube-token"})
	if err != nil {
		t.Fatal(err)
	}
	path := t.TempDir() + "/settings.json"
	st, _ := settings.Open(path)
	typed := kfake.NewSimpleClientset(objs...)
	h := &Handler{
		env: func() env {
			return env{context: "kind-dev", typed: typed, req: restRequester{rc: cs.CoreV1().RESTClient()}}
		},
		disc:     newDiscoverer(),
		tokens:   st,
		sessions: map[string]string{},
	}
	mux := http.NewServeMux()
	h.register(mux)
	return &testRig{h: h, argo: argo, mux: mux, store: st, path: path}
}

func (r *testRig) call(t *testing.T, method, target string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = strings.NewReader(string(b))
	}
	w := httptest.NewRecorder()
	r.mux.ServeHTTP(w, httptest.NewRequest(method, target, rd))
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

// A modified Deployment (with a prediction), one to be created, one to be
// pruned, and a synced Service.
var sampleResources = func() string {
	dep := func(replicas int, extra string) string {
		return `{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"web","namespace":"demo",` + extra +
			`"annotations":{"argocd.argoproj.io/tracking-id":"app:apps/Deployment:demo/web"}},"spec":{"replicas":` + string(rune('0'+replicas)) + `}}`
	}
	liveExtra := `"uid":"u1","resourceVersion":"42","generation":3,"creationTimestamp":"2026-11-03T00:00:00Z","managedFields":[{"manager":"kubectl"}],`
	liveDep := strings.Replace(dep(3, liveExtra), `"annotations":{`, `"annotations":{"kubectl.kubernetes.io/last-applied-configuration":"{}","deployment.kubernetes.io/revision":"1",`, 1)
	liveDep = strings.TrimSuffix(liveDep, "}") + `,"status":{"replicas":3}}`
	cm := `{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"old","namespace":"demo","uid":"u2","resourceVersion":"7"},"data":{"A":"1"}}`
	svc := `{"apiVersion":"v1","kind":"Service","metadata":{"name":"web","namespace":"demo"},"spec":{"type":"ClusterIP"}}`
	items := []map[string]any{
		{"kind": "Service", "namespace": "demo", "name": "web", "targetState": svc, "liveState": svc, "normalizedLiveState": svc, "predictedLiveState": svc},
		{"group": "apps", "kind": "Deployment", "namespace": "demo", "name": "web", "targetState": dep(2, ""), "liveState": liveDep,
			"normalizedLiveState": liveDep, "predictedLiveState": strings.Replace(liveDep, `"replicas":3}`, `"replicas":2}`, 1), "modified": true},
		{"kind": "ConfigMap", "namespace": "demo", "name": "old", "targetState": "null", "liveState": cm, "normalizedLiveState": cm, "predictedLiveState": "null"}, // Argo leaves modified unset for prunes
		{"kind": "Secret", "namespace": "demo", "name": "new", "targetState": `{"apiVersion":"v1","kind":"Secret","metadata":{"name":"new","namespace":"demo"},"data":{"k":"++++++++"}}`,
			"liveState": "null", "normalizedLiveState": "null", "predictedLiveState": `{"apiVersion":"v1","kind":"Secret","metadata":{"name":"new","namespace":"demo"},"data":{"k":"++++++++"}}`, "modified": true},
		{"group": "batch", "kind": "Job", "namespace": "demo", "name": "migrate", "targetState": `{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"migrate"}}`, "liveState": "null", "hook": true},
	}
	b, _ := json.Marshal(map[string]any{"items": items})
	return string(b)
}()

func TestConvert(t *testing.T) {
	var mr struct {
		Items []managedResource `json:"items"`
	}
	if err := json.Unmarshal([]byte(sampleResources), &mr); err != nil {
		t.Fatal(err)
	}
	out := convert(mr.Items)
	by := map[string]ResourceDiff{}
	for _, r := range out {
		by[r.Kind+"/"+r.Name] = r
	}
	// Out of sync first.
	if out[0].Status != "OutOfSync" || out[len(out)-1].Status != "Synced" {
		t.Fatalf("order: %+v", out)
	}
	dep := by["Deployment/web"]
	if dep.Status != "OutOfSync" || dep.Target == nil || dep.Live == nil || dep.RequiresPruning {
		t.Fatalf("deployment: %+v", dep)
	}
	// normalizedLive vs predictedLive: only replicas differs, noise is gone.
	for _, noise := range []string{"managedFields", "resourceVersion", "uid:", "generation", "creationTimestamp", "last-applied", "deployment.kubernetes.io/revision", "status:"} {
		if strings.Contains(*dep.Live, noise) || strings.Contains(*dep.Target, noise) {
			t.Errorf("%q left in:\n%s", noise, *dep.Live)
		}
	}
	if !strings.Contains(*dep.Live, "replicas: 3") || !strings.Contains(*dep.Target, "replicas: 2") {
		t.Errorf("replicas: live\n%s\ntarget\n%s", *dep.Live, *dep.Target)
	}
	if strings.Replace(*dep.Live, "replicas: 3", "replicas: 2", 1) != *dep.Target {
		t.Errorf("expected only replicas to differ:\n%s\n---\n%s", *dep.Live, *dep.Target)
	}
	if !strings.Contains(*dep.Target, "argocd.argoproj.io/tracking-id") {
		t.Error("kept annotations should stay")
	}
	cm := by["ConfigMap/old"]
	if cm.Target != nil || cm.Live == nil || !cm.RequiresPruning || cm.Status != "OutOfSync" {
		t.Errorf("to be pruned: %+v", cm)
	}
	sec := by["Secret/new"]
	if sec.Live != nil || sec.Target == nil || sec.RequiresPruning || !strings.Contains(*sec.Target, "++++++++") {
		t.Errorf("to be created: %+v", sec)
	}
	job := by["Job/migrate"]
	if !job.Hook || job.RequiresPruning || job.Status != "Synced" {
		t.Errorf("hook: %+v", job)
	}
	if svc := by["Service/web"]; *svc.Live != *svc.Target {
		t.Error("synced service should have equal sides")
	}
}

func TestConvertComparisonFailed(t *testing.T) {
	// The repo-server failed: every target is null, so nothing is prunable.
	live := `{"apiVersion":"v1","kind":"Service","metadata":{"name":"web"}}`
	out := convert([]managedResource{{Kind: "Service", Name: "web", TargetState: "null", LiveState: live, NormalizedLiveState: live, PredictedLiveState: "null"}})
	if out[0].RequiresPruning || out[0].Status != "Synced" {
		t.Fatalf("%+v", out[0])
	}
}

func TestConvertCapturedFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/managed-resources-helm-guestbook.json")
	if err != nil {
		t.Skip("no captured fixture")
	}
	var mr struct {
		Items []managedResource `json:"items"`
	}
	if err := json.Unmarshal(b, &mr); err != nil {
		t.Fatal(err)
	}
	out := convert(mr.Items)
	var dep, cm *ResourceDiff
	for i := range out {
		switch out[i].Kind {
		case "Deployment":
			dep = &out[i]
		case "ConfigMap":
			cm = &out[i]
		}
	}
	if dep == nil || dep.Status != "OutOfSync" || !strings.Contains(*dep.Live, "replicas: 3") || !strings.Contains(*dep.Target, "replicas: 2") {
		t.Fatalf("deployment: %+v", dep)
	}
	if strings.Contains(*dep.Live, "managedFields") || strings.Contains(*dep.Live, "last-applied") {
		t.Error("noise not stripped")
	}
	if cm == nil || !cm.RequiresPruning || cm.Target != nil {
		t.Fatalf("configmap: %+v", cm)
	}
}

func TestStatusAndDiffWithConfiguredToken(t *testing.T) {
	argo := &fakeArgo{resources: sampleResources}
	rig := newRig(t, argo, argoService("argocd"))

	code, st := rig.call(t, "GET", "/api/argocd/status?namespace=argocd", nil)
	if code != 200 || st["found"] != true || st["reachable"] != true || st["auth"] != AuthNone || st["initialAdminAvailable"] != false {
		t.Fatalf("status %d %v", code, st)
	}
	if srv := st["server"].(map[string]any); srv["scheme"] != "https" || srv["port"] != float64(443) || srv["version"] != "v3.5.7" {
		t.Fatalf("server %v", srv)
	}

	// No token yet.
	code, body := rig.call(t, "GET", "/api/argocd/diff?namespace=argocd&name=guestbook", nil)
	if code != 401 || body["reason"] != ReasonNoToken {
		t.Fatalf("diff without token: %d %v", code, body)
	}

	// A rejected token isn't saved.
	code, body = rig.call(t, "POST", "/api/argocd/auth", map[string]string{"token": "nope"})
	if code != 401 || body["reason"] != ReasonUnauthorized || rig.store.ArgoCDToken("kind-dev") != "" {
		t.Fatalf("bad token: %d %v", code, body)
	}

	code, body = rig.call(t, "POST", "/api/argocd/auth", map[string]string{"token": "Bearer " + goodToken + "\n"})
	if code != 200 || body["auth"] != AuthConfigured || body["authValid"] != true || body["username"] != "admin" {
		t.Fatalf("set token: %d %v", code, body)
	}
	if rig.store.ArgoCDToken("kind-dev") != goodToken {
		t.Fatal("token not saved")
	}
	if fi, _ := os.Stat(rig.path); fi.Mode().Perm() != 0o600 {
		t.Errorf("settings mode %v", fi.Mode().Perm())
	}
	// The token never comes back in a response.
	_, raw := rig.call(t, "GET", "/api/argocd/status", nil)
	if b, _ := json.Marshal(raw); strings.Contains(string(b), goodToken) {
		t.Error("status leaks the token")
	}

	code, body = rig.call(t, "GET", "/api/argocd/diff?namespace=argocd&name=guestbook", nil)
	if code != 200 || body["auth"] != AuthConfigured {
		t.Fatalf("diff: %d %v", code, body)
	}
	if n := len(body["resources"].([]any)); n != 5 {
		t.Fatalf("resources: %d", n)
	}
	last := argo.seen[len(argo.seen)-1]
	if !strings.HasPrefix(last, "GET argocd/https:argocd-server:443/api/v1/applications/guestbook/managed-resources?appNamespace=argocd") {
		t.Fatalf("request: %s", last)
	}
	// Sent as Argo's cookie; the kube bearer stays the kube one.
	if c := argo.cookies[len(argo.cookies)-1]; c != "argocd.token="+goodToken {
		t.Fatalf("cookie %q", c)
	}
	if a := argo.auths[len(argo.auths)-1]; a != "Bearer kube-token" {
		t.Fatalf("authorization %q", a)
	}

	// Argo RBAC denies.
	argo.forbidden = true
	code, body = rig.call(t, "GET", "/api/argocd/diff?namespace=argocd&name=guestbook", nil)
	if code != 403 || body["reason"] != ReasonForbidden || !strings.Contains(body["error"].(string), "permission denied") {
		t.Fatalf("forbidden: %d %v", code, body)
	}
	argo.forbidden = false

	code, body = rig.call(t, "DELETE", "/api/argocd/auth", nil)
	if code != 200 || body["auth"] != AuthNone || rig.store.ArgoCDToken("kind-dev") != "" {
		t.Fatalf("clear: %d %v", code, body)
	}
}

func TestRevokedTokenGives401(t *testing.T) {
	argo := &fakeArgo{resources: sampleResources}
	rig := newRig(t, argo, argoService("argocd"))
	_ = rig.store.SetArgoCDToken("kind-dev", "tok-XYZZY")
	code, body := rig.call(t, "GET", "/api/argocd/diff?namespace=argocd&name=guestbook", nil)
	if code != 401 || body["reason"] != ReasonUnauthorized || strings.Contains(body["error"].(string), "XYZZY") {
		t.Fatalf("revoked: %d %v", code, body)
	}
	_, st := rig.call(t, "GET", "/api/argocd/status", nil)
	if st["authValid"] != false || st["auth"] != AuthConfigured {
		t.Fatalf("status: %v", st)
	}
}

func TestInitialAdminSession(t *testing.T) {
	argo := &fakeArgo{resources: sampleResources}
	rig := newRig(t, argo, argoService("argocd"), adminSecret("argocd"))
	_, st := rig.call(t, "GET", "/api/argocd/status?namespace=argocd", nil)
	if st["initialAdminAvailable"] != true {
		t.Fatalf("status %v", st)
	}
	code, body := rig.call(t, "POST", "/api/argocd/auth/initial-admin", map[string]string{"namespace": "argocd"})
	if code != 200 || body["auth"] != AuthSession || body["authValid"] != true {
		t.Fatalf("initial admin: %d %v", code, body)
	}
	if b, _ := json.Marshal(body); strings.Contains(string(b), adminPass) || strings.Contains(string(b), sessionToken) {
		t.Fatal("password or session leaked")
	}
	// Memory only: nothing on disk.
	if b, err := os.ReadFile(rig.path); err == nil && (strings.Contains(string(b), sessionToken) || strings.Contains(string(b), adminPass)) {
		t.Fatal("session or password written to settings")
	}
	code, _ = rig.call(t, "GET", "/api/argocd/diff?namespace=argocd&name=guestbook", nil)
	if code != 200 {
		t.Fatalf("diff: %d", code)
	}
	if c := argo.cookies[len(argo.cookies)-1]; c != "argocd.token="+sessionToken {
		t.Fatalf("cookie %q", c)
	}
}

func TestInitialAdminMissingOrWrong(t *testing.T) {
	rig := newRig(t, &fakeArgo{}, argoService("argocd"))
	code, body := rig.call(t, "POST", "/api/argocd/auth/initial-admin", nil)
	if code != 404 || body["reason"] != ReasonNoAdmin {
		t.Fatalf("missing: %d %v", code, body)
	}
	bad := adminSecret("argocd")
	bad.Data["password"] = []byte("pw-PLUGH")
	rig = newRig(t, &fakeArgo{}, argoService("argocd"), bad)
	code, body = rig.call(t, "POST", "/api/argocd/auth/initial-admin", nil)
	if code != 401 || body["reason"] != ReasonUnauthorized || strings.Contains(body["error"].(string), "PLUGH") {
		t.Fatalf("wrong password: %d %v", code, body)
	}
}

func TestDiscoveryInsecureAndRootPath(t *testing.T) {
	argo := &fakeArgo{insecure: true}
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Namespace: "gitops", Name: paramsConfigMap}, Data: map[string]string{"server.insecure": "true", "server.rootpath": "/argo/"}}
	rig := newRig(t, argo, argoService("gitops"), cm)
	_ = rig.store.SetArgoCDToken("kind-dev", goodToken)
	// The app lives in another namespace: found cluster-wide.
	_, st := rig.call(t, "GET", "/api/argocd/status?namespace=apps", nil)
	srv, _ := st["server"].(map[string]any)
	if st["reachable"] != true || srv["scheme"] != "http" || srv["port"] != float64(80) || srv["rootPath"] != "/argo" || srv["namespace"] != "gitops" {
		t.Fatalf("status %v", st)
	}
	if !strings.Contains(strings.Join(argo.seen, "\n"), "GET gitops/http:argocd-server:80/argo/api/version") {
		t.Fatalf("seen %v", argo.seen)
	}
}

func TestDiscoveryFallsBackToHTTPWithoutParams(t *testing.T) {
	// server.insecure but the ConfigMap is unreadable: https fails, http works.
	argo := &fakeArgo{insecure: true}
	rig := newRig(t, argo, argoService("argocd"))
	_, st := rig.call(t, "GET", "/api/argocd/status", nil)
	if st["reachable"] != true || st["server"].(map[string]any)["scheme"] != "http" {
		t.Fatalf("status %v", st)
	}
}

func TestNotFound(t *testing.T) {
	rig := newRig(t, &fakeArgo{})
	_, st := rig.call(t, "GET", "/api/argocd/status", nil)
	if st["found"] != false || st["reachable"] != false || !strings.Contains(st["error"].(string), "not found") {
		t.Fatalf("status %v", st)
	}
	code, body := rig.call(t, "GET", "/api/argocd/diff?name=x", nil)
	if code != 404 || body["reason"] != ReasonNotFound {
		t.Fatalf("diff %d %v", code, body)
	}
}

func TestUpstreamErrKubeVsArgo(t *testing.T) {
	e := upstreamErr(401, []byte(`{"kind":"Status","apiVersion":"v1","status":"Failure","message":"Unauthorized","reason":"Unauthorized","code":401}`), nil).(*Error)
	if !e.Kube || e.Reason == ReasonUnauthorized || isArgoAuthErr(e) {
		t.Fatalf("kube 401: %+v", e)
	}
	e = upstreamErr(401, []byte(`{"error":"no session information","code":16,"message":"no session information"}`), nil).(*Error)
	if e.Kube || e.Reason != ReasonUnauthorized || !isArgoAuthErr(e) {
		t.Fatalf("argo 401: %+v", e)
	}
}
