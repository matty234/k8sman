package kcache

import (
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
)

// Event is one change seen by a subscriber.
type Event struct {
	Type   watch.EventType // Added, Modified or Deleted
	Object *unstructured.Unstructured
}

// Update is what a subscriber should send next, in this order: an error, a
// fresh snapshot (replaces everything), or events.
type Update struct {
	// Err is a LIST failure. Terminal errors (Forbidden, NotFound) end the
	// stream; others are retried and followed by a snapshot on success.
	Err      error
	Terminal bool
	Snapshot *Snapshot
	Events   []Event
	// Partial lists namespaces of a namespace set that ended for good
	// (Forbidden, NotFound) while the others carry on (SubscribeSet only).
	Partial []NamespaceError
}

// NamespaceError is a terminal LIST error of one namespace in a set.
type NamespaceError struct {
	Namespace string
	Err       error
}

// Subscription is what a table watcher reads: a single stream (Sub) or a
// namespace set merged from several (MultiSub).
type Subscription interface {
	C() <-chan struct{}
	Next() Update
	Memo(u *unstructured.Unstructured, tag any, extra string, compute func() any) any
	Close()
}

// Sub is one subscriber of a stream. Its queue is bounded: a subscriber that
// falls more than maxPending events behind is sent a fresh snapshot instead,
// so a slow client can't make the backend buffer without limit.
type Sub struct {
	c      *Cache
	s      *stream
	filter *filter
	notify chan struct{}

	// guarded by s.mu
	pending  []Event
	resync   bool
	err      error
	terminal bool
	seen     map[string]bool // filtered subs: keys currently matching
	closed   bool
}

// Subscribe joins (or starts) the stream for key. A warm broader stream is
// reused with a local filter, e.g. the inspector's single-object watch rides
// on the table's watch of the same type. Call Close when done.
func (c *Cache) Subscribe(key Key) *Sub {
	s, f := c.acquire(key)
	return c.subscribeOn(s, f)
}

// subscribeOn joins stream s (one reference already held) through filter f.
func (c *Cache) subscribeOn(s *stream, f *filter) *Sub {
	sub := &Sub{c: c, s: s, filter: f, notify: make(chan struct{}, 1)}
	if f != nil {
		sub.seen = map[string]bool{}
	}
	s.mu.Lock()
	s.subs[sub] = struct{}{}
	switch {
	case s.synced:
		sub.resync = true
		sub.wake()
	case s.err != nil:
		sub.err, sub.terminal = s.err, s.terminal
		sub.wake()
	}
	s.mu.Unlock()
	return sub
}

// C is signalled when Next has something.
func (sub *Sub) C() <-chan struct{} { return sub.notify }

func (sub *Sub) wake() {
	select {
	case sub.notify <- struct{}{}:
	default:
	}
}

// push queues an event (caller holds s.mu).
func (sub *Sub) push(t watch.EventType, u *unstructured.Unstructured) {
	if sub.filter != nil {
		k := objKey(u)
		matches := t != watch.Deleted && sub.filter.match(u)
		was := sub.seen[k]
		switch {
		case matches:
			sub.seen[k] = true
			if !was {
				t = watch.Added
			}
		case was:
			// Deleted, or no longer matches the selector: like the API
			// server, report it as deleted.
			delete(sub.seen, k)
			t = watch.Deleted
		default:
			return
		}
	}
	if sub.resync || sub.closed {
		return // a snapshot is coming anyway
	}
	if len(sub.pending) >= sub.c.maxPending {
		sub.pending, sub.resync = nil, true
		sub.wake()
		return
	}
	sub.pending = append(sub.pending, Event{Type: t, Object: u})
	sub.wake()
}

// Next returns the pending update, or a zero Update if there is none.
func (sub *Sub) Next() Update {
	s := sub.s
	s.mu.Lock()
	defer s.mu.Unlock()
	if sub.err != nil {
		u := Update{Err: sub.err, Terminal: sub.terminal}
		sub.err = nil
		if s.synced || sub.resync {
			sub.wake() // the snapshot follows
		}
		return u
	}
	if sub.resync {
		sub.resync, sub.pending = false, nil
		if !s.synced {
			return Update{}
		}
		snap := s.snapshotLocked(sub.filter)
		if sub.seen != nil {
			clear(sub.seen)
			for _, u := range snap.Items {
				sub.seen[objKey(u)] = true
			}
		}
		return Update{Snapshot: &snap}
	}
	ev := sub.pending
	sub.pending = nil
	return Update{Events: ev}
}

// Close leaves the stream; the last subscriber starts its idle timer.
func (sub *Sub) Close() {
	s := sub.s
	s.mu.Lock()
	if sub.closed {
		s.mu.Unlock()
		return
	}
	sub.closed = true
	delete(s.subs, sub)
	sub.pending = nil
	s.mu.Unlock()
	sub.c.release(s)
}

// Memo returns a value derived from u (e.g. a rendered table row or a typed
// conversion), computing it only when u's resourceVersion or extra changed
// since the last call with the same tag. Values live as long as the object
// is in the stream.
func (sub *Sub) Memo(u *unstructured.Unstructured, tag any, extra string, compute func() any) any {
	return sub.s.memoGet(u, tag, extra, compute)
}

// Memo is Sub.Memo for snapshot readers.
func (snap Snapshot) Memo(u *unstructured.Unstructured, tag any, extra string, compute func() any) any {
	if snap.stream == nil {
		return compute()
	}
	return snap.stream.memoGet(u, tag, extra, compute)
}

type memoVal struct {
	version string
	v       any
}

// maxMemoTags bounds how many derived forms (column sets, conversions) are
// kept per object.
const maxMemoTags = 8

func (s *stream) memoGet(u *unstructured.Unstructured, tag any, extra string, compute func() any) any {
	uid := u.GetUID()
	version := u.GetResourceVersion() + "\x00" + extra
	s.mu.Lock()
	if mv, ok := s.memo[uid][tag]; ok && mv.version == version {
		s.mu.Unlock()
		return mv.v
	}
	s.mu.Unlock()
	v := compute()
	s.mu.Lock()
	defer s.mu.Unlock()
	// Only cache while the object is still current in the stream.
	if cur, ok := s.items[objKey(u)]; !ok || cur.GetUID() != uid {
		return v
	}
	if s.memo == nil {
		s.memo = map[types.UID]map[any]memoVal{}
	}
	m := s.memo[uid]
	if m == nil || len(m) >= maxMemoTags {
		m = map[any]memoVal{}
		s.memo[uid] = m
	}
	m[tag] = memoVal{version: version, v: v}
	return v
}

func (s *stream) forgetMemoLocked(u *unstructured.Unstructured) {
	delete(s.memo, u.GetUID())
}

// pruneMemoLocked drops memos of objects gone after a re-list.
func (s *stream) pruneMemoLocked() {
	if len(s.memo) == 0 {
		return
	}
	live := make(map[types.UID]bool, len(s.items))
	for _, u := range s.items {
		live[u.GetUID()] = true
	}
	for uid := range s.memo {
		if !live[uid] {
			delete(s.memo, uid)
		}
	}
}
