package server

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/watch"
)

var upgrader = websocket.Upgrader{
	// Desktop clients send no Origin; browsers in dev send localhost.
	// ServeHTTP has already refused other origins; this is a second check.
	CheckOrigin: func(r *http.Request) bool {
		o := r.Header.Get("Origin")
		return o == "" || isLocalOrigin(o)
	},
}

// wsConn serialises writes and cancels ctx when the client goes away.
type wsConn struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

func upgrade(w http.ResponseWriter, r *http.Request) (*wsConn, context.Context, context.CancelFunc, error) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return nil, nil, nil, err
	}
	ctx, cancel := context.WithCancel(r.Context())
	ws := &wsConn{conn: conn}
	go func() { // reader: detect close
		defer cancel()
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
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
	return ws, ctx, cancel, nil
}

func (ws *wsConn) send(v any) error {
	ws.mu.Lock()
	defer ws.mu.Unlock()
	_ = ws.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return ws.conn.WriteJSON(v)
}

// sendBytes writes a pre-encoded JSON frame.
func (ws *wsConn) sendBytes(b []byte) error {
	ws.mu.Lock()
	defer ws.mu.Unlock()
	_ = ws.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return ws.conn.WriteMessage(websocket.TextMessage, b)
}

func (ws *wsConn) close() {
	ws.mu.Lock()
	_ = ws.conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	ws.mu.Unlock()
	_ = ws.conn.Close()
}

// WatchMessage is a frame on /api/watch.
type WatchMessage struct {
	// SNAPSHOT (full table; replace all rows), ADDED, MODIFIED, DELETED,
	// ERROR, or (only with ?batch=true) BATCH: several row events in order.
	Type  string `json:"type"`
	Table *Table `json:"table,omitempty"`
	Row   *Row   `json:"row,omitempty"`
	Error string `json:"error,omitempty"`
	// On ERROR: Unreachable, Unauthorized, Forbidden, NotFound, Timeout, or
	// another Kubernetes StatusReason; empty when unclassified.
	Reason string `json:"reason,omitempty"`
	// On ERROR: the HTTP status equivalent (401, 403, 404, 502, 504, …).
	Code int `json:"code,omitempty"`
	// On ERROR: the cluster API server URL, for "can't reach <host>".
	Host string `json:"host,omitempty"`
	// On PARTIAL_ERROR: the namespace of a namespace set that can't be
	// watched (the others carry on and the socket stays open).
	Namespace string `json:"namespace,omitempty"`
}

// partialFrame reports one namespace of a set that ended for good.
func partialFrame(p kcache.NamespaceError) WatchMessage {
	m := errorFrame(nil, p.Err)
	m.Type, m.Namespace = "PARTIAL_ERROR", p.Namespace
	return m
}

// errorFrame builds an ERROR frame with the error classified for the UI.
func errorFrame(c *cluster.Clients, err error) WatchMessage {
	m := WatchMessage{Type: "ERROR", Error: err.Error()}
	m.Reason, m.Code = classifyError(err)
	if m.Reason == "" {
		var se apierrors.APIStatus
		if errors.As(err, &se) {
			m.Reason, m.Code = string(se.Status().Reason), int(se.Status().Code)
		}
	}
	if c != nil && c.RESTConfig != nil {
		m.Host = c.RESTConfig.Host
	}
	return m
}

