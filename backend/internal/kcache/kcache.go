// Package kcache is a per-context, ref-counted cache of shared list+watch
// streams ("informers") over the dynamic client.
//
// Every UI watcher of the same resource shares one upstream LIST+WATCH;
// snapshot readers (tables, raw items, the Overview analysis) are answered
// from memory while a stream is warm. A stream with no subscribers is kept
// for an idle period and then stopped.
//
// It deliberately mirrors what a per-connection list+watch loop used to do,
// so errors look the same to the UI: a failed LIST is reported to every
// subscriber (Forbidden and NotFound end the stream, anything else is retried
// with backoff), an expired watch (410 Gone) triggers a re-list and a fresh
// snapshot, and a watch that simply ends is resumed from the last seen
// resourceVersion without a re-list.
package kcache

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/dynamic"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// Key identifies one upstream list+watch.
type Key struct {
	GVR           schema.GroupVersionResource
	Namespace     string // "" = all namespaces (or cluster-scoped)
	LabelSelector string
	FieldSelector string
}

const (
	// DefaultIdle is how long a stream nobody uses is kept warm.
	DefaultIdle = 90 * time.Second
	// DefaultMaxPending bounds the events queued for one slow subscriber;
	// beyond it the queue is dropped and the subscriber gets a fresh snapshot.
	DefaultMaxPending = 4096
)

// Cache holds the streams of one cluster connection.
type Cache struct {
	dyn  dynamic.Interface
	idle time.Duration
	// tunables, per instance so tests can shorten them
	maxPending             int
	minBackoff, maxBackoff time.Duration

	mu      sync.Mutex
	streams map[Key]*stream
}

// New builds a cache over a dynamic client.
func New(dyn dynamic.Interface) *Cache {
	return &Cache{dyn: dyn, idle: DefaultIdle, maxPending: DefaultMaxPending, minBackoff: time.Second, maxBackoff: 30 * time.Second, streams: map[Key]*stream{}}
}

var (
	registryMu sync.Mutex
	registry   = map[*cluster.Clients]*Cache{}
)

// For returns the cache for a client snapshot (one per kube context, so
// caches never mix clusters).
func For(c *cluster.Clients) *Cache {
	registryMu.Lock()
	defer registryMu.Unlock()
	if k, ok := registry[c]; ok {
		return k
	}
	k := New(c.Dynamic)
	registry[c] = k
	return k
}

// Stats is a point-in-time view for tests and diagnostics.
type Stats struct {
	Streams     int // live upstream streams
	Subscribers int
}

// Stats counts streams and subscribers.
func (c *Cache) Stats() Stats {
	c.mu.Lock()
	defer c.mu.Unlock()
	s := Stats{Streams: len(c.streams)}
	for _, st := range c.streams {
		s.Subscribers += st.refs
	}
	return s
}

// Close stops every stream.
func (c *Cache) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k, s := range c.streams {
		s.cancel()
		delete(c.streams, k)
	}
}

// ---- matching -----------------------------------------------------------

// filter matches objects of a broader stream against a narrower key.
type filter struct {
	labels labels.Selector // nil = everything
	name   string
	ns     string
	nsSet  map[string]bool // a namespace set (SubscribeSet); nil = any
}

func (f *filter) match(u *unstructured.Unstructured) bool {
	if f == nil {
		return true
	}
	if f.ns != "" && u.GetNamespace() != f.ns {
		return false
	}
	if f.nsSet != nil && !f.nsSet[u.GetNamespace()] {
		return false
	}
	if f.name != "" && u.GetName() != f.name {
		return false
	}
	return f.labels == nil || f.labels.Matches(labels.Set(u.GetLabels()))
}

