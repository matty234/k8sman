package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
)

// wsPair runs fn with a server-side wsConn and returns the client end.
func wsPair(t *testing.T, fn func(ws *wsConn)) *websocket.Conn {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, ctx, cancel, err := upgrade(w, r)
		if err != nil {
			return
		}
		defer cancel()
		fn(ws)
		<-ctx.Done()
	}))
	t.Cleanup(srv.Close)
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

type gotFrame struct {
	Type   string `json:"type"`
	Row    *Row   `json:"row"`
	Events []struct {
		Type string `json:"type"`
		Row  Row    `json:"row"`
	} `json:"events"`
}

func readFrames(t *testing.T, c *websocket.Conn, n int) []gotFrame {
	t.Helper()
	var out []gotFrame
	for range n {
		_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
		_, b, err := c.ReadMessage()
		if err != nil {
			t.Fatalf("after %d frames: %v", len(out), err)
		}
		var f gotFrame
		if err := json.Unmarshal(b, &f); err != nil {
			t.Fatal(err)
		}
		out = append(out, f)
	}
	return out
}

func br(uid, rv string) *builtRow {
	return &builtRow{Row: Row{UID: uid, Name: uid, ResourceVersion: rv, Cells: []any{rv}}}
}

// drive runs the writer like handleWatch's select loop: events, then
// flushes when due.
func drive(t *testing.T, fw *frameWriter, events func(fw *frameWriter)) {
	events(fw)
	select {
	case <-fw.due():
		if err := fw.flush(); err != nil {
			t.Error(err)
		}
	case <-time.After(2 * time.Second):
		t.Error("batch never became due")
	}
}

func TestFrameWriterBatchesAndCoalesces(t *testing.T) {
	c := wsPair(t, func(ws *wsConn) {
		drive(t, newFrameWriter(ws, true), func(fw *frameWriter) {
			_ = fw.add("ADDED", br("x", "1"))
			_ = fw.add("MODIFIED", br("y", "1"))
			_ = fw.add("MODIFIED", br("x", "2")) // replaces x's row, stays ADDED
			_ = fw.add("DELETED", br("z", "1"))
			_ = fw.add("MODIFIED", br("y", "2"))
			_ = fw.add("DELETED", br("x", "3"))
		})
	})
	f := readFrames(t, c, 1)[0]
	if f.Type != "BATCH" {
		t.Fatalf("want BATCH, got %+v", f)
	}
	var got []string
	for _, e := range f.Events {
		got = append(got, e.Type+":"+e.Row.UID+"@"+e.Row.ResourceVersion)
	}
	want := []string{"ADDED:x@2", "MODIFIED:y@2", "DELETED:z@1", "DELETED:x@3"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("events\n got  %v\n want %v", got, want)
	}
}

// The pre-encoded SNAPSHOT must match what encoding the WatchMessage would
// produce, row cache or not.
func TestSnapshotFrameMatchesWatchMessage(t *testing.T) {
	cols := []columns.Column{{Name: "Name", Query: ".metadata.name"}, {Name: "Bad", Query: ".x | error"}}
	for _, memo := range []bool{false, true} {
		b := newTableBuilder(cols, false)
		if memo {
			cache := map[any]any{}
			b.memo = func(u *unstructured.Unstructured, tag any, extra string, compute func() any) any {
				k := [3]any{u.GetUID(), tag, extra}
				if v, ok := cache[k]; ok {
					return v
				}
				v := compute()
				cache[k] = v
				return v
			}
		}
		items := []*unstructured.Unstructured{pod("b", "2"), pod("a", "1")}
		t1, built := b.tableOf(cluster.ResourceType{Resource: "pods", Version: "v1"}, true, items, "9")
		got := map[string]any{}
		if err := json.Unmarshal(snapshotFrame(t1, built), &got); err != nil {
			t.Fatal(err)
		}
		wantB, _ := json.Marshal(WatchMessage{Type: "SNAPSHOT", Table: &t1})
		want := map[string]any{}
		_ = json.Unmarshal(wantB, &want)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("memo=%v\n got  %v\n want %v", memo, got, want)
		}
		if t1.ColumnErrors[1] == "" {
			t.Fatal("column errors lost")
		}
	}
}