// handleWatch streams a live table: a SNAPSHOT, then row deltas. Every
// watcher of the same resource shares one upstream list+watch (kcache); if
// the upstream watch expires it re-lists and sends a fresh SNAPSHOT.
// With ?batch=true, deltas arriving within batchWindow are coalesced into
// one BATCH frame.
func (s *Server) handleWatch(w http.ResponseWriter, r *http.Request) {
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		// Report over the socket so the client can tell a cluster problem
		// from the backend being down (a failed handshake looks the same).
		if reason, _ := classifyError(err); reason == "" {
			writeErr(w, err)
			return
		}
		ws, _, cancel, uerr := upgrade(w, r)
		if uerr != nil {
			return
		}
		defer cancel()
		defer ws.close()
		_ = ws.send(errorFrame(c, err))
		return
	}
	ws, ctx, cancel, err := upgrade(w, r)
	if err != nil {
		return
	}
	defer cancel()
	defer ws.close()

	cols, isDefault := s.tableColumns(ctx, c, rq)
	includeObject := r.URL.Query().Get("includeObject") == "true"
	sub := s.subscribe(c, rq) // one stream, or a namespace set merged

	defer sub.Close()
	live := s.newLiveUsage(c, rq) // periodic usage refresh for pods/nodes
	defer live.stop()
	out := newFrameWriter(ws, r.URL.Query().Get("batch") == "true")
	defer out.stop()

	var b *tableBuilder
	for {
		select {
		case <-ctx.Done():
			return
		case <-out.due():
			if out.flush() != nil {
				return
			}
		case <-live.tick():
			if b == nil {
				continue
			}
			for _, row := range live.changedRows(ctx, b) {
				if out.add(string(watch.Modified), &builtRow{Row: row}) != nil {
					return
				}
			}
		case <-sub.C():
			u := sub.Next()
			for _, p := range u.Partial {
				if ws.send(partialFrame(p)) != nil {
					return
				}
			}
			switch {
			case u.Err != nil:
				if out.flush() != nil || ws.send(errorFrame(c, u.Err)) != nil || u.Terminal {
					return
				}
			case u.Snapshot != nil:
				out.discard() // the snapshot supersedes queued deltas
				b = newTableBuilder(cols, includeObject)
				b.decorate = s.usageDecorator(ctx, c, rq)
				b.memo = sub.Memo
				t, built := b.tableOf(rq.Type, isDefault, u.Snapshot.Items, u.Snapshot.ResourceVersion)
				live.resetItems(u.Snapshot.Items, t.Rows)
				if ws.sendBytes(snapshotFrame(t, built)) != nil {
					return
				}
			}
			for _, ev := range u.Events {
				if b == nil {
					break
				}
				br := b.build(ev.Object)
				live.track(ev.Type, ev.Object, br.Row)
				if out.add(string(ev.Type), br) != nil {
					return
				}
			}
		}
	}
}

// snapshotFrame encodes a SNAPSHOT, reusing each row's cached JSON.
func snapshotFrame(t Table, built []*builtRow) []byte {
	type wireTable struct {
		Table
		Rows []json.RawMessage `json:"rows"` // shadows Table.Rows
	}
	wt := wireTable{Table: t, Rows: make([]json.RawMessage, len(built))}
	for i, br := range built {
		wt.Rows[i] = br.json()
	}
	b, _ := json.Marshal(struct {
		Type  string     `json:"type"`
		Table *wireTable `json:"table"`
	}{"SNAPSHOT", &wt})
	return b
}

func (br *builtRow) json() json.RawMessage {
	if br.raw != nil {
		return br.raw
	}
	b, _ := json.Marshal(br.Row)
	return b
}

// batchWindow is how long deltas are collected before a BATCH frame is sent;
// maxBatch flushes early.
var (
	batchWindow = 75 * time.Millisecond
	maxBatch    = 1000
)

type batchEvent struct {
	Type string          `json:"type"`
	Row  json.RawMessage `json:"row"`
	uid  string
}

// frameWriter sends row deltas: one frame each (the original protocol), or,
// when the client opted in with batch=true, coalesced into BATCH frames.
// Within a batch a later ADDED/MODIFIED of the same object replaces the
// earlier row in place, so a burst of updates to one object costs one row.
type frameWriter struct {
	ws    *wsConn
	batch bool
	queue []batchEvent
	index map[string]int // uid → position of its last ADDED/MODIFIED
	timer *time.Timer
}

func newFrameWriter(ws *wsConn, batch bool) *frameWriter {
	return &frameWriter{ws: ws, batch: batch, index: map[string]int{}}
}

