package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

// The relay maps console bytes to binary frames and back, ignores resize
// frames, and reports exit when the console closes.
func TestRelayVMConsole(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, _ := upgrader.Upgrade(w, r, nil)
		defer c.Close()
		_ = c.WriteMessage(websocket.BinaryMessage, []byte("login: "))
		_, in, _ := c.ReadMessage() // resize must not arrive first
		_ = c.WriteMessage(websocket.BinaryMessage, append([]byte("got "), in...))
	}))
	defer up.Close()
	upConn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(up.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}

	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, _ := upgrader.Upgrade(w, r, nil)
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		relayVMConsole(ctx, cancel, &wsConn{conn: c}, upConn)
		c.Close()
	}))
	defer down.Close()
	cl, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(down.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()

	_, b, _ := cl.ReadMessage()
	if string(b) != "login: " {
		t.Fatalf("first frame %q", b)
	}
	_ = cl.WriteMessage(websocket.TextMessage, []byte(`{"type":"resize","cols":80,"rows":24}`))
	_ = cl.WriteMessage(websocket.BinaryMessage, []byte("root"))
	_, b, _ = cl.ReadMessage()
	if string(b) != "got root" {
		t.Fatalf("echo %q", b)
	}
	mt, b, _ := cl.ReadMessage()
	if mt != websocket.TextMessage || !strings.Contains(string(b), `"exit"`) {
		t.Fatalf("want exit frame, got %d %q", mt, b)
	}
}