// narrowing returns the filter that turns stream key `broad` into `want`,
// or false when broad's items can't answer want (different resource,
// narrower namespace, or a selector that can't be evaluated locally).
func narrowing(broad, want Key) (*filter, bool) {
	if broad.GVR != want.GVR || broad.LabelSelector != "" || broad.FieldSelector != "" {
		return nil, false
	}
	if broad.Namespace != "" && broad.Namespace != want.Namespace {
		return nil, false
	}
	f := &filter{}
	if want.Namespace != broad.Namespace {
		f.ns = want.Namespace
	}
	if want.LabelSelector != "" {
		sel, err := labels.Parse(want.LabelSelector)
		if err != nil {
			return nil, false
		}
		f.labels = sel
	}
	if want.FieldSelector != "" {
		sel, err := fields.ParseSelector(want.FieldSelector)
		if err != nil {
			return nil, false
		}
		for _, r := range sel.Requirements() {
			if r.Operator != "=" && r.Operator != "==" {
				return nil, false
			}
			switch r.Field {
			case "metadata.name":
				f.name = r.Value
			case "metadata.namespace":
				if f.ns != "" && f.ns != r.Value {
					return nil, false
				}
				f.ns = r.Value
			default:
				return nil, false // e.g. status.phase: let the API server filter
			}
		}
	}
	if f.ns == "" && f.name == "" && f.labels == nil {
		return nil, true
	}
	return f, true
}

// warmLocked finds a synced stream that can answer key: the exact one, else
// a broader one (all namespaces, no selectors) with a local filter.
func (c *Cache) warmLocked(key Key) (*stream, *filter) {
	if s := c.streams[key]; s != nil && s.isWarm() {
		return s, nil
	}
	for _, bk := range []Key{{GVR: key.GVR, Namespace: key.Namespace}, {GVR: key.GVR}} {
		if bk == key {
			continue
		}
		if s := c.streams[bk]; s != nil && s.isWarm() {
			if f, ok := narrowing(bk, key); ok {
				return s, f
			}
		}
	}
	return nil, nil
}

// acquire returns a stream for key (warm broader one, else the exact one,
// started if needed) with one reference held.
func (c *Cache) acquire(key Key) (*stream, *filter) {
	c.mu.Lock()
	defer c.mu.Unlock()
	s, f := c.warmLocked(key)
	if s == nil {
		s = c.streams[key]
		if s == nil {
			s = c.start(key)
		}
	}
	s.refs++
	if s.idleTimer != nil {
		s.idleTimer.Stop()
		s.idleTimer = nil
	}
	return s, f
}

func (c *Cache) release(s *stream) {
	c.mu.Lock()
	defer c.mu.Unlock()
	s.refs--
	if s.refs > 0 || c.streams[s.key] != s {
		return
	}
	s.idleTimer = time.AfterFunc(c.idle, func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		if s.refs == 0 && c.streams[s.key] == s {
			delete(c.streams, s.key)
			s.cancel()
		}
	})
}

// drop forgets a stream that ended for good (Forbidden/NotFound), so the
// next user starts over with a fresh LIST.
func (c *Cache) drop(s *stream) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.streams[s.key] == s {
		delete(c.streams, s.key)
	}
}

// ---- snapshot reads ---------------------------------------------------------

// Snapshot is a consistent view of a stream's objects. Objects are shared
// with the cache and must not be modified.
type Snapshot struct {
	Items           []*unstructured.Unstructured
	ResourceVersion string
	stream          *stream
	filter          *filter
}

// Cached answers from a warm stream, or returns ok=false when there is none
// (the caller should LIST directly). Reading keeps the stream warm.
func (c *Cache) Cached(key Key) (Snapshot, bool) {
	c.mu.Lock()
	s, f := c.warmLocked(key)
	if s != nil && s.refs == 0 && s.idleTimer != nil {
		s.idleTimer.Reset(c.idle)
	}
	c.mu.Unlock()
	if s == nil {
		return Snapshot{}, false
	}
	snap, err := s.snapshot(f)
	return snap, err == nil
}

// List answers from the cache, starting (and keeping warm for the idle
// period) a stream when there is none: the first call costs one LIST, later
// ones none. Errors are those of the underlying LIST.
func (c *Cache) List(ctx context.Context, key Key) (Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	if snap, ok := c.Cached(key); ok {
		return snap, nil
	}
	s, f := c.acquire(key)
	defer c.release(s)
	select {
	case <-ctx.Done():
		return Snapshot{}, ctx.Err()
	case <-s.ready:
	}
	return s.snapshot(f)
}

