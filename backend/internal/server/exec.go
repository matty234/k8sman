package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/remotecommand"
	utilexec "k8s.io/client-go/util/exec"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
)

func (s *Server) execRoutes() {
	s.mux.HandleFunc("GET /api/exec", s.handleExec)
	s.mux.HandleFunc("POST /api/debug-container", s.handleDebugContainer)
}

// ---- shell selection --------------------------------------------------------

// autoShells is the preference order when no shell is chosen.
var autoShells = []string{"zsh", "bash", "ash", "sh"}

// shellName accepts bare names or absolute paths, nothing that needs quoting.
var shellName = regexp.MustCompile(`^[A-Za-z0-9_./+-]+$`)

// shellScript builds the /bin/sh -c script that picks the first available
// shell (preferred first) and execs it, so the whole choice happens in one
// exec without client round-trips. TERM becomes xterm-256color when unset,
// dumb or plain xterm.
func shellScript(preferred string) string {
	shells := make([]string, 0, len(autoShells)+1)
	if preferred != "" && preferred != "auto" {
		shells = append(shells, preferred)
	}
	for _, s := range autoShells {
		if s != preferred {
			shells = append(shells, s)
		}
	}
	// Runtimes set TERM=xterm for TTYs; the UI emulator does 256 colours.
	return `case "$TERM" in ""|dumb|xterm) export TERM=xterm-256color;; esac; ` +
		`for s in ` + strings.Join(shells, " ") + `; do ` +
		`if command -v "$s" >/dev/null 2>&1; then exec "$s"; fi; ` +
		`done; ` +
		`echo "k8sman: no shell found" >&2; exit 127`
}

// execCommand resolves the command to run from the query: an explicit
// `command` (repeated params, or one JSON-encoded array) wins; otherwise the
// auto shell script with the optional `shell` preference. auto reports
// whether the shell script is used (which enables no-shell detection).
func execCommand(q map[string][]string) (cmd []string, auto bool, err error) {
	raw := q["command"]
	if len(raw) == 1 && strings.HasPrefix(strings.TrimSpace(raw[0]), "[") {
		if err := json.Unmarshal([]byte(raw[0]), &cmd); err != nil {
			return nil, false, httpx.BadRequest("command: invalid JSON array: %v", err)
		}
	} else {
		for _, c := range raw {
			if c != "" {
				cmd = append(cmd, c)
			}
		}
	}
	if len(cmd) > 0 {
		if cmd[0] == "" {
			return nil, false, httpx.BadRequest("command: empty executable")
		}
		return cmd, false, nil
	}
	shell := ""
	if v := q["shell"]; len(v) > 0 {
		shell = strings.TrimSpace(v[0])
	}
	if shell != "" && shell != "auto" && !shellName.MatchString(shell) {
		return nil, false, httpx.BadRequest("shell: %q is not a plain shell name or path", shell)
	}
	return []string{"/bin/sh", "-c", shellScript(shell)}, true, nil
}

// ---- error classification ---------------------------------------------------

// Exec error reasons sent to the UI in {type:"error", reason}.
const (
	reasonNoShell             = "noShell"             // /bin/sh missing (distroless) or no shell found
	reasonCommandNotFound     = "commandNotFound"     // explicit command missing
	reasonPodNotFound         = "podNotFound"         //
	reasonContainerNotFound   = "containerNotFound"   //
	reasonContainerNotRunning = "containerNotRunning" //
	reasonForbidden           = "forbidden"           // RBAC or --read-only
	reasonExecFailed          = "execFailed"          // anything else
)

var notFoundPatterns = []string{
	"no such file or directory",
	"executable file not found",
	"not found in $path",
	"command not found",
}

// classifyExecError maps the result of an exec to (exit code, error reason).
// A nil err is exit 0. A CodeExitError is a normal exit unless it is 126/127
// before any output, which means the shell/command couldn't start.
func classifyExecError(err error, auto, sawOutput bool) (code int, reason string) {
	if err == nil {
		return 0, ""
	}
	var ce utilexec.CodeExitError
	if errors.As(err, &ce) {
		if !sawOutput && (ce.Code == 126 || ce.Code == 127) {
			if auto {
				return ce.Code, reasonNoShell
			}
			return ce.Code, reasonCommandNotFound
		}
		return ce.Code, ""
	}
	if apierrors.IsForbidden(err) {
		return -1, reasonForbidden
	}
	msg := strings.ToLower(err.Error())
	for _, p := range notFoundPatterns {
		if strings.Contains(msg, p) {
			if auto {
				return -1, reasonNoShell
			}
			return -1, reasonCommandNotFound
		}
	}
	if strings.Contains(msg, "container not found") || strings.Contains(msg, "is not valid for pod") {
		return -1, reasonContainerNotFound
	}
	return -1, reasonExecFailed
}