// due fires when a pending batch should be sent (nil when nothing is queued).
func (f *frameWriter) due() <-chan time.Time {
	if f.timer == nil {
		return nil
	}
	return f.timer.C
}

func (f *frameWriter) add(typ string, br *builtRow) error {
	if !f.batch {
		return f.ws.sendBytes(eventFrame(typ, br.json()))
	}
	uid := br.Row.UID
	if typ != string(watch.Deleted) {
		if i, ok := f.index[uid]; ok {
			f.queue[i].Row = br.json()
			return nil
		}
		f.index[uid] = len(f.queue)
	} else {
		delete(f.index, uid)
	}
	f.queue = append(f.queue, batchEvent{Type: typ, Row: br.json(), uid: uid})
	if len(f.queue) >= maxBatch {
		return f.flush()
	}
	if f.timer == nil {
		f.timer = time.NewTimer(batchWindow)
	}
	return nil
}

func eventFrame(typ string, row json.RawMessage) []byte {
	b, _ := json.Marshal(struct {
		Type string          `json:"type"`
		Row  json.RawMessage `json:"row"`
	}{typ, row})
	return b
}

// flush sends queued deltas: a lone event as a plain frame, more as BATCH.
func (f *frameWriter) flush() error {
	q := f.queue
	f.discard()
	switch len(q) {
	case 0:
		return nil
	case 1:
		return f.ws.sendBytes(eventFrame(q[0].Type, q[0].Row))
	}
	b, _ := json.Marshal(struct {
		Type   string       `json:"type"`
		Events []batchEvent `json:"events"`
	}{"BATCH", q})
	return f.ws.sendBytes(b)
}

func (f *frameWriter) discard() {
	f.queue = nil
	clear(f.index)
	f.stop()
}

func (f *frameWriter) stop() {
	if f.timer != nil {
		f.timer.Stop()
		f.timer = nil
	}
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

// LogMessage is a frame on /api/logs.
type LogMessage struct {
	Line  string `json:"line,omitempty"`
	Error string `json:"error,omitempty"`
	EOF   bool   `json:"eof,omitempty"`
}

// handleLogs streams container logs, one frame per line.
// Query: namespace, pod, container, tailLines (default 500), sinceSeconds,
// previous, timestamps, follow (default true).
func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	ns, pod := q.Get("namespace"), q.Get("pod")
	if ns == "" || pod == "" {
		writeErr(w, httpx.BadRequest("namespace and pod are required"))
		return
	}
	opts := &corev1.PodLogOptions{
		Container:  q.Get("container"),
		Follow:     q.Get("follow") != "false",
		Previous:   q.Get("previous") == "true",
		Timestamps: q.Get("timestamps") == "true",
	}
	tail := int64(500)
	if v, err := strconv.ParseInt(q.Get("tailLines"), 10, 64); err == nil {
		tail = v
	}
	if tail >= 0 {
		opts.TailLines = &tail
	}
	if v, err := strconv.ParseInt(q.Get("sinceSeconds"), 10, 64); err == nil && v > 0 {
		opts.SinceSeconds = &v
	}

	ws, ctx, cancel, err := upgrade(w, r)
	if err != nil {
		return
	}
	defer cancel()
	defer ws.close()

	c := s.mgr.Clients()
	stream, err := c.Typed.CoreV1().Pods(ns).GetLogs(pod, opts).Stream(ctx)
	if err != nil {
		_ = ws.send(LogMessage{Error: err.Error()})
		return
	}
	defer stream.Close()
	sc := bufio.NewScanner(stream)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		if ws.send(LogMessage{Line: sc.Text()}) != nil {
			return
		}
	}
	if err := sc.Err(); err != nil && err != io.EOF && ctx.Err() == nil {
		_ = ws.send(LogMessage{Error: err.Error()})
		return
	}
	_ = ws.send(LogMessage{EOF: true})
}
