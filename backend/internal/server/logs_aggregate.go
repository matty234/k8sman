package server

import (
	"bufio"
	"container/heap"
	"context"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
)

const (
	aggMaxPods        = 50
	aggDefaultTail    = 200
	defaultContainerA = "kubectl.kubernetes.io/default-container"
)

// Aggregate tunables; tests shorten them.
var (
	aggReorderWindow = 250 * time.Millisecond
	aggFlushEvery    = 75 * time.Millisecond
)

// logOpener opens one container's log stream. The fake clientset can't
// stream logs, so tests substitute this.
type logOpener interface {
	Open(ctx context.Context, ns, pod string, opts *corev1.PodLogOptions) (io.ReadCloser, error)
}

type kubeLogOpener struct{ cs kubernetes.Interface }

func (k kubeLogOpener) Open(ctx context.Context, ns, pod string, opts *corev1.PodLogOptions) (io.ReadCloser, error) {
	return k.cs.CoreV1().Pods(ns).GetLogs(pod, opts).Stream(ctx)
}

// AggLine is one element of a line frame (a JSON array of these is sent per
// flush).
type AggLine struct {
	Pod       string `json:"pod"`
	Container string `json:"container"`
	TS        string `json:"ts"`
	Line      string `json:"line"`
}

// AggEvent is a control frame on /api/logs/aggregate.
type AggEvent struct {
	Event     string `json:"event,omitempty"` // added | removed
	Pod       string `json:"pod,omitempty"`
	Container string `json:"container,omitempty"`
	Error     string `json:"error,omitempty"`
	Warning   string `json:"warning,omitempty"`
}

type aggEntry struct {
	AggLine
	t       time.Time // parsed log timestamp (or arrival)
	arrived time.Time
	seq     uint64
}

type entryHeap []*aggEntry

func (h entryHeap) Len() int { return len(h) }
func (h entryHeap) Less(i, j int) bool {
	if !h[i].t.Equal(h[j].t) {
		return h[i].t.Before(h[j].t)
	}
	return h[i].seq < h[j].seq
}
func (h entryHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *entryHeap) Push(x any)   { *h = append(*h, x.(*aggEntry)) }
func (h *entryHeap) Pop() any {
	o := *h
	n := len(o)
	x := o[n-1]
	*h = o[:n-1]
	return x
}

type aggStream struct {
	cancel   context.CancelFunc
	done     atomic.Bool
	restarts int32
}

type aggKey struct{ pod, container string }

// aggregator merges the logs of a changing set of pods.
type aggregator struct {
	ns        string
	container string // "" = each pod's default, "*" = all, else a name
	tail      int64  // -1 = all
	since     int64
	previous  bool
	follow    bool
	opener    logOpener
	emit      func(any) error // must be safe for concurrent use

	initial  bool
	warned   bool
	reported map[aggKey]bool
	seq      atomic.Uint64
}

// run follows the pod sets delivered on pods (each a full desired set) until
// ctx ends, then closes every stream and returns once all goroutines have
// exited.
func (a *aggregator) run(ctx context.Context, pods <-chan []*corev1.Pod) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wg sync.WaitGroup
	in := make(chan *aggEntry, 1024)
	wg.Add(1)
	go func() { defer wg.Done(); a.merge(ctx, in, cancel) }()
	streams := map[aggKey]*aggStream{}
	a.initial = true
	a.reported = map[aggKey]bool{}
loop:
	for {
		select {
		case <-ctx.Done():
			break loop
		case ps := <-pods:
			a.reconcile(ctx, &wg, in, streams, ps)
			a.initial = false
		}
	}
	cancel()
	wg.Wait()
}

func (a *aggregator) containersFor(p *corev1.Pod) []string {
	switch a.container {
	case "*":
		out := make([]string, 0, len(p.Spec.Containers))
		for _, c := range p.Spec.Containers {
			out = append(out, c.Name)
		}
		return out
	case "":
		if d := p.Annotations[defaultContainerA]; d != "" {
			return []string{d}
		}
		if hasContainer(p, "main") { // Argo steps: main next to wait and init
			return []string{"main"}
		}
		if len(p.Spec.Containers) > 0 {
			return []string{p.Spec.Containers[0].Name}
		}
		return nil
	}
	return []string{a.container}
}