// ---- framing ----------------------------------------------------------------

// ExecControl is a text (JSON) frame on /api/exec. Binary frames carry raw
// terminal bytes in both directions.
type ExecControl struct {
	// resize (client→server), exit / error / started (server→client)
	Type    string `json:"type"`
	Cols    uint16 `json:"cols,omitempty"`
	Rows    uint16 `json:"rows,omitempty"`
	Code    *int   `json:"code,omitempty"`
	Reason  string `json:"reason,omitempty"`
	Message string `json:"message,omitempty"`
	// started: the resolved container and command.
	Container string   `json:"container,omitempty"`
	Command   []string `json:"command,omitempty"`
}

// sizeQueue feeds resize events to remotecommand. Only the latest pending
// size matters, so a full channel drops the older value.
type sizeQueue struct {
	ch  chan remotecommand.TerminalSize
	ctx context.Context
}

func newSizeQueue(ctx context.Context) *sizeQueue {
	return &sizeQueue{ch: make(chan remotecommand.TerminalSize, 1), ctx: ctx}
}

func (q *sizeQueue) push(cols, rows uint16) {
	if cols == 0 || rows == 0 {
		return
	}
	sz := remotecommand.TerminalSize{Width: cols, Height: rows}
	for {
		select {
		case q.ch <- sz:
			return
		default:
			select { // drop the stale pending size and retry
			case <-q.ch:
			default:
			}
		}
	}
}

func (q *sizeQueue) Next() *remotecommand.TerminalSize {
	select {
	case <-q.ctx.Done():
		return nil
	case sz := <-q.ch:
		return &sz
	}
}

// wsBinaryWriter sends each Write as one binary frame. Blocking writes give
// natural backpressure on the exec stream when the client is slow.
type wsBinaryWriter struct {
	ws   *wsConn
	seen atomic.Bool
}