// ---- the stream -------------------------------------------------------------

type stream struct {
	c      *Cache
	key    Key
	ri     dynamic.ResourceInterface
	ctx    context.Context
	cancel context.CancelFunc

	// guarded by Cache.mu
	refs      int
	idleTimer *time.Timer

	// ready is closed once the first LIST has succeeded or failed.
	ready     chan struct{}
	readyOnce sync.Once

	mu       sync.Mutex
	items    map[string]*unstructured.Unstructured // by namespace/name
	rv       string
	synced   bool  // the last LIST succeeded and the data is current
	err      error // last LIST error while not synced
	terminal bool  // ended for good (Forbidden/NotFound)
	subs     map[*Sub]struct{}
	memo     map[types.UID]map[any]memoVal // see Sub.Memo
}

func (c *Cache) start(key Key) *stream {
	ctx, cancel := context.WithCancel(context.Background())
	ri := c.dyn.Resource(key.GVR)
	var r dynamic.ResourceInterface = ri
	if key.Namespace != "" {
		r = ri.Namespace(key.Namespace)
	}
	s := &stream{c: c, key: key, ri: r, ctx: ctx, cancel: cancel, ready: make(chan struct{}),
		items: map[string]*unstructured.Unstructured{}, subs: map[*Sub]struct{}{}}
	c.streams[key] = s
	go s.run()
	return s
}

func objKey(u *unstructured.Unstructured) string { return u.GetNamespace() + "/" + u.GetName() }

// trim drops what no cache reader uses as an object enters the cache:
// metadata.managedFields is often the largest part of an object, and only
// the YAML tab shows it, from a live GET (/api/object).
func trim(u *unstructured.Unstructured) {
	if md, ok := u.Object["metadata"].(map[string]any); ok {
		delete(md, "managedFields")
	}
}

func (s *stream) isWarm() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.synced
}

func (s *stream) listOptions() metav1.ListOptions {
	return metav1.ListOptions{LabelSelector: s.key.LabelSelector, FieldSelector: s.key.FieldSelector}
}

// IsTerminal reports whether a LIST error ends a stream instead of being
// retried (the UI can't fix these by waiting).
func IsTerminal(err error) bool {
	return apierrors.IsForbidden(err) || apierrors.IsNotFound(err) || apierrors.IsMethodNotSupported(err)
}

func (s *stream) run() {
	defer s.readyOnce.Do(func() { close(s.ready) })
	backoff := s.c.minBackoff
	first := true
	for s.ctx.Err() == nil {
		// The first LIST is answered from the API server's watch cache
		// (resourceVersion 0, like client-go reflectors): no etcd quorum read.
		// Re-lists after an expired watch ask for the latest version.
		opts := s.listOptions()
		if first {
			opts.ResourceVersion = "0"
		}
		list, err := s.ri.List(s.ctx, opts)
		if err != nil {
			if s.ctx.Err() != nil {
				return
			}
			terminal := IsTerminal(err)
			s.fail(err, terminal)
			if terminal {
				s.c.drop(s)
				s.cancel()
				return
			}
			sleep(s.ctx, backoff)
			backoff = min(backoff*2, s.c.maxBackoff)
			continue
		}
		s.replace(list)
		first = false
		backoff = s.c.minBackoff
		// Watch from the listed version; resume after a plain close, re-list
		// only when the version has expired or the watch can't be opened.
		for s.ctx.Err() == nil {
			opts := s.listOptions()
			opts.ResourceVersion = s.currentRV()
			opts.AllowWatchBookmarks = true
			wi, err := s.ri.Watch(s.ctx, opts)
			if err != nil {
				if s.ctx.Err() == nil && !apierrors.IsGone(err) && !apierrors.IsResourceExpired(err) {
					sleep(s.ctx, backoff)
					backoff = min(backoff*2, s.c.maxBackoff)
				}
				break // re-list
			}
			relist := s.pump(wi)
			wi.Stop()
			if relist {
				break
			}
			backoff = s.c.minBackoff
		}
	}
}

func (s *stream) currentRV() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rv
}

