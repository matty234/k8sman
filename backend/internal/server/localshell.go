package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// Local shells: `GET /api/local-shell` (WebSocket) runs the user's login
// shell on this machine in a pseudo-terminal, with the exec protocol of
// /api/exec (binary frames = terminal bytes, text frames = ExecControl).
//
// The shell's KUBECONFIG puts a small per-session file first that sets only
// current-context, followed by the kubeconfig the app is using, so kubectl,
// helm, k9s and friends target the cluster on screen without touching the
// user's kubeconfig or other terminals.

func (s *Server) localShellRoutes() {
	s.mux.HandleFunc("GET /api/local-shell", s.handleLocalShell)
}

// errLocalShellUnsupported is returned by startLocalShell where there is no
// implementation yet (Windows).
var errLocalShellUnsupported = errors.New("local shells aren't supported on this platform yet")

// localShell is a running shell in a pseudo-terminal.
type localShell interface {
	io.ReadWriter
	Resize(cols, rows uint16) error
	// Wait returns the exit code once the process has exited.
	Wait() (int, error)
	// Close hangs up (SIGHUP to the shell's process group) and, if it's
	// still running after a grace period, kills it. Releases the terminal.
	Close() error
}

// localShellSpec is what to start.
type localShellSpec struct {
	Shell      string
	Args       []string
	Dir        string
	Env        []string
	Cols, Rows uint16
}

// localShellEnv is the environment for a local shell: the backend's own,
// minus anything k8sman-internal, with the session KUBECONFIG and terminal
// variables set.
func localShellEnv(base []string, kubeconfig, contextName string) []string {
	out := make([]string, 0, len(base)+6)
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		switch {
		case k == AuthTokenEnv, strings.HasPrefix(k, "K8SMAN_"):
			continue // never hand the API token (or other internals) to the shell
		case k == "KUBECONFIG", k == "TERM", k == "COLORTERM", k == "TERM_PROGRAM":
			continue // set below
		}
		out = append(out, kv)
	}
	out = append(out,
		"TERM=xterm-256color",
		"COLORTERM=truecolor",
		"TERM_PROGRAM=k8sman",
		"KUBECONFIG="+kubeconfig,
	)
	if contextName != "" {
		out = append(out, "K8SMAN_CONTEXT="+contextName)
	}
	return out
}

// kubeconfigChain is the KUBECONFIG list the app's kubeconfig corresponds
// to: the explicit file, else $KUBECONFIG, else ~/.kube/config.
func kubeconfigChain(explicit, envKubeconfig, home string) string {
	switch {
	case explicit != "":
		return explicit
	case envKubeconfig != "":
		return envKubeconfig
	default:
		return filepath.Join(home, ".kube", "config")
	}
}

// writeContextKubeconfig writes a kubeconfig that only sets current-context
// (0600, in dir) and returns its path.
func writeContextKubeconfig(dir, contextName string) (string, error) {
	f, err := os.CreateTemp(dir, "k8sman-shell-*.kubeconfig")
	if err != nil {
		return "", err
	}
	// JSON is valid YAML and quotes the name safely.
	name, _ := json.Marshal(contextName)
	_, err = fmt.Fprintf(f, "apiVersion: v1\nkind: Config\ncurrent-context: %s\n", name)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(f.Name())
		return "", err
	}
	return f.Name(), nil
}

// readOnlyShellNotice is printed (yellow) at the top of a local shell when
// the context is read-only in k8sman, which can't apply to the shell.
func readOnlyShellNotice(contextName string) string {
	return "\x1b[33mk8sman: " + contextName + " is read-only in k8sman, but commands in this shell use your own " +
		"credentials and can change the cluster.\x1b[0m\r\n"
}

func (s *Server) handleLocalShell(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	ws := &wsConn{conn: conn}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	defer ws.close()
	fail := func(err error) {
		_ = ws.send(ExecControl{Type: "error", Reason: reasonExecFailed, Message: err.Error()})
	}

	contextName := ""
	if c := s.mgr.Clients(); c != nil {
		contextName = c.Context
	}
	home, _ := os.UserHomeDir()
	chain := kubeconfigChain(s.mgr.Kubeconfig(), os.Getenv("KUBECONFIG"), home)
	if contextName != "" {
		tmp, err := writeContextKubeconfig("", contextName)
		if err != nil {
			fail(fmt.Errorf("could not prepare the shell's kubeconfig: %w", err))
			return
		}
		defer os.Remove(tmp)
		chain = tmp + string(os.PathListSeparator) + chain
	}

	spec := localShellSpec{Dir: home, Env: localShellEnv(os.Environ(), chain, contextName)}
	spec.Shell, spec.Args = userShell()
	if cols, err1 := strconv.Atoi(q.Get("cols")); err1 == nil {
		if rows, err2 := strconv.Atoi(q.Get("rows")); err2 == nil && cols > 0 && rows > 0 && cols < 1<<16 && rows < 1<<16 {
			spec.Cols, spec.Rows = uint16(cols), uint16(rows)
		}
	}
	sh, err := startLocalShell(spec)
	if err != nil {
		fail(err)
		return
	}
	defer sh.Close()

	if ws.send(ExecControl{Type: "started", Container: contextName, Command: append([]string{spec.Shell}, spec.Args...)}) != nil {
		return
	}
	out := &wsBinaryWriter{ws: ws}
	if contextName != "" && s.isReadOnly() {
		_, _ = out.Write([]byte(readOnlyShellNotice(contextName)))
	}

	// Client → shell: binary frames are keystrokes, text frames control.
	go func() {
		defer cancel()
		conn.SetReadLimit(1 << 20)
		for {
			mt, data, err := conn.ReadMessage()
			if err != nil {
				return
			}
			switch mt {
			case websocket.BinaryMessage:
				if _, err := sh.Write(data); err != nil {
					return
				}
			case websocket.TextMessage:
				var m ExecControl
				if json.Unmarshal(data, &m) == nil && m.Type == "resize" && m.Cols > 0 && m.Rows > 0 {
					_ = sh.Resize(m.Cols, m.Rows)
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

	// Shell → client until the terminal closes (the shell exited) or the
	// client went away (the deferred Close hangs the shell up).
	copied := make(chan struct{})
	go func() {
		defer close(copied)
		_, _ = io.Copy(out, sh)
	}()
	select {
	case <-copied:
	case <-ctx.Done():
		return
	}
	code, err := sh.Wait()
	if ctx.Err() != nil {
		return
	}
	if err != nil && code < 0 {
		fail(err)
		return
	}
	_ = ws.send(ExecControl{Type: "exit", Code: &code})
}
