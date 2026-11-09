package server

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	utilexec "k8s.io/client-go/util/exec"
)

func TestExecCommand(t *testing.T) {
	q := func(s string) url.Values { v, _ := url.ParseQuery(s); return v }

	cmd, auto, err := execCommand(q(""))
	if err != nil || !auto || len(cmd) != 3 || cmd[0] != "/bin/sh" || cmd[1] != "-c" {
		t.Fatalf("default: %v %v %v", cmd, auto, err)
	}
	cmd, auto, _ = execCommand(q("shell=bash"))
	if !auto || !strings.Contains(cmd[2], "for s in bash ") {
		t.Fatalf("shell=bash: %v", cmd)
	}
	if _, _, err := execCommand(q("shell=" + url.QueryEscape("bash; rm -rf /"))); err == nil {
		t.Fatal("expected shell injection to be rejected")
	}
	cmd, auto, _ = execCommand(q("command=python3&command=-q"))
	if auto || strings.Join(cmd, " ") != "python3 -q" {
		t.Fatalf("repeated: %v %v", cmd, auto)
	}
	cmd, auto, _ = execCommand(q("command=" + url.QueryEscape(`["/bin/bash","-l"]`)))
	if auto || strings.Join(cmd, " ") != "/bin/bash -l" {
		t.Fatalf("json: %v %v", cmd, auto)
	}
	if _, _, err := execCommand(q("command=" + url.QueryEscape(`["oops`))); err == nil {
		t.Fatal("expected bad JSON to fail")
	}
	cmd, _, _ = execCommand(q("command=/bin/bash"))
	if len(cmd) != 1 || cmd[0] != "/bin/bash" {
		t.Fatalf("single: %v", cmd)
	}
}

func TestClassifyExecError(t *testing.T) {
	exit := func(c int) error { return utilexec.CodeExitError{Err: errors.New("x"), Code: c} }
	ociMissing := errors.New(`OCI runtime exec failed: exec failed: unable to start container process: exec: "/bin/sh": stat /bin/sh: no such file or directory: unknown`)
	cases := []struct {
		name       string
		err        error
		auto, out  bool
		wantCode   int
		wantReason string
	}{
		{"clean exit", nil, true, true, 0, ""},
		{"exit 3", exit(3), true, true, 3, ""},
		{"127 after output is a normal exit", exit(127), true, true, 127, ""},
		{"127 before output, auto", exit(127), true, false, 127, reasonNoShell},
		{"126 before output, explicit", exit(126), false, false, 126, reasonCommandNotFound},
		{"distroless", ociMissing, true, false, -1, reasonNoShell},
		{"explicit missing binary", errors.New(`exec: "python": executable file not found in $PATH`), false, false, -1, reasonCommandNotFound},
		{"forbidden", apierrors.NewForbidden(schema.GroupResource{Resource: "pods"}, "p", errors.New("no")), true, false, -1, reasonForbidden},
		{"container gone", errors.New(`container not found ("web")`), true, false, -1, reasonContainerNotFound},
		{"other", errors.New("connection reset"), true, false, -1, reasonExecFailed},
	}
	for _, c := range cases {
		code, reason := classifyExecError(c.err, c.auto, c.out)
		if code != c.wantCode || reason != c.wantReason {
			t.Errorf("%s: got (%d,%q) want (%d,%q)", c.name, code, reason, c.wantCode, c.wantReason)
		}
	}
}

func TestResolveContainer(t *testing.T) {
	running := corev1.ContainerState{Running: &corev1.ContainerStateRunning{}}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "p"},
		Spec: corev1.PodSpec{
			Containers:          []corev1.Container{{Name: "app"}, {Name: "side"}},
			EphemeralContainers: []corev1.EphemeralContainer{{EphemeralContainerCommon: corev1.EphemeralContainerCommon{Name: "debugger"}}},
		},
		Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{
				{Name: "app", State: running},
				{Name: "side", State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff"}}},
			},
			EphemeralContainerStatuses: []corev1.ContainerStatus{{Name: "debugger", State: running}},
		},
	}
	if c, reason, err := resolveContainer(pod, ""); c != "app" || err != nil || reason != "" {
		t.Errorf("default: %s %s %v", c, reason, err)
	}
	if _, reason, _ := resolveContainer(pod, "side"); reason != reasonContainerNotRunning {
		t.Errorf("side: %s", reason)
	}
	if _, reason, _ := resolveContainer(pod, "nope"); reason != reasonContainerNotFound {
		t.Errorf("nope: %s", reason)
	}
	if _, _, err := resolveContainer(pod, "debugger"); err != nil {
		t.Errorf("ephemeral: %v", err)
	}
	pod.Annotations = map[string]string{"kubectl.kubernetes.io/default-container": "side"}
	if c, _, _ := resolveContainer(pod, ""); c != "side" {
		t.Errorf("annotation default: %s", c)
	}
}

func TestReadOnlyRefusesExecAndDebug(t *testing.T) {
	s := &Server{readOnly: true, mux: http.NewServeMux()}
	s.execRoutes()
	for _, r := range []*http.Request{
		httptest.NewRequest("GET", "/api/exec?namespace=demo&pod=p", nil),
		httptest.NewRequest("POST", "/api/debug-container", strings.NewReader(`{"namespace":"demo","pod":"p"}`)),
	} {
		w := httptest.NewRecorder()
		s.mux.ServeHTTP(w, r)
		if w.Code != http.StatusForbidden {
			t.Errorf("%s %s: got %d, want 403", r.Method, r.URL.Path, w.Code)
		}
	}
}
