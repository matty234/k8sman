package server

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/apimachinery/pkg/util/httpstream/wsstream"
	wstransport "k8s.io/client-go/transport/websocket"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
)

// KubeVirt serial console. Upstream is the VMI's console subresource over a
// WebSocket (subprotocol plain.kubevirt.io, raw binary frames both ways).
// Downstream speaks the same frames as /api/exec so the terminal UI is shared.

const vmConsoleProtocol = "plain.kubevirt.io"

// Console error reasons sent to the UI (shared with exec where they overlap).
const (
	reasonVMINotFound   = reasonPodNotFound         // the VMI doesn't exist
	reasonVMINotRunning = reasonContainerNotRunning // phase is not Running
	reasonNoKubeVirt    = reasonExecFailed          // KubeVirt isn't installed
)

var vmiGVR = schema.GroupVersionResource{Group: "kubevirt.io", Version: "v1", Resource: "virtualmachineinstances"}

// dialVMConsole opens the console WebSocket, authenticating with the
// context's credentials (client certs, tokens, exec plugins, proxies) via
// client-go's websocket round tripper, the same one remotecommand uses.
func dialVMConsole(ctx context.Context, c *cluster.Clients, ns, name string) (*websocket.Conn, error) {
	rt, holder, err := wstransport.RoundTripperFor(c.RESTConfig)
	if err != nil {
		return nil, err
	}
	host, err := url.Parse(c.RESTConfig.Host)
	if err != nil || host.Host == "" {
		// rest.Config allows a bare host:port.
		if host, err = url.Parse("https://" + strings.TrimPrefix(c.RESTConfig.Host, "//")); err != nil {
			return nil, err
		}
	}
	u := *host
	u.Path = strings.TrimSuffix(host.Path, "/") + "/apis/subresources.kubevirt.io/v1/namespaces/" + url.PathEscape(ns) + "/virtualmachineinstances/" + url.PathEscape(name) + "/console"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header[wsstream.WebSocketProtocolHeader] = []string{vmConsoleProtocol}
	if _, err := rt.RoundTrip(req); err != nil {
		return nil, err
	}
	conn := holder.Connection()
	if conn == nil {
		return nil, errors.New("console connection was not established")
	}
	return conn, nil
}

// classifyVMConsoleError maps a failed dial to a UI error reason.
func classifyVMConsoleError(err error) string {
	var ue *httpstream.UpgradeFailureError
	if errors.As(err, &ue) {
		err = ue.Cause
	}
	switch {
	case apierrors.IsForbidden(err):
		return reasonForbidden
	case apierrors.IsNotFound(err):
		return reasonVMINotFound
	}
	if strings.Contains(strings.ToLower(err.Error()), "phase is") {
		return reasonVMINotRunning
	}
	return reasonExecFailed
}

func (s *Server) vmConsoleRoutes() {
	s.mux.HandleFunc("GET /api/vm-console", s.handleVMConsole)
}

// handleVMConsole relays a VMI's serial console. Query: namespace, name.
func (s *Server) handleVMConsole(w http.ResponseWriter, r *http.Request) {
	if s.isReadOnly() {
		httpx.WriteError(w, http.StatusForbidden, "Forbidden", "the serial console is disabled in read-only mode")
		return
	}
	q := r.URL.Query()
	ns, name := q.Get("namespace"), q.Get("name")
	if ns == "" || name == "" {
		writeErr(w, httpx.BadRequest("namespace and name are required"))
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
	fail := func(reason, msg string) {
		_ = ws.send(ExecControl{Type: "error", Reason: reason, Message: msg})
	}

	c := s.mgr.Clients()
	vmi, err := c.Dynamic.Resource(vmiGVR).Namespace(ns).Get(ctx, name, metav1.GetOptions{})
	switch {
	case err == nil:
		phase, _ := vmi.Object["status"].(map[string]any)["phase"].(string)
		if phase != "Running" {
			if phase == "" {
				phase = "not started"
			}
			fail(reasonVMINotRunning, fmt.Sprintf("VirtualMachineInstance %s is %s; the console needs a Running VMI", name, phase))
			return
		}
	case meta.IsNoMatchError(err) || (apierrors.IsNotFound(err) && strings.Contains(err.Error(), "could not find the requested resource")):
		fail(reasonNoKubeVirt, "KubeVirt does not appear to be installed in this cluster")
		return
	case apierrors.IsNotFound(err):
		fail(reasonVMINotFound, fmt.Sprintf("VirtualMachineInstance %s/%s not found (is the VM running?)", ns, name))
		return
	case apierrors.IsForbidden(err):
		// No get on VMIs doesn't mean no console: try the dial.
	default:
		fail(reasonExecFailed, err.Error())
		return
	}

	up, err := dialVMConsole(ctx, c, ns, name)
	if err != nil {
		reason := classifyVMConsoleError(err)
		msg := err.Error()
		if reason == reasonForbidden {
			msg = fmt.Sprintf("not allowed to open the console of %s/%s (needs get on virtualmachineinstances/console): %s", ns, name, msg)
		}
		fail(reason, msg)
		return
	}
	defer up.Close()
	if ws.send(ExecControl{Type: "started", Container: "serial console", Command: []string{"serial console"}}) != nil {
		return
	}
	relayVMConsole(ctx, cancel, ws, up)
}

// relayVMConsole copies bytes between the client and the upstream console
// until either side closes. Resize frames are ignored (the plain protocol
// has none). Sends an exit frame when the console ends on its own.
func relayVMConsole(ctx context.Context, cancel context.CancelFunc, ws *wsConn, up *websocket.Conn) {
	go func() { // client → console
		defer cancel()
		ws.conn.SetReadLimit(1 << 20)
		for {
			mt, data, err := ws.conn.ReadMessage()
			if err != nil {
				return
			}
			if mt == websocket.BinaryMessage {
				if err := up.WriteMessage(websocket.BinaryMessage, data); err != nil {
					return
				}
			} // text frames are resize: nothing to do
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
				_ = ws.conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
				ws.mu.Unlock()
			}
		}
	}()
	go func() { <-ctx.Done(); _ = up.Close() }()

	out := &wsBinaryWriter{ws: ws}
	for { // console → client
		_, data, err := up.ReadMessage()
		if err != nil {
			if ctx.Err() == nil {
				code := 0
				_ = ws.send(ExecControl{Type: "exit", Code: &code})
			}
			return
		}
		if _, err := out.Write(data); err != nil {
			return
		}
	}
}