// startable reports whether the container has run (or is running), so logs
// exist; it also returns the restart count.
func startable(p *corev1.Pod, name string, previous bool) (bool, int32) {
	for _, cs := range p.Status.ContainerStatuses {
		if cs.Name != name {
			continue
		}
		if previous {
			return cs.RestartCount > 0 || cs.LastTerminationState.Terminated != nil, cs.RestartCount
		}
		return cs.State.Running != nil || cs.State.Terminated != nil, cs.RestartCount
	}
	return false, 0
}

func hasContainer(p *corev1.Pod, name string) bool {
	for _, c := range p.Spec.Containers {
		if c.Name == name {
			return true
		}
	}
	return false
}

func (a *aggregator) reconcile(ctx context.Context, wg *sync.WaitGroup, in chan<- *aggEntry, streams map[aggKey]*aggStream, ps []*corev1.Pod) {
	sort.Slice(ps, func(i, j int) bool { return ps[i].Name < ps[j].Name })
	if len(ps) > aggMaxPods {
		if !a.warned {
			a.warned = true
			_ = a.emit(AggEvent{Warning: fmt.Sprintf("%d pods match; streaming the first %d by name", len(ps), aggMaxPods)})
		}
		ps = ps[:aggMaxPods]
	}
	present := map[string]bool{}
	for _, p := range ps {
		present[p.Name] = true
		for _, c := range a.containersFor(p) {
			k := aggKey{p.Name, c}
			ok, restarts := startable(p, c, a.previous)
			st := streams[k]
			if st != nil && st.done.Load() && a.follow && restarts > st.restarts {
				delete(streams, k) // container restarted: follow the new instance
				st = nil
			}
			if st != nil {
				continue
			}
			if !ok {
				if !hasContainer(p, c) && !a.reported[k] {
					a.reported[k] = true
					_ = a.emit(AggEvent{Pod: p.Name, Container: c, Error: "container not found in pod"})
				}
				continue
			}
			sctx, scancel := context.WithCancel(ctx)
			st = &aggStream{cancel: scancel, restarts: restarts}
			streams[k] = st
			_ = a.emit(AggEvent{Event: "added", Pod: p.Name, Container: c})
			wg.Add(1)
			go func(k aggKey, st *aggStream, initial bool) {
				defer wg.Done()
				defer st.done.Store(true)
				a.stream(sctx, in, k, initial)
			}(k, st, a.initial)
		}
	}
	for k, st := range streams {
		if !present[k.pod] {
			st.cancel()
			delete(streams, k)
			_ = a.emit(AggEvent{Event: "removed", Pod: k.pod, Container: k.container})
		}
	}
}

func (a *aggregator) stream(ctx context.Context, in chan<- *aggEntry, k aggKey, initial bool) {
	opts := &corev1.PodLogOptions{Container: k.container, Follow: a.follow, Previous: a.previous, Timestamps: true}
	if initial && a.tail >= 0 { // pods that appear later are read from their start
		t := a.tail
		opts.TailLines = &t
	}
	if a.since > 0 {
		s := a.since
		opts.SinceSeconds = &s
	}
	rc, err := a.opener.Open(ctx, a.ns, k.pod, opts)
	if err != nil {
		if ctx.Err() == nil {
			_ = a.emit(AggEvent{Pod: k.pod, Container: k.container, Error: err.Error()})
		}
		return
	}
	defer rc.Close()
	// Unblock a Read stuck in the transport when ctx ends.
	stop := context.AfterFunc(ctx, func() { rc.Close() })
	defer stop()
	sc := bufio.NewScanner(rc)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		now := time.Now()
		ts, line := splitTimestamp(sc.Text())
		t, err := time.Parse(time.RFC3339Nano, ts)
		if err != nil { // no timestamp: keep the whole line, order by arrival
			t, ts, line = now, now.UTC().Format(time.RFC3339Nano), sc.Text()
		}
		e := &aggEntry{AggLine: AggLine{Pod: k.pod, Container: k.container, TS: ts, Line: line}, t: t, arrived: now, seq: a.seq.Add(1)}
		select {
		case in <- e:
		case <-ctx.Done():
			return
		}
	}
	if err := sc.Err(); err != nil && err != io.EOF && ctx.Err() == nil {
		_ = a.emit(AggEvent{Pod: k.pod, Container: k.container, Error: err.Error()})
	}
}

// splitTimestamp separates the RFC3339Nano prefix added by timestamps=true.
func splitTimestamp(s string) (string, string) {
	if i := strings.IndexByte(s, ' '); i > 0 {
		return s[:i], s[i+1:]
	}
	return s, ""
}