func (w *wsBinaryWriter) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	w.seen.Store(true)
	w.ws.mu.Lock()
	defer w.ws.mu.Unlock()
	_ = w.ws.conn.SetWriteDeadline(time.Now().Add(30 * time.Second))
	if err := w.ws.conn.WriteMessage(websocket.BinaryMessage, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

// ---- handlers ---------------------------------------------------------------

// resolveContainer checks the pod and container exist and the container is
// running. An empty container picks the default (annotation, else first).
func resolveContainer(pod *corev1.Pod, container string) (string, string, error) {
	if container == "" {
		container = pod.Annotations["kubectl.kubernetes.io/default-container"]
	}
	if container == "" && len(pod.Spec.Containers) > 0 {
		container = pod.Spec.Containers[0].Name
	}
	statuses := append(append(append([]corev1.ContainerStatus{}, pod.Status.ContainerStatuses...),
		pod.Status.InitContainerStatuses...), pod.Status.EphemeralContainerStatuses...)
	known := false
	for _, c := range pod.Spec.Containers {
		known = known || c.Name == container
	}
	for _, c := range pod.Spec.InitContainers {
		known = known || c.Name == container
	}
	for _, c := range pod.Spec.EphemeralContainers {
		known = known || c.Name == container
	}
	if !known {
		return container, reasonContainerNotFound, fmt.Errorf("container %q not found in pod %s", container, pod.Name)
	}
	for _, st := range statuses {
		if st.Name != container {
			continue
		}
		if st.State.Running != nil {
			return container, "", nil
		}
		state := "not running"
		if w := st.State.Waiting; w != nil {
			state = "waiting: " + w.Reason
		} else if t := st.State.Terminated; t != nil {
			state = fmt.Sprintf("terminated: %s (exit %d)", t.Reason, t.ExitCode)
		}
		return container, reasonContainerNotRunning, fmt.Errorf("container %q is %s", container, state)
	}
	return container, reasonContainerNotRunning, fmt.Errorf("container %q has not started", container)
}

func newExecutor(c *cluster.Clients, ns, pod string, opts *corev1.PodExecOptions) (remotecommand.Executor, error) {
	req := c.Typed.CoreV1().RESTClient().Post().
		Resource("pods").Namespace(ns).Name(pod).SubResource("exec").
		VersionedParams(opts, scheme.ParameterCodec)
	u := req.URL()
	spdy, err := remotecommand.NewSPDYExecutor(c.RESTConfig, "POST", u)
	if err != nil {
		return nil, err
	}
	ws, err := remotecommand.NewWebSocketExecutor(c.RESTConfig, "GET", u.String())
	if err != nil {
		return nil, err
	}
	// Same policy as kubectl 1.30+: WebSockets, falling back to SPDY on
	// servers (or proxies) that can't upgrade.
	return remotecommand.NewFallbackExecutor(ws, spdy, func(err error) bool {
		return httpstream.IsUpgradeFailure(err) || httpstream.IsHTTPSProxyError(err)
	})
}

// handleExec runs an interactive TTY session in a container.
// Query: namespace, pod, container, command (repeatable or JSON array),
// shell (auto | zsh | bash | ...), cols, rows (initial size).
func (s *Server) handleExec(w http.ResponseWriter, r *http.Request) {
	if s.isReadOnly() {
		httpx.WriteError(w, http.StatusForbidden, "Forbidden", "exec is disabled in read-only mode")
		return
	}
	q := r.URL.Query()
	ns, podName := q.Get("namespace"), q.Get("pod")
	if ns == "" || podName == "" {
		writeErr(w, httpx.BadRequest("namespace and pod are required"))
		return
	}
	cmd, auto, err := execCommand(q)
	if err != nil {
		writeErr(w, err)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	ws := &wsConn{conn: conn}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	defer ws.close()

	fail := func(reason string, err error) {
		_ = ws.send(ExecControl{Type: "error", Reason: reason, Message: err.Error()})
	}

	c := s.mgr.Clients()
	pod, err := c.Typed.CoreV1().Pods(ns).Get(ctx, podName, metav1.GetOptions{})
	if err != nil {
		reason := reasonExecFailed
		if apierrors.IsNotFound(err) {
			reason = reasonPodNotFound
		} else if apierrors.IsForbidden(err) {
			reason = reasonForbidden
		}
		fail(reason, err)
		return
	}
	container, reason, err := resolveContainer(pod, q.Get("container"))
	if err != nil {
		fail(reason, err)
		return
	}

	sizes := newSizeQueue(ctx)
	if cols, err1 := strconv.Atoi(q.Get("cols")); err1 == nil {
		if rows, err2 := strconv.Atoi(q.Get("rows")); err2 == nil && cols > 0 && rows > 0 && cols < 1<<16 && rows < 1<<16 {
			sizes.push(uint16(cols), uint16(rows))
		}
	}

	// Client → exec: binary frames are stdin, text frames are control.
	stdinR, stdinW := io.Pipe()
	go func() {
		defer cancel()
		defer stdinW.Close()
		conn.SetReadLimit(1 << 20)
		for {
			mt, data, err := conn.ReadMessage()
			if err != nil {
				return
			}
			switch mt {
			case websocket.BinaryMessage:
				// Blocks until the exec stream consumes it (backpressure).
				if _, err := stdinW.Write(data); err != nil {
					return
				}
			case websocket.TextMessage:
				var m ExecControl
				if json.Unmarshal(data, &m) == nil && m.Type == "resize" {
					sizes.push(m.Cols, m.Rows)
				}
			}
		}
	}()
	go func() { // keepalive
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				ws.mu.Lock()
				_ = conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
				ws.mu.Unlock()
			}
		}
	}()

	exec, err := newExecutor(c, ns, podName, &corev1.PodExecOptions{
		Container: container,
		Command:   cmd,
		Stdin:     true,
		Stdout:    true,
		Stderr:    false, // merged into stdout by the TTY
		TTY:       true,
	})
	if err != nil {
		fail(reasonExecFailed, err)
		return
	}
	if ws.send(ExecControl{Type: "started", Container: container, Command: cmd}) != nil {
		return
	}
	out := &wsBinaryWriter{ws: ws}
	err = exec.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdin:             stdinR,
		Stdout:            out,
		Tty:               true,
		TerminalSizeQueue: sizes,
	})
	_ = stdinR.Close()
	if ctx.Err() != nil {
		return // client went away
	}
	code, reason := classifyExecError(err, auto, out.seen.Load())
	if reason != "" {
		msg := err.Error()
		if reason == reasonNoShell {
			msg = fmt.Sprintf("No shell found in container %q (the image may be distroless). %s", container, msg)
		}
		m := ExecControl{Type: "error", Reason: reason, Message: msg}
		if code >= 0 {
			m.Code = &code
		}
		_ = ws.send(m)
		return
	}
	_ = ws.send(ExecControl{Type: "exit", Code: &code})
}

// ---- debug containers ---------------------------------------------------------

// DebugContainerRequest is the body of POST /api/debug-container.
type DebugContainerRequest struct {
	Namespace       string `json:"namespace"`
	Pod             string `json:"pod"`
	TargetContainer string `json:"targetContainer"`
	Image           string `json:"image"`
}

const defaultDebugImage = "busybox:1.36"

var debugMu sync.Mutex // serialises ephemeral container updates per server

