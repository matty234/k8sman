package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gorilla/websocket"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/settings"
)

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// localRequest is a request as the app sends it: to 127.0.0.1:7443 (and
// arriving on that listener), with the bearer token, and JSON for mutations.
func localRequest(method, path string, body io.Reader) *http.Request {
	r := httptest.NewRequest(method, "http://127.0.0.1:7443"+path, body)
	r = r.WithContext(context.WithValue(r.Context(), http.LocalAddrContextKey, &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7443}))
	r.Header.Set("Authorization", "Bearer "+testToken)
	if mutating(method) {
		r.Header.Set("Content-Type", "application/json")
	}
	return r
}

// guardServer is a real listener on 127.0.0.1 in front of a disconnected
// server (no cluster is contacted).
func guardServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	dir := t.TempDir()
	mgr := cluster.NewDisconnected(filepath.Join(dir, "nope"), errors.New("no kubeconfig"))
	store, _ := columns.OpenStore(filepath.Join(dir, "columns.json"))
	st, _ := settings.Open(filepath.Join(dir, "settings.json"))
	srv := httptest.NewServer(New(mgr, store, nil, Options{Settings: st, AuthToken: testToken}))
	t.Cleanup(srv.Close)
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	return srv, port
}

type probe struct {
	method, path, body string
	header             map[string]string
	host               string
}

func send(t *testing.T, srv *httptest.Server, p probe) (int, http.Header, map[string]any) {
	t.Helper()
	var body io.Reader
	if p.body != "" {
		body = strings.NewReader(p.body)
	}
	req, err := http.NewRequest(p.method, srv.URL+p.path, body)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range p.header {
		req.Header.Set(k, v)
	}
	if p.host != "" {
		req.Host = p.host
	}
	res, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var j map[string]any
	_ = json.NewDecoder(res.Body).Decode(&j)
	return res.StatusCode, res.Header, j
}

func TestGuardRefusesAttacks(t *testing.T) {
	srv, port := guardServer(t)
	auth := "Bearer " + testToken
	cases := []struct {
		name string
		p    probe
		want int
	}{
		// 1. no authentication
		{"no token", probe{method: "GET", path: "/api/health"}, 401},
		{"wrong token", probe{method: "GET", path: "/api/health", header: map[string]string{"Authorization": "Bearer " + strings.Repeat("x", 64)}}, 401},
		{"token prefix", probe{method: "GET", path: "/api/health", header: map[string]string{"Authorization": "Bearer " + testToken[:32]}}, 401},
		{"basic auth", probe{method: "GET", path: "/api/health", header: map[string]string{"Authorization": "Basic " + testToken}}, 401},
		{"token in query is ignored", probe{method: "GET", path: "/api/health?token=" + testToken}, 401},
		{"no token, settings", probe{method: "GET", path: "/api/contexts"}, 401},
		// 2. DNS rebinding
		{"evil host", probe{method: "GET", path: "/api/health", host: "evil.example:" + port, header: map[string]string{"Authorization": auth}}, 403},
		{"evil host no token", probe{method: "GET", path: "/api/health", host: "evil.example:" + port}, 403},
		{"loopback host wrong port", probe{method: "GET", path: "/api/health", host: "127.0.0.1:1", header: map[string]string{"Authorization": auth}}, 403},
		{"host without port", probe{method: "GET", path: "/api/health", host: "localhost", header: map[string]string{"Authorization": auth}}, 403},
		{"localhost suffix host", probe{method: "GET", path: "/api/health", host: "localhost.evil.example:" + port, header: map[string]string{"Authorization": auth}}, 403},
		// 3. Origin prefix bypass
		{"localhost-prefixed origin", probe{method: "GET", path: "/api/health", header: map[string]string{"Origin": "http://localhost.evil.example", "Authorization": auth}}, 403},
		{"127-prefixed origin", probe{method: "GET", path: "/api/health", header: map[string]string{"Origin": "http://127.0.0.1.evil.example:" + port, "Authorization": auth}}, 403},
		{"userinfo origin", probe{method: "GET", path: "/api/health", header: map[string]string{"Origin": "http://localhost@evil.example", "Authorization": auth}}, 403},
		{"null origin", probe{method: "GET", path: "/api/health", header: map[string]string{"Origin": "null", "Authorization": auth}}, 403},
		{"evil preflight", probe{method: "OPTIONS", path: "/api/contexts/current", header: map[string]string{"Origin": "http://localhost.evil.example"}}, 403},
		// 4. CSRF with a "simple" request
		{"text/plain POST no token", probe{method: "POST", path: "/api/contexts/current", body: `{"name":"x"}`, header: map[string]string{"Content-Type": "text/plain"}}, 401},
		{"text/plain POST", probe{method: "POST", path: "/api/contexts/current", body: `{"name":"x"}`, header: map[string]string{"Content-Type": "text/plain", "Authorization": auth}}, 415},
		{"form POST", probe{method: "POST", path: "/api/kubeconfigs/current", body: `path=/x`, header: map[string]string{"Content-Type": "application/x-www-form-urlencoded", "Authorization": auth}}, 415},
		{"no content type DELETE", probe{method: "DELETE", path: "/api/portforwards/x", header: map[string]string{"Authorization": auth}}, 415},
		{"yaml where not allowed", probe{method: "POST", path: "/api/contexts/current", body: "name: x", header: map[string]string{"Content-Type": "application/yaml", "Authorization": auth}}, 415},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			code, h, j := send(t, srv, c.p)
			if code != c.want {
				t.Fatalf("status %d, want %d (%v)", code, c.want, j)
			}
			if h.Get("Access-Control-Allow-Origin") != "" {
				t.Errorf("reflected origin %q", h.Get("Access-Control-Allow-Origin"))
			}
			if c.p.method != "OPTIONS" && (j["error"] == nil || j["code"] != float64(c.want)) {
				t.Errorf("want a JSON error body, got %v", j)
			}
		})
	}
}