// merge orders entries by timestamp: an entry is released once it has been
// held for the reorder window, smallest timestamp first, so a slower stream's
// older lines can still slot in ahead of it. Released entries go out as one
// array frame per flush interval.
func (a *aggregator) merge(ctx context.Context, in <-chan *aggEntry, cancel context.CancelFunc) {
	var h entryHeap
	tick := time.NewTicker(aggFlushEvery)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case e := <-in:
			heap.Push(&h, e)
		case now := <-tick.C:
			var batch []AggLine
			for h.Len() > 0 && now.Sub(h[0].arrived) >= aggReorderWindow {
				batch = append(batch, heap.Pop(&h).(*aggEntry).AggLine)
			}
			if len(batch) > 0 && a.emit(batch) != nil {
				cancel()
				return
			}
		}
	}
}

// handleLogsAggregate streams the merged logs of several pods.
// Query: namespace; selector or pods (comma-separated); container (name, *,
// or empty for each pod's default: annotation, then main, then the first); tailLines (per stream, default 200),
// sinceSeconds, previous, follow (default true).
func (s *Server) handleLogsAggregate(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	ns, selector := q.Get("namespace"), q.Get("selector")
	var names []string
	for _, n := range strings.Split(q.Get("pods"), ",") {
		if n = strings.TrimSpace(n); n != "" {
			names = append(names, n)
		}
	}
	if ns == "" || (selector == "") == (len(names) == 0) {
		writeErr(w, httpx.BadRequest("namespace and exactly one of selector or pods are required"))
		return
	}
	a := &aggregator{
		ns: ns, container: q.Get("container"), tail: aggDefaultTail,
		previous: q.Get("previous") == "true", follow: q.Get("follow") != "false",
	}
	if v, err := strconv.ParseInt(q.Get("tailLines"), 10, 64); err == nil {
		a.tail = v
	}
	if v, err := strconv.ParseInt(q.Get("sinceSeconds"), 10, 64); err == nil && v > 0 {
		a.since = v
	}
	c := s.mgr.Clients()
	a.opener = kubeLogOpener{c.Typed}

	ws, ctx, cancel, err := upgrade(w, r)
	if err != nil {
		return
	}
	defer cancel()
	defer ws.close()
	a.emit = ws.send

	pods := make(chan []*corev1.Pod, 1)
	if selector == "" {
		var ps []*corev1.Pod
		for _, n := range names {
			p, err := c.Typed.CoreV1().Pods(ns).Get(ctx, n, metav1.GetOptions{})
			if err != nil {
				_ = ws.send(AggEvent{Pod: n, Error: err.Error()})
				continue
			}
			ps = append(ps, p)
		}
		pods <- ps
		a.run(ctx, pods)
		return
	}

	// Follow the selector through the shared pod watch.
	sub := kcache.For(c).Subscribe(kcache.Key{GVR: gvrPods, Namespace: ns, LabelSelector: selector})
	defer sub.Close()
	runDone := make(chan struct{})
	go func() { defer close(runDone); a.run(ctx, pods); cancel() }()
	defer func() { cancel(); <-runDone }()
	cur := map[string]*corev1.Pod{}
	for {
		select {
		case <-ctx.Done():
			return
		case <-sub.C():
		}
		u := sub.Next()
		if u.Err != nil {
			_ = ws.send(AggEvent{Error: u.Err.Error()})
			if u.Terminal {
				return
			}
		}
		if u.Snapshot != nil {
			clear(cur)
			for _, it := range u.Snapshot.Items {
				addPod(cur, it.Object)
			}
		}
		for _, ev := range u.Events {
			if ev.Type == watch.Deleted {
				delete(cur, ev.Object.GetName())
			} else {
				addPod(cur, ev.Object.Object)
			}
		}
		set := make([]*corev1.Pod, 0, len(cur))
		for _, p := range cur {
			set = append(set, p)
		}
		select { // the latest set wins
		case <-pods:
		default:
		}
		select {
		case pods <- set:
		case <-ctx.Done():
			return
		}
		if a.previous { // previous logs are finite: the pod set is not followed
			<-ctx.Done()
			return
		}
	}
}

func addPod(m map[string]*corev1.Pod, obj map[string]any) {
	var p corev1.Pod
	if runtime.DefaultUnstructuredConverter.FromUnstructured(obj, &p) == nil {
		m[p.Name] = &p
	}
}
