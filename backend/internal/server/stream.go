package server

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/gorilla/websocket"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/watch"
)

var upgrader = websocket.Upgrader{
	// Desktop clients send no Origin; browsers in dev send localhost.
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

func (ws *wsConn) close() {
	ws.mu.Lock()
	_ = ws.conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	ws.mu.Unlock()
	_ = ws.conn.Close()
}

// WatchMessage is a frame on /api/watch.
type WatchMessage struct {
	// SNAPSHOT (full table; replace all rows), ADDED, MODIFIED, DELETED, ERROR.
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

// handleWatch streams a live table: a SNAPSHOT, then row deltas. If the
// underlying watch expires it re-lists and sends a fresh SNAPSHOT.
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

	cols, isDefault := s.columnsFor(ctx, c, rq.Type)
	includeObject := r.URL.Query().Get("includeObject") == "true"
	ri := rq.client(c)
	backoff := time.Second
	live := s.newLiveUsage(c, rq) // periodic usage refresh for pods/nodes
	defer live.stop()

	for ctx.Err() == nil {
		list, err := ri.List(ctx, rq.listOptions())
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			_ = ws.send(errorFrame(c, err))
			if apierrors.IsForbidden(err) || apierrors.IsNotFound(err) {
				return
			}
			sleep(ctx, backoff)
			backoff = min(backoff*2, 30*time.Second)
			continue
		}
		b := newTableBuilder(cols, includeObject)
		b.decorate = s.usageDecorator(ctx, c, rq)
		t := b.table(rq.Type, isDefault, list)
		live.reset(list, t)
		if ws.send(WatchMessage{Type: "SNAPSHOT", Table: &t}) != nil {
			return
		}
		opts := rq.listOptions()
		opts.ResourceVersion = list.GetResourceVersion()
		opts.AllowWatchBookmarks = true
		wi, err := ri.Watch(ctx, opts)
		if err != nil {
			sleep(ctx, backoff)
			continue
		}
		backoff = time.Second
		if !s.pumpWatch(ctx, ws, wi, b, live) {
			wi.Stop()
			return
		}
		wi.Stop()
	}
}

// pumpWatch forwards events until the watch ends. Returns false if the client
// is gone.
func (s *Server) pumpWatch(ctx context.Context, ws *wsConn, wi watch.Interface, b *tableBuilder, live *liveUsage) bool {
	for {
		select {
		case <-ctx.Done():
			return false
		case <-live.tick():
			for _, row := range live.changedRows(ctx, b) {
				if ws.send(WatchMessage{Type: string(watch.Modified), Row: &row}) != nil {
					return false
				}
			}
		case ev, ok := <-wi.ResultChan():
			if !ok {
				return true // re-list
			}
			switch ev.Type {
			case watch.Added, watch.Modified, watch.Deleted:
				u, ok := ev.Object.(*unstructured.Unstructured)
				if !ok {
					continue
				}
				row := b.row(u)
				live.track(ev.Type, u, row)
				if ws.send(WatchMessage{Type: string(ev.Type), Row: &row}) != nil {
					return false
				}
			case watch.Error:
				return true // usually 410 Gone → re-list
			}
		}
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
		writeErr(w, badRequest("namespace and pod are required"))
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