func TestGuardAllowsTheApp(t *testing.T) {
	srv, port := guardServer(t)
	auth := map[string]string{"Authorization": "Bearer " + testToken}
	for _, host := range []string{"", "localhost:" + port, "LOCALHOST:" + port, "[::1]:" + port} {
		if code, _, j := send(t, srv, probe{method: "GET", path: "/api/health", host: host, header: auth}); code != 200 {
			t.Errorf("host %q: %d %v", host, code, j)
		}
	}
	// Lower-case scheme, case-insensitive "bearer".
	if code, _, _ := send(t, srv, probe{method: "GET", path: "/api/health", header: map[string]string{"Authorization": "bearer " + testToken}}); code != 200 {
		t.Errorf("lower-case bearer: %d", code)
	}
	// A JSON mutation reaches the handler (400: the file doesn't exist).
	code, _, j := send(t, srv, probe{method: "POST", path: "/api/kubeconfigs/current", body: `{"path":"/does/not/exist"}`,
		header: map[string]string{"Authorization": "Bearer " + testToken, "Content-Type": "application/json; charset=utf-8"}})
	if code == 401 || code == 403 || code == 415 || code == 200 {
		t.Errorf("json POST: %d %v", code, j)
	}
	// YAML is accepted where the endpoint takes it (503: no cluster).
	code, _, j = send(t, srv, probe{method: "PUT", path: "/api/object?resource=pods&name=x", body: "kind: Pod",
		header: map[string]string{"Authorization": "Bearer " + testToken, "Content-Type": "application/yaml"}})
	if code != http.StatusServiceUnavailable {
		t.Errorf("yaml PUT: %d %v", code, j)
	}
	// A local dev origin gets CORS headers.
	code, h, _ := send(t, srv, probe{method: "GET", path: "/api/health", header: map[string]string{"Authorization": "Bearer " + testToken, "Origin": "http://localhost:5000"}})
	if code != 200 || h.Get("Access-Control-Allow-Origin") != "http://localhost:5000" || !strings.Contains(h.Get("Access-Control-Allow-Headers"), "Authorization") {
		t.Errorf("local origin: %d %v", code, h)
	}
}

