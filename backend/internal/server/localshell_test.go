//go:build !windows

package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// End to end: a real shell in a pty over the WebSocket, with the session
// kubeconfig, the read-only notice, no API token, and the exit code.
func TestLocalShellSession(t *testing.T) {
	dir := t.TempDir()
	kc := writeKubeconfig(t, filepath.Join(dir, "config"), "first", "second")
	mgr, err := cluster.NewManager(kc, "second")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv(AuthTokenEnv, "do-not-leak")
	t.Setenv("ENV", "") // no sh startup file
	s := &Server{mgr: mgr, mux: http.NewServeMux(), readOnly: true}
	s.localShellRoutes()
	srv := httptest.NewServer(s.mux)
	defer srv.Close()

	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/api/local-shell?cols=100&rows=30", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(20 * time.Second))

	var started ExecControl
	if _, data, err := conn.ReadMessage(); err != nil || json.Unmarshal(data, &started) != nil || started.Type != "started" {
		t.Fatalf("first message: %s %v", data, err)
	}
	if started.Container != "second" || started.Command[0] != "/bin/sh" {
		t.Errorf("started: %+v", started)
	}
	script := `first=${KUBECONFIG%%:*}; printf 'ctx=%s tok=%s cols=%s\n' "$(sed -n 's/^current-context: //p' "$first")" "${K8SMAN_AUTH_TOKEN:-none}" "$(stty size | cut -d' ' -f2)"; exit 3` + "\n"
	if err := conn.WriteMessage(websocket.BinaryMessage, []byte(script)); err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	var exit *ExecControl
	for exit == nil {
		mt, data, err := conn.ReadMessage()
		if err != nil {
			t.Fatalf("read: %v\noutput so far:\n%s", err, out.String())
		}
		if mt == websocket.BinaryMessage {
			out.Write(data)
			continue
		}
		var m ExecControl
		_ = json.Unmarshal(data, &m)
		if m.Type == "exit" || m.Type == "error" {
			exit = &m
		}
	}
	got := out.String()
	if !strings.Contains(got, "is read-only in k8sman") {
		t.Errorf("no read-only notice:\n%s", got)
	}
	if !strings.Contains(got, `ctx="second" tok=none cols=100`) {
		t.Errorf("unexpected session output:\n%s", got)
	}
	if exit.Type != "exit" || exit.Code == nil || *exit.Code != 3 {
		t.Errorf("exit: %+v", exit)
	}
	if strings.Contains(got, "do-not-leak") {
		t.Error("the API token reached the shell")
	}
}
