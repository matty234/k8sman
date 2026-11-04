package argowf

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/client-go/rest"
)

func mustJSON(t *testing.T, s string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func get(m map[string]any, path ...string) any {
	var cur any = m
	for _, p := range path {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[p]
	}
	return cur
}

const runningWF = `{
  "apiVersion": "argoproj.io/v1alpha1", "kind": "Workflow",
  "metadata": {"name": "approval-abcde", "generateName": "approval-", "namespace": "demo", "resourceVersion": "42",
    "labels": {"team": "a", "workflows.argoproj.io/phase": "Running", "workflows.argoproj.io/creator": "someone"},
    "annotations": {"note": "x", "kubectl.kubernetes.io/last-applied-configuration": "{}"},
    "ownerReferences": [{"kind": "CronWorkflow", "name": "c", "uid": "u"}]},
  "spec": {"entrypoint": "main", "suspend": true, "shutdown": "Stop", "activeDeadlineSeconds": 0,
    "arguments": {"parameters": [{"name": "p", "value": "1"}]}},
  "status": {"phase": "Running", "nodes": {
    "approval-abcde": {"id": "approval-abcde", "type": "Steps", "phase": "Running"},
    "approval-abcde-1": {"id": "approval-abcde-1", "displayName": "approve", "type": "Suspend", "phase": "Running",
      "outputs": {"parameters": [
        {"name": "choice", "valueFrom": {"supplied": {}, "default": "yes"}},
        {"name": "fixed", "value": "v"}]}},
    "approval-abcde-2": {"id": "approval-abcde-2", "type": "Suspend", "phase": "Succeeded"}
  }}
}`

func TestShutdownAndSuspendPatches(t *testing.T) {
	wf := mustJSON(t, runningWF)
	p, err := ShutdownPatch(wf, "Terminate")
	if err != nil || get(p, "spec", "shutdown") != "Terminate" {
		t.Fatalf("ShutdownPatch = %v, %v", p, err)
	}
	if _, err := ShutdownPatch(wf, "Pause"); err == nil {
		t.Error("unknown strategy accepted")
	}
	if p, err := SuspendPatch(wf); err != nil || get(p, "spec", "suspend") != true {
		t.Fatalf("SuspendPatch = %v, %v", p, err)
	}
	done := mustJSON(t, `{"status": {"phase": "Succeeded"}}`)
	if _, err := ShutdownPatch(done, "Stop"); err == nil {
		t.Error("stopping a completed workflow was allowed")
	}
	if _, err := SuspendPatch(done); err == nil {
		t.Error("suspending a completed workflow was allowed")
	}
}

func TestResumePatch(t *testing.T) {
	now := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	wf := mustJSON(t, runningWF)
	if !Suspended(wf) {
		t.Fatal("Suspended = false")
	}
	p, err := ResumePatch(wf, now)
	if err != nil {
		t.Fatal(err)
	}
	spec := p["spec"].(map[string]any)
	if v, ok := spec["suspend"]; !ok || v != nil {
		t.Errorf("spec.suspend not cleared: %v", spec)
	}
	if get(p, "metadata", "resourceVersion") != "42" {
		t.Error("missing resourceVersion precondition")
	}
	nodes := get(p, "status", "nodes").(map[string]any)
	if len(nodes) != 1 {
		t.Fatalf("patched nodes = %v, want only the running suspend node", nodes)
	}
	n := nodes["approval-abcde-1"].(map[string]any)
	if n["phase"] != "Succeeded" || n["finishedAt"] != "2026-01-02T03:04:05Z" {
		t.Errorf("node patch = %v", n)
	}
	params := get(n, "outputs", "parameters").([]any)
	if params[0].(map[string]any)["value"] != "yes" || params[1].(map[string]any)["value"] != "v" {
		t.Errorf("supplied output not defaulted: %v", params)
	}
	// The input must not be modified.
	if get(wf, "status", "nodes", "approval-abcde-1", "phase") != "Running" {
		t.Error("ResumePatch mutated its input")
	}

	// Nothing to resume.
	idle := mustJSON(t, `{"spec": {}, "status": {"phase": "Running", "nodes": {}}}`)
	if p, err := ResumePatch(idle, now); err != nil || p != nil {
		t.Errorf("idle ResumePatch = %v, %v", p, err)
	}
	// A supplied output without a default can't be resumed blindly.
	noDef := mustJSON(t, `{"status": {"nodes": {"n": {"type": "Suspend", "phase": "Running",
		"outputs": {"parameters": [{"name": "x", "valueFrom": {"supplied": {}}}]}}}}}`)
	if _, err := ResumePatch(noDef, now); err == nil {
		t.Error("expected an error for a supplied output without default")
	}
	off := mustJSON(t, `{"status": {"offloadNodeStatusVersion": "abc"}}`)
	if _, err := ResumePatch(off, now); err == nil {
		t.Error("expected an error for offloaded node status")
	}
}

func TestResubmit(t *testing.T) {
	out := Resubmit(mustJSON(t, runningWF))
	if get(out, "metadata", "generateName") != "approval-" || get(out, "metadata", "name") != nil {
		t.Errorf("metadata = %v", out["metadata"])
	}
	if get(out, "metadata", "namespace") != "demo" || get(out, "metadata", "ownerReferences") != nil || out["status"] != nil {
		t.Errorf("namespace/owners/status wrong: %v", out)
	}
	labels := get(out, "metadata", "labels").(map[string]any)
	if labels["team"] != "a" || labels[LabelResubmittedFrom] != "approval-abcde" || labels[LabelPhase] != nil || labels[LabelCreator] != nil {
		t.Errorf("labels = %v", labels)
	}
	ann := get(out, "metadata", "annotations").(map[string]any)
	if ann["note"] != "x" || ann["kubectl.kubernetes.io/last-applied-configuration"] != nil {
		t.Errorf("annotations = %v", ann)
	}
	spec := out["spec"].(map[string]any)
	if spec["shutdown"] != nil || spec["activeDeadlineSeconds"] != nil || get(spec, "arguments", "parameters") == nil {
		t.Errorf("spec = %v", spec)
	}
	// No generateName: name + "-".
	plain := Resubmit(mustJSON(t, `{"metadata": {"name": "solo"}, "spec": {"activeDeadlineSeconds": 60}}`))
	if get(plain, "metadata", "generateName") != "solo-" || get(plain, "spec", "activeDeadlineSeconds") == nil {
		t.Errorf("plain resubmit = %v", plain)
	}
}

func TestFromCronWorkflow(t *testing.T) {
	cron := mustJSON(t, `{"apiVersion": "argoproj.io/v1alpha1", "kind": "CronWorkflow",
	  "metadata": {"name": "nightly", "namespace": "demo", "uid": "cron-uid", "labels": {"workflows.argoproj.io/controller-instanceid": "i1", "other": "no"}},
	  "spec": {"schedules": ["0 * * * *"], "workflowMetadata": {"labels": {"team": "a"}, "annotations": {"a": "b"}},
	    "workflowSpec": {"entrypoint": "main", "templates": [{"name": "main", "container": {"image": "busybox"}}]}}}`)
	now := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	wf := FromCronWorkflow(cron, now)
	if get(wf, "metadata", "generateName") != "nightly-" || get(wf, "metadata", "namespace") != "demo" || wf["kind"] != "Workflow" {
		t.Errorf("metadata = %v", wf["metadata"])
	}
	labels := get(wf, "metadata", "labels").(map[string]any)
	if labels[LabelCronWorkflow] != "nightly" || labels["team"] != "a" || labels[LabelControllerInstanceID] != "i1" || labels["other"] != nil {
		t.Errorf("labels = %v", labels)
	}
	ann := get(wf, "metadata", "annotations").(map[string]any)
	if ann[AnnotationScheduledTime] != "2026-01-02T03:04:05Z" || ann["a"] != "b" {
		t.Errorf("annotations = %v", ann)
	}
	owner := get(wf, "metadata", "ownerReferences").([]any)[0].(map[string]any)
	if owner["kind"] != "CronWorkflow" || owner["uid"] != "cron-uid" || owner["controller"] != true {
		t.Errorf("owner = %v", owner)
	}
	if get(wf, "spec", "entrypoint") != "main" {
		t.Errorf("spec = %v", wf["spec"])
	}
}

func TestFromTemplateAndValidate(t *testing.T) {
	tmpl := mustJSON(t, `{"apiVersion": "argoproj.io/v1alpha1", "kind": "WorkflowTemplate",
	  "metadata": {"name": "build", "namespace": "demo"},
	  "spec": {"arguments": {"parameters": [{"name": "target", "value": "staging", "enum": ["staging", "production"]}, {"name": "msg"}]}}}`)
	params := []Param{{Name: "target", Value: "production"}, {Name: "msg", Value: "hi"}}
	if err := ValidateParams(tmpl, params); err != nil {
		t.Fatal(err)
	}
	if err := ValidateParams(tmpl, []Param{{Name: "target", Value: "qa"}}); err == nil || !strings.Contains(err.Error(), "one of") {
		t.Errorf("enum not enforced: %v", err)
	}
	if err := ValidateParams(tmpl, []Param{{Name: "nope", Value: "1"}}); err == nil {
		t.Error("unknown parameter accepted")
	}
	wf := FromTemplate(tmpl, false, "demo", params, "")
	if get(wf, "spec", "workflowTemplateRef", "name") != "build" || get(wf, "spec", "workflowTemplateRef", "clusterScope") != nil {
		t.Errorf("ref = %v", get(wf, "spec", "workflowTemplateRef"))
	}
	if get(wf, "metadata", "labels", LabelWorkflowTemplate) != "build" || get(wf, "spec", "entrypoint") != nil {
		t.Errorf("wf = %v", wf)
	}
	ps := get(wf, "spec", "arguments", "parameters").([]any)
	if len(ps) != 2 || ps[0].(map[string]any)["value"] != "production" {
		t.Errorf("parameters = %v", ps)
	}
	cwf := FromTemplate(tmpl, true, "other", nil, "alt")
	if get(cwf, "spec", "workflowTemplateRef", "clusterScope") != true || get(cwf, "metadata", "labels", LabelClusterWorkflowTemplate) != "build" ||
		get(cwf, "metadata", "namespace") != "other" || get(cwf, "spec", "entrypoint") != "alt" || get(cwf, "spec", "arguments") != nil {
		t.Errorf("cluster wf = %v", cwf)
	}
}

// fakeReq answers argo-server paths per token.
type fakeReq struct {
	version string
	// userinfo: token → subject; a missing token is a 401.
	users map[string]string
	calls []string
}

func (f *fakeReq) do(_ context.Context, method string, s *Server, p string, body []byte, token string) ([]byte, int, error) {
	f.calls = append(f.calls, method+" "+s.Scheme+" "+p+" "+token)
	if s.Scheme != "https" {
		return nil, 503, errors.New("no")
	}
	switch {
	case p == "/api/v1/version":
		if _, ok := f.users[token]; !ok && f.users[""] == "" {
			// Client/SSO mode: argo-server refuses even this without a token.
			return []byte(`{"code":16,"message":"token not valid"}`), 401, statusErr(401, "unauthorized")
		}
		return []byte(`{"version":"` + f.version + `"}`), 200, nil
	case p == "/api/v1/userinfo":
		if sub, ok := f.users[token]; ok {
			return []byte(`{"subject":"` + sub + `"}`), 200, nil
		}
		return nil, 401, statusErr(401, "argo-server: token not valid")
	case strings.HasSuffix(p, "/retry"):
		if _, ok := f.users[token]; !ok {
			return nil, 401, statusErr(401, "unauthorized")
		}
		return []byte(`{"metadata":{"name":"wf"}}`), 200, nil
	}
	return nil, 404, statusErr(404, "not found")
}

func argoService() *corev1.Service {
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: "argo-server", Namespace: "argo"},
		Spec:       corev1.ServiceSpec{Ports: []corev1.ServicePort{{Name: "web", Port: 2746}}},
	}
}