func TestGuardRefusesWithoutConfiguredToken(t *testing.T) {
	dir := t.TempDir()
	mgr := cluster.NewDisconnected(filepath.Join(dir, "nope"), errors.New("no kubeconfig"))
	store, _ := columns.OpenStore(filepath.Join(dir, "columns.json"))
	srv := httptest.NewServer(New(mgr, store, nil, Options{}))
	defer srv.Close()
	for _, tok := range []string{"", "Bearer ", "Bearer x"} {
		if code, _, _ := send(t, srv, probe{method: "GET", path: "/api/health", header: map[string]string{"Authorization": tok}}); code != 401 {
			t.Errorf("%q: %d", tok, code)
		}
	}
}

func wsURL(srv *httptest.Server, path string) string {
	return "ws" + strings.TrimPrefix(srv.URL, "http") + path
}

// 5. WebSockets go through the same guard.
func TestGuardWebSockets(t *testing.T) {
	srv, port := guardServer(t)
	auth := http.Header{"Authorization": {"Bearer " + testToken}}
	cases := []struct {
		name string
		h    http.Header
		want int
	}{
		{"no token", http.Header{}, 401},
		{"evil origin", http.Header{"Authorization": auth["Authorization"], "Origin": {"http://localhost.evil.example"}}, 403},
		{"evil origin no token", http.Header{"Origin": {"https://evil.example"}}, 403},
		{"evil host", http.Header{"Authorization": auth["Authorization"], "Host": {"evil.example:" + port}}, 403},
		// Past the guard: the disconnected server answers 503 before upgrading.
		{"token", auth, 503},
	}
	for _, path := range []string{"/api/watch?resource=pods", "/api/logs?namespace=a&pod=b", "/api/exec?namespace=a&pod=b"} {
		for _, c := range cases {
			t.Run(path+" "+c.name, func(t *testing.T) {
				_, res, err := websocket.DefaultDialer.Dial(wsURL(srv, path), c.h)
				if err == nil {
					t.Fatal("upgrade succeeded")
				}
				if res == nil || res.StatusCode != c.want {
					t.Fatalf("got %v %v, want %d", res, err, c.want)
				}
			})
		}
	}
}

func TestProtectedUpgradeWithToken(t *testing.T) {
	srv := httptest.NewServer(Protect(testToken, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, _, cancel, err := upgrade(w, r)
		if err != nil {
			return
		}
		defer cancel()
		_ = ws.send(map[string]string{"type": "hello"})
	})))
	defer srv.Close()
	if _, res, err := websocket.DefaultDialer.Dial(wsURL(srv, "/"), nil); err == nil || res.StatusCode != 401 {
		t.Fatalf("without token: %v %v", res, err)
	}
	c, _, err := websocket.DefaultDialer.Dial(wsURL(srv, "/"), http.Header{"Authorization": {"Bearer " + testToken}})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var m map[string]string
	if err := c.ReadJSON(&m); err != nil || m["type"] != "hello" {
		t.Fatalf("%v %v", m, err)
	}
}

func TestIsLocalOrigin(t *testing.T) {
	for o, want := range map[string]bool{
		"http://localhost":              true,
		"http://localhost:5000":         true,
		"https://127.0.0.1:8443":        true,
		"http://[::1]:3000":             true,
		"http://localhost.evil.example": false,
		"http://127.0.0.1.nip.io":       false,
		"http://localhost@evil.example": false,
		"http://evil.example#localhost": false,
		"file://localhost":              false,
		"null":                          false,
		"http://localhost:99999":        false,
	} {
		if got := isLocalOrigin(o); got != want {
			t.Errorf("%s: %v", o, got)
		}
	}
}
