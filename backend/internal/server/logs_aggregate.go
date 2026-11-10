package server

import (
	"bufio"
	"container/heap"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
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
	Namespace string `json:"namespace,omitempty"`
	Pod       string `json:"pod"`
	Container string `json:"container"`
	TS        string `json:"ts"`
	Line      string `json:"line"`
}

// AggEvent is a control frame on /api/logs/aggregate.
type AggEvent struct {
	Event     string `json:"event,omitempty"` // added | removed
	Namespace string `json:"namespace,omitempty"`
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

type aggKey struct{ ns, pod, container string }

// aggregator merges the logs of a changing set of pods.
type aggregator struct {
	container string // "" = each pod's default, "*" = all, else a name
	// containerRe, when set, keeps only the matching containers (of all the
	// pod's containers when container is "").
	containerRe *regexp.Regexp
	tail        int64 // -1 = all
	since       int64
	previous    bool
	follow      bool
	opener      logOpener
	emit        func(any) error // must be safe for concurrent use

	initial  bool
	warned   bool
	reported map[aggKey]bool
	streams  sync.WaitGroup // the stream goroutines alone (see run)
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
	finished := make(chan struct{}) // closed once a non-following run has read every stream to EOF
	wg.Add(1)
	go func() { defer wg.Done(); a.merge(ctx, in, finished, cancel) }()
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
			if !a.follow { // one pass over the pods as they are, to EOF
				go func() { a.streams.Wait(); close(finished) }()
				pods = nil
			}
		}
	}
	cancel()
	wg.Wait()
}

func (a *aggregator) containersFor(p *corev1.Pod) []string {
	cs := a.baseContainers(p)
	if a.containerRe == nil {
		return cs
	}
	out := cs[:0:0]
	for _, c := range cs {
		if a.containerRe.MatchString(c) {
			out = append(out, c)
		}
	}
	return out
}