// pump applies watch events until the watch ends. It returns true when a
// re-list is needed (an ERROR event, usually 410 Gone).
func (s *stream) pump(wi watch.Interface) bool {
	for {
		select {
		case <-s.ctx.Done():
			return false
		case ev, ok := <-wi.ResultChan():
			if !ok {
				return false
			}
			switch ev.Type {
			case watch.Added, watch.Modified, watch.Deleted:
				if u, ok := ev.Object.(*unstructured.Unstructured); ok {
					s.apply(ev.Type, u)
				}
			case watch.Bookmark:
				if u, ok := ev.Object.(*unstructured.Unstructured); ok {
					s.mu.Lock()
					s.rv = u.GetResourceVersion()
					s.mu.Unlock()
				}
			case watch.Error:
				return true
			}
		}
	}
}

func (s *stream) replace(list *unstructured.UnstructuredList) {
	s.mu.Lock()
	clear(s.items)
	for i := range list.Items {
		u := &list.Items[i]
		trim(u)
		s.items[objKey(u)] = u
	}
	s.rv = list.GetResourceVersion()
	s.synced, s.err = true, nil
	for sub := range s.subs {
		sub.resync = true
		sub.pending = nil
		sub.err = nil
		sub.wake()
	}
	s.pruneMemoLocked()
	s.mu.Unlock()
	s.readyOnce.Do(func() { close(s.ready) })
}

func (s *stream) apply(t watch.EventType, u *unstructured.Unstructured) {
	trim(u)
	s.mu.Lock()
	defer s.mu.Unlock()
	k := objKey(u)
	if t == watch.Deleted {
		delete(s.items, k)
	} else {
		s.items[k] = u
	}
	if rv := u.GetResourceVersion(); rv != "" {
		s.rv = rv
	}
	for sub := range s.subs {
		sub.push(t, u)
	}
	if t == watch.Deleted {
		s.forgetMemoLocked(u)
	}
}

func (s *stream) fail(err error, terminal bool) {
	s.mu.Lock()
	s.synced, s.err, s.terminal = false, err, terminal
	for sub := range s.subs {
		sub.err, sub.terminal = err, terminal
		sub.wake()
	}
	s.mu.Unlock()
	s.readyOnce.Do(func() { close(s.ready) })
}

// snapshot copies the current items (pointers) in namespace/name order.
func (s *stream) snapshot(f *filter) (Snapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.synced {
		if s.err != nil {
			return Snapshot{}, s.err
		}
		return Snapshot{}, errors.New("kcache: not synced")
	}
	return s.snapshotLocked(f), nil
}

func (s *stream) snapshotLocked(f *filter) Snapshot {
	// Same order as a LIST from the API server (by "namespace/name" key),
	// so analyses that keep list order produce identical output.
	keys := make([]string, 0, len(s.items))
	for k, u := range s.items {
		if f.match(u) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	items := make([]*unstructured.Unstructured, len(keys))
	for i, k := range keys {
		items[i] = s.items[k]
	}
	return Snapshot{Items: items, ResourceVersion: s.rv, stream: s, filter: f}
}

// Warm returns a snapshot of every synced stream that has no label or field
// selector (so each holds all of its kind in its namespace scope). It starts
// nothing and does not keep streams warm; use it to scan what is already
// cached, e.g. for owner lookups.
func (c *Cache) Warm() []Snapshot {
	c.mu.Lock()
	var ss []*stream
	for k, s := range c.streams {
		if k.LabelSelector == "" && k.FieldSelector == "" {
			ss = append(ss, s)
		}
	}
	c.mu.Unlock()
	var out []Snapshot
	for _, s := range ss {
		if snap, err := s.snapshot(nil); err == nil {
			out = append(out, snap)
		}
	}
	return out
}

func sleep(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}

// keyString is for logs and tests.
func (k Key) String() string {
	parts := []string{k.GVR.String(), k.Namespace}
	if k.LabelSelector != "" {
		parts = append(parts, "l="+k.LabelSelector)
	}
	if k.FieldSelector != "" {
		parts = append(parts, "f="+k.FieldSelector)
	}
	return strings.Join(parts, " ")
}