func TestDiscoverAuthModes(t *testing.T) {
	cases := []struct {
		name      string
		users     map[string]string
		token     string
		wantAuth  string
		available bool
	}{
		{"server mode", map[string]string{"": "system:serviceaccount:argo:argo-server"}, "", AuthServer, true},
		{"client mode", map[string]string{"tok": "alice"}, "tok", AuthClient, true},
		{"client mode, no token", map[string]string{"tok": "alice"}, "", AuthNone, false},
		{"sso only", map[string]string{}, "tok", AuthNone, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fr := &fakeReq{version: "v4.0.1", users: c.users}
			e := env{context: "kind", typed: fake.NewClientset(argoService()), req: fr, token: func() (string, error) { return c.token, nil }}
			h := &Handler{env: func() env { return e }, disc: newDiscoverer()}
			d := h.disc.get(context.Background(), e, false)
			st := d.status
			wantVersion := "v4.0.1"
			if !c.available {
				wantVersion = "" // never authorised to ask
			}
			if !st.Found || !st.Reachable || st.Server == nil || st.Server.Version != wantVersion || st.Server.Port != 2746 || st.Server.Scheme != "https" {
				t.Fatalf("status = %+v", st)
			}
			if st.Auth != c.wantAuth || st.Available != c.available {
				t.Fatalf("auth = %q available = %v (%s)", st.Auth, st.Available, st.Error)
			}
			err := h.retry(context.Background(), e, "demo", "wf", false)
			if c.available != (err == nil) {
				t.Fatalf("retry err = %v", err)
			}
			if c.available {
				last := fr.calls[len(fr.calls)-1]
				if last != "PUT https /api/v1/workflows/demo/wf/retry "+c.token {
					t.Errorf("retry call = %q", last)
				}
			}
		})
	}
}

