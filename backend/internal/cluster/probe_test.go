package cluster

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// probeKubeconfig writes a kubeconfig whose contexts point at the given
// servers (context name = map key), all with a static token.
func probeKubeconfig(t *testing.T, servers map[string]string) string {
	t.Helper()
	var b strings.Builder
	b.WriteString("apiVersion: v1\nkind: Config\nusers:\n- name: u\n  user:\n    token: secret\nclusters:\n")
	for name, server := range servers {
		fmt.Fprintf(&b, "- name: %s\n  cluster:\n    server: %s\n    insecure-skip-tls-verify: true\n", name, server)
	}
	b.WriteString("contexts:\n")
	for name := range servers {
		fmt.Fprintf(&b, "- name: %s\n  context:\n    cluster: %s\n    user: u\n", name, name)
	}
	path := filepath.Join(t.TempDir(), "kubeconfig")
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// silentListener accepts TCP connections and never answers (a half-up VPN
// or a load balancer with no backends).
func silentListener(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var conns []net.Conn
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			conns = append(conns, c)
			mu.Unlock()
		}
	}()
	t.Cleanup(func() {
		ln.Close()
		mu.Lock()
		defer mu.Unlock()
		for _, c := range conns {
			c.Close()
		}
	})
	return "https://" + ln.Addr().String()
}

func TestProbeReachFailsFastOnSilentServer(t *testing.T) {
	defer func(d time.Duration) { ReachTimeout = d }(ReachTimeout)
	ReachTimeout = 300 * time.Millisecond

	// A TLS server whose handler never returns: TLS works, HTTP never answers.
	hang := make(chan struct{})
	stuck := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-hang:
		case <-r.Context().Done():
		}
	}))
	defer stuck.Close()
	defer close(hang)

	ok := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer secret" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(401)
			fmt.Fprint(w, `{"kind":"Status","apiVersion":"v1","status":"Failure","reason":"Unauthorized","code":401}`)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"major":"1","minor":"31","gitVersion":"v1.31.0"}`)
	}))
	defer ok.Close()

	kc := probeKubeconfig(t, map[string]string{
		"silent":  silentListener(t),
		"stuck":   stuck.URL,
		"refused": "https://127.0.0.1:1",
		"ok":      ok.URL,
	})
	m, err := NewManager(kc, "ok")
	if err != nil {
		t.Fatal(err)
	}

	for _, name := range []string{"silent", "stuck", "refused"} {
		c, err := m.ClientsFor(name)
		if err != nil {
			t.Fatal(err)
		}
		start := time.Now()
		err = c.ProbeReach(context.Background())
		if !errors.Is(err, ErrUnreachable) {
			t.Fatalf("%s: want ErrUnreachable, got %v", name, err)
		}
		if d := time.Since(start); d > 3*time.Second {
			t.Fatalf("%s: probe took %s, want ~%s", name, d, ReachTimeout)
		}
		if !strings.Contains(err.Error(), c.RESTConfig.Host) {
			t.Fatalf("%s: error should name the server: %v", name, err)
		}
	}

	// Reachable: the anonymous probe gets 401, which still means "answering".
	c, _ := m.ClientsFor("ok")
	if err := c.ProbeReach(context.Background()); err != nil {
		t.Fatalf("ok reach: %v", err)
	}
	if err := c.ProbeAuth(context.Background()); err != nil {
		t.Fatalf("ok auth: %v", err)
	}
}

// A context whose requests hang must not block switching to another one.
func TestSwitchNotBlockedByHangingProbe(t *testing.T) {
	defer func(d time.Duration) { ReachTimeout = d }(ReachTimeout)
	ReachTimeout = 5 * time.Second

	kc := probeKubeconfig(t, map[string]string{"dead": silentListener(t), "other": "https://127.0.0.1:1"})
	m, err := NewManager(kc, "dead")
	if err != nil {
		t.Fatal(err)
	}
	dead := m.Clients()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- dead.ProbeReach(ctx) }()

	time.Sleep(100 * time.Millisecond)
	start := time.Now()
	if err := m.SwitchContext("other"); err != nil {
		t.Fatal(err)
	}
	if err := m.SwitchContext("dead"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := m.Contexts(); err != nil {
		t.Fatal(err)
	}
	if d := time.Since(start); d > 500*time.Millisecond {
		t.Fatalf("switching took %s while a probe was in flight", d)
	}
	// Cancelling the request (the UI's Cancel) ends the probe.
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("probe ignored cancellation")
	}
}