func (a *aggregator) baseContainers(p *corev1.Pod) []string {
	container := a.container
	if container == "" && a.containerRe != nil {
		container = "*"
	}
	switch container {
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
	sort.Slice(ps, func(i, j int) bool { return podID(ps[i]) < podID(ps[j]) })
	if len(ps) > aggMaxPods {
		if !a.warned {
			a.warned = true
			_ = a.emit(AggEvent{Warning: fmt.Sprintf("%d pods match; streaming the first %d by name; narrow the query to see the rest", len(ps), aggMaxPods)})
		}
		ps = ps[:aggMaxPods]
	}
	present := map[string]bool{}
	for _, p := range ps {
		present[podID(p)] = true
		for _, c := range a.containersFor(p) {
			k := aggKey{p.Namespace, p.Name, c}
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
					_ = a.emit(AggEvent{Namespace: p.Namespace, Pod: p.Name, Container: c, Error: "container not found in pod"})
				}
				continue
			}
			sctx, scancel := context.WithCancel(ctx)
			st = &aggStream{cancel: scancel, restarts: restarts}
			streams[k] = st
			_ = a.emit(AggEvent{Event: "added", Namespace: p.Namespace, Pod: p.Name, Container: c})
			wg.Add(1)
			a.streams.Add(1)
			go func(k aggKey, st *aggStream, initial bool) {
				defer wg.Done()
				defer a.streams.Done()
				defer st.done.Store(true)
				a.stream(sctx, in, k, initial)
			}(k, st, a.initial)
		}
	}
	for k, st := range streams {
		if !present[k.ns+"/"+k.pod] {
			st.cancel()
			delete(streams, k)
			_ = a.emit(AggEvent{Event: "removed", Namespace: k.ns, Pod: k.pod, Container: k.container})
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
	rc, err := a.opener.Open(ctx, k.ns, k.pod, opts)
	if err != nil {
		if ctx.Err() == nil {
			_ = a.emit(AggEvent{Namespace: k.ns, Pod: k.pod, Container: k.container, Error: err.Error()})
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
		e := &aggEntry{AggLine: AggLine{Namespace: k.ns, Pod: k.pod, Container: k.container, TS: ts, Line: line}, t: t, arrived: now, seq: a.seq.Add(1)}
		select {
		case in <- e:
		case <-ctx.Done():
			return
		}
	}
	if err := sc.Err(); err != nil && err != io.EOF && ctx.Err() == nil {
		_ = a.emit(AggEvent{Namespace: k.ns, Pod: k.pod, Container: k.container, Error: err.Error()})
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
func (a *aggregator) merge(ctx context.Context, in <-chan *aggEntry, finished <-chan struct{}, cancel context.CancelFunc) {
	var h entryHeap
	tick := time.NewTicker(aggFlushEvery)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case e := <-in:
			heap.Push(&h, e)
		case <-finished: // every stream ended: flush what is held, then end the run
			for len(in) > 0 {
				heap.Push(&h, <-in)
			}
			var batch []AggLine
			for h.Len() > 0 {
				batch = append(batch, heap.Pop(&h).(*aggEntry).AggLine)
			}
			if len(batch) > 0 {
				_ = a.emit(batch)
			}
			cancel()
			return
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

func podID(p *corev1.Pod) string { return p.Namespace + "/" + p.Name }

// aggQuery is a parsed /api/logs/aggregate request.
type aggQuery struct {
	scope      kube.Namespaces
	selectors  []string
	names      []string // fixed pods (one namespace)
	podRe      *regexp.Regexp
	containerR *regexp.Regexp
}

func parseAggQuery(q url.Values, parseScope func(url.Values) (kube.Namespaces, error)) (*aggQuery, error) {
	aq := &aggQuery{}
	var err error
	if aq.scope, err = parseScope(q); err != nil {
		return nil, httpx.BadRequest("%v", err)
	}
	for _, sel := range q["selector"] {
		if sel = strings.TrimSpace(sel); sel != "" {
			aq.selectors = append(aq.selectors, sel)
		}
	}
	for _, n := range strings.Split(q.Get("pods"), ",") {
		if n = strings.TrimSpace(n); n != "" {
			aq.names = append(aq.names, n)
		}
	}
	for _, f := range []struct {
		param string
		dst   **regexp.Regexp
	}{{"podRegex", &aq.podRe}, {"containerRegex", &aq.containerR}} {
		if v := q.Get(f.param); v != "" {
			if *f.dst, err = regexp.Compile(v); err != nil {
				return nil, httpx.BadRequest("%s: %v", f.param, err)
			}
		}
	}
	switch {
	case len(aq.names) > 0:
		if len(aq.selectors) > 0 || aq.podRe != nil || len(aq.scope) != 1 {
			return nil, httpx.BadRequest("pods needs exactly one namespace and no selector or podRegex")
		}
	case len(aq.selectors) == 0 && aq.podRe == nil:
		return nil, httpx.BadRequest("one of selector, pods or podRegex is required")
	}
	return aq, nil
}

// podSet unions the pods of several watches, keeping those whose name
// matches re, and delivers the latest full set once every watch has
// reported. Safe for concurrent use.
type podSet struct {
	mu    sync.Mutex
	re    *regexp.Regexp
	cur   []map[string]*corev1.Pod
	ready []bool
	out   chan []*corev1.Pod // capacity 1; only the latest set is kept
}

func newPodSet(n int, re *regexp.Regexp) *podSet {
	ps := &podSet{re: re, cur: make([]map[string]*corev1.Pod, n), ready: make([]bool, n), out: make(chan []*corev1.Pod, 1)}
	for i := range ps.cur {
		ps.cur[i] = map[string]*corev1.Pod{}
	}
	return ps
}

func (ps *podSet) allReady() bool {
	for _, r := range ps.ready {
		if !r {
			return false
		}
	}
	return true
}

// apply folds one watch update in and publishes the union; it reports
// whether the set has been published.
func (ps *podSet) apply(i int, u kcache.Update) bool {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	if u.Snapshot != nil {
		clear(ps.cur[i])
		for _, it := range u.Snapshot.Items {
			addPod(ps.cur[i], it.Object)
		}
		ps.ready[i] = true
	}
	for _, ev := range u.Events {
		if ev.Type == watch.Deleted {
			delete(ps.cur[i], ev.Object.GetNamespace()+"/"+ev.Object.GetName())
		} else {
			addPod(ps.cur[i], ev.Object.Object)
		}
	}
	if !ps.allReady() {
		return false
	}
	seen := map[string]bool{}
	var set []*corev1.Pod
	for _, m := range ps.cur {
		for id, p := range m {
			if !seen[id] && (ps.re == nil || ps.re.MatchString(p.Name)) {
				seen[id] = true
				set = append(set, p)
			}
		}
	}
	select {
	case <-ps.out:
	default:
	}
	ps.out <- set
	return true
}

// handleLogsAggregate streams the merged logs of several pods.
// Query: namespace or namespaces (none = every allowed namespace); selector
// (repeatable, results unioned), podRegex and containerRegex (RE2, unanchored)
// or pods (comma-separated, one namespace); container (name, *, or empty for
// each pod's default: annotation, then main, then the first); tailLines (per
// stream, default 200), sinceSeconds, previous, follow (default true). The
// pod set follows the shared pod watch and is capped at aggMaxPods.
func (s *Server) handleLogsAggregate(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aq, err := parseAggQuery(q, s.parseScope)
	if err != nil {
		writeErr(w, err)
		return
	}
	a := &aggregator{
		container: q.Get("container"), containerRe: aq.containerR, tail: aggDefaultTail,
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
	if len(aq.names) > 0 {
		ns := aq.scope[0]
		var ps []*corev1.Pod
		for _, n := range aq.names {
			p, err := c.Typed.CoreV1().Pods(ns).Get(ctx, n, metav1.GetOptions{})
			if err != nil {
				_ = ws.send(AggEvent{Namespace: ns, Pod: n, Error: err.Error()})
				continue
			}
			p.Namespace = ns
			ps = append(ps, p)
		}
		pods <- ps
		a.run(ctx, pods)
		return
	}

	// Follow the selectors through the shared pod watch.
	sels := aq.selectors
	if len(sels) == 0 {
		sels = []string{""}
	}
	set := newPodSet(len(sels), aq.podRe)
	runDone := make(chan struct{})
	go func() { defer close(runDone); a.run(ctx, set.out); cancel() }()
	var wg sync.WaitGroup
	defer func() { cancel(); wg.Wait(); <-runDone }()
	for i, sel := range sels {
		sub := kcache.For(c).SubscribeSet(kcache.Key{GVR: gvrPods, LabelSelector: sel}, aq.scope)
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer sub.Close()
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
						cancel()
						return
					}
				}
				// Previous logs are finite: the set is not followed.
				if set.apply(i, u) && a.previous {
					<-ctx.Done()
					return
				}
			}
		}()
	}
	<-ctx.Done()
}

func addPod(m map[string]*corev1.Pod, obj map[string]any) {
	var p corev1.Pod
	if runtime.DefaultUnstructuredConverter.FromUnstructured(obj, &p) == nil {
		m[podID(&p)] = &p
	}
}