func TestDiscoverNotFound(t *testing.T) {
	e := env{context: "kind", typed: fake.NewClientset(), req: &fakeReq{}, token: func() (string, error) { return "", nil }}
	st := discover(context.Background(), e).status
	if st.Found || st.Available || st.Error == "" {
		t.Errorf("status = %+v", st)
	}
}

func TestBearerToken(t *testing.T) {
	if tok, err := BearerToken(&rest.Config{Host: "https://k", BearerToken: "abc"}); err != nil || tok != "abc" {
		t.Errorf("static token = %q, %v", tok, err)
	}
	// Client certificates carry no token.
	if tok, err := BearerToken(&rest.Config{Host: "https://k"}); err != nil || tok != "" {
		t.Errorf("no-token config = %q, %v", tok, err)
	}
	// Wrapped transports (exec plugins, auth providers) set the header;
	// emulate one with WrapTransport.
	cfg := &rest.Config{Host: "https://k", WrapTransport: func(rt http.RoundTripper) http.RoundTripper {
		return roundTripFunc(func(r *http.Request) (*http.Response, error) {
			r = r.Clone(r.Context())
			r.Header.Set("Authorization", "Bearer from-plugin")
			return rt.RoundTrip(r)
		})
	}}
	if tok, err := BearerToken(cfg); err != nil || tok != "from-plugin" {
		t.Errorf("wrapped token = %q, %v", tok, err)
	}
}