// handleDebugContainer adds an ephemeral container to a pod (like
// `kubectl debug -it pod --image=... --target=...`) and waits until it runs.
// The UI then execs into it. Ephemeral containers can't be removed.
func (s *Server) handleDebugContainer(w http.ResponseWriter, r *http.Request) {
	if s.isReadOnly() {
		httpx.WriteError(w, http.StatusForbidden, "Forbidden", "debug containers are disabled in read-only mode")
		return
	}
	req, ok := httpx.DecodeJSON[DebugContainerRequest](w, r, 0)
	if !ok {
		return
	}
	if req.Namespace == "" || req.Pod == "" {
		writeErr(w, httpx.BadRequest("namespace and pod are required"))
		return
	}
	if req.Image == "" {
		req.Image = defaultDebugImage
	}
	if strings.ContainsAny(req.Image, " \t\n") {
		writeErr(w, httpx.BadRequest("image %q is invalid", req.Image))
		return
	}
	c := s.mgr.Clients()
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer cancel()

	name, err := s.addDebugContainer(ctx, c, req)
	if err != nil {
		writeErr(w, err)
		return
	}
	if err := waitEphemeralRunning(ctx, c, req.Namespace, req.Pod, name); err != nil {
		httpx.WriteError(w, http.StatusGatewayTimeout, "DebugContainerNotRunning", err.Error())
		return
	}
	log.Printf("debug container %s added to %s/%s (image %s, target %q)", name, req.Namespace, req.Pod, req.Image, req.TargetContainer)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"name": name, "image": req.Image, "context": c.Context})
}

func (s *Server) addDebugContainer(ctx context.Context, c *cluster.Clients, req DebugContainerRequest) (string, error) {
	debugMu.Lock()
	defer debugMu.Unlock()
	pods := c.Typed.CoreV1().Pods(req.Namespace)
	pod, err := pods.Get(ctx, req.Pod, metav1.GetOptions{})
	if err != nil {
		return "", err
	}
	if req.TargetContainer != "" {
		found := false
		for _, ct := range pod.Spec.Containers {
			found = found || ct.Name == req.TargetContainer
		}
		if !found {
			return "", httpx.BadRequest("target container %q not found in pod %s", req.TargetContainer, req.Pod)
		}
	}
	name := debugContainerName(pod)
	pod.Spec.EphemeralContainers = append(pod.Spec.EphemeralContainers, corev1.EphemeralContainer{
		EphemeralContainerCommon: corev1.EphemeralContainerCommon{
			Name:                     name,
			Image:                    req.Image,
			ImagePullPolicy:          corev1.PullIfNotPresent,
			Stdin:                    true, // keeps the image's default shell alive
			TTY:                      true,
			TerminationMessagePolicy: corev1.TerminationMessageReadFile,
		},
		TargetContainerName: req.TargetContainer,
	})
	if _, err := pods.UpdateEphemeralContainers(ctx, req.Pod, pod, metav1.UpdateOptions{}); err != nil {
		return "", err
	}
	return name, nil
}

// debugContainerName returns debugger, debugger-2, ... (first unused).
func debugContainerName(pod *corev1.Pod) string {
	used := map[string]bool{}
	for _, c := range pod.Spec.Containers {
		used[c.Name] = true
	}
	for _, c := range pod.Spec.InitContainers {
		used[c.Name] = true
	}
	for _, c := range pod.Spec.EphemeralContainers {
		used[c.Name] = true
	}
	name := "debugger"
	for i := 2; used[name]; i++ {
		name = fmt.Sprintf("debugger-%d", i)
	}
	return name
}

var fatalWaitingReasons = map[string]bool{
	"ErrImagePull": true, "ImagePullBackOff": true, "InvalidImageName": true,
	"CreateContainerError": true, "CreateContainerConfigError": true, "RunContainerError": true,
}

func waitEphemeralRunning(ctx context.Context, c *cluster.Clients, ns, pod, name string) error {
	for {
		p, err := c.Typed.CoreV1().Pods(ns).Get(ctx, pod, metav1.GetOptions{})
		if err != nil {
			return err
		}
		for _, st := range p.Status.EphemeralContainerStatuses {
			if st.Name != name {
				continue
			}
			switch {
			case st.State.Running != nil:
				return nil
			case st.State.Terminated != nil:
				return fmt.Errorf("debug container %s exited: %s (exit %d) %s", name, st.State.Terminated.Reason, st.State.Terminated.ExitCode, st.State.Terminated.Message)
			case st.State.Waiting != nil && fatalWaitingReasons[st.State.Waiting.Reason]:
				return fmt.Errorf("debug container %s: %s: %s", name, st.State.Waiting.Reason, st.State.Waiting.Message)
			}
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("debug container %s did not start in time", name)
		case <-time.After(500 * time.Millisecond):
		}
	}
}
