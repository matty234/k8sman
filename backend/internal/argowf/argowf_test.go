package argowf

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"

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
