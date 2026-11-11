package kcache

import (
	"sort"
	"sync"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/watch"
)

// SubscribeSet watches key's resource in a set of namespaces. key.Namespace
// is ignored; an empty set means all namespaces and one namespace is a plain
// Subscribe.
//
// When a warm all-namespaces stream of the resource exists, the set is one
// filtered subscriber on it: no extra upstream requests and no merging.
// Otherwise every namespace gets its own stream (the same key a
// one-namespace table uses, so they share), merged by a MultiSub. That is
// what lets a user with only namespaced RoleBindings watch several
// namespaces at once.
func (c *Cache) SubscribeSet(key Key, namespaces []string) Subscription {
	key = key.norm()
	switch len(namespaces) {
	case 0:
		key.Namespace = ""
		return c.Subscribe(key)
	case 1:
		key.Namespace = namespaces[0]
		return c.Subscribe(key)
	}
	if s, f := c.acquireWarmSet(key, namespaces); s != nil {
		return c.subscribeOn(s, f)
	}
	m := &MultiSub{
		subs:   map[string]*Sub{},
		order:  append([]string(nil), namespaces...),
		notify: make(chan struct{}, 1),
		done:   make(chan struct{}),
		items:  map[string]map[string]*unstructured.Unstructured{},
		ready:  map[string]bool{},
		dead:   map[string]bool{},
	}
	sort.Strings(m.order)
	for _, ns := range m.order {
		k := key
		k.Namespace = ns
		sub := c.Subscribe(k)
		m.subs[ns] = sub
		m.wg.Add(1)
		go func() {
			defer m.wg.Done()
			for {
				select {
				case <-m.done:
					return
				case <-sub.C():
					m.wake()
				}
			}
		}()
	}
	return m
}

// setFilter turns broad (an all-namespaces key) into key restricted to
// namespaces, or false when broad can't answer it.
func setFilter(broad, key Key, namespaces []string) (*filter, bool) {
	want := key
	want.Namespace = ""
	f, ok := narrowing(broad, want)
	if !ok {
		return nil, false
	}
	if f == nil {
		f = &filter{}
	}
	f.nsSet = make(map[string]bool, len(namespaces))
	for _, ns := range namespaces {
		f.nsSet[ns] = true
	}
	return f, true
}

// warmSetLocked finds a synced all-namespaces stream that can answer key in
// a namespace set.
func (c *Cache) warmSetLocked(key Key, namespaces []string) (*stream, *filter) {
	for _, bk := range []Key{{GVR: key.GVR, LabelSelector: key.LabelSelector, FieldSelector: key.FieldSelector, Lean: key.Lean}, {GVR: key.GVR}, {GVR: key.GVR, Lean: true}} {
		if s := c.streams[bk]; s != nil && s.isWarm() {
			if f, ok := setFilter(bk, key, namespaces); ok {
				return s, f
			}
		}
	}
	return nil, nil
}

// acquireWarmSet is acquire for a namespace set: only a warm stream counts.
func (c *Cache) acquireWarmSet(key Key, namespaces []string) (*stream, *filter) {
	c.mu.Lock()
	defer c.mu.Unlock()
	s, f := c.warmSetLocked(key, namespaces)
	if s == nil {
		return nil, nil
	}
	s.refs++
	if s.idleTimer != nil {
		s.idleTimer.Stop()
		s.idleTimer = nil
	}
	return s, f
}

// CachedSet answers a namespace set from a warm all-namespaces stream, or
// returns ok=false (the caller then reads each namespace).
func (c *Cache) CachedSet(key Key, namespaces []string) (Snapshot, bool) {
	key = key.norm()
	c.mu.Lock()
	s, f := c.warmSetLocked(key, namespaces)
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

// MultiSub merges one subscriber per namespace into one table:
//
//   - the first snapshot waits until every namespace has listed or failed
//     for good, so a table doesn't fill in one namespace at a time;
//   - a namespace that re-lists (410 Gone, a slow subscriber) produces a
//     fresh merged snapshot;
//   - a namespace that fails for good (Forbidden, NotFound) is reported in
//     Update.Partial and the others carry on; only when every namespace has
//     failed does the update end the stream (Err, Terminal).
//
// Next must be called from one goroutine (like Sub.Next).
type MultiSub struct {
	subs   map[string]*Sub
	order  []string
	notify chan struct{}
	done   chan struct{}
	wg     sync.WaitGroup
	once   sync.Once

	// merge state, owned by the Next caller
	items     map[string]map[string]*unstructured.Unstructured // namespace → objKey → object
	ready     map[string]bool                                  // listed, or failed for good
	dead      map[string]bool                                  // failed for good
	firstErr  error
	sent      bool // the first merged snapshot went out
	resnap    bool // a merged snapshot is due
	events    []Event
	partial   []NamespaceError
	transient error
}

// C is signalled when Next may have something.
func (m *MultiSub) C() <-chan struct{} { return m.notify }

func (m *MultiSub) wake() {
	select {
	case m.notify <- struct{}{}:
	default:
	}
}

// Memo caches derived values on the stream the object came from.
func (m *MultiSub) Memo(u *unstructured.Unstructured, tag any, extra string, compute func() any) any {
	if sub := m.subs[u.GetNamespace()]; sub != nil {
		return sub.Memo(u, tag, extra, compute)
	}
	return compute()
}

// Close leaves every namespace's stream.
func (m *MultiSub) Close() {
	m.once.Do(func() {
		close(m.done)
		m.wg.Wait()
		for _, sub := range m.subs {
			sub.Close()
		}
	})
}

// Next drains every namespace and returns what to send, in the same order
// as Sub.Next: an error, then a snapshot or events.
func (m *MultiSub) Next() Update {
	for _, ns := range m.order {
		if !m.dead[ns] {
			m.drain(ns)
		}
	}
	if len(m.dead) == len(m.order) {
		// Every namespace failed for good: the table fails like a plain one.
		m.partial, m.events = nil, nil
		return Update{Err: m.firstErr, Terminal: true}
	}
	out := Update{Partial: m.partial}
	m.partial = nil
	if err := m.transient; err != nil {
		m.transient = nil
		out.Err = err
		if m.resnap || len(m.events) > 0 {
			m.wake() // the data follows, as with Sub
		}
		return out
	}
	if !m.allReady() {
		return out
	}
	if m.resnap || !m.sent {
		m.resnap, m.sent, m.events = false, true, nil
		snap := m.merged()
		out.Snapshot = &snap
		return out
	}
	out.Events, m.events = m.events, nil
	return out
}

// drain applies one namespace's pending update to the merge state.
func (m *MultiSub) drain(ns string) {
	u := m.subs[ns].Next()
	switch {
	case u.Err != nil && u.Terminal:
		if m.firstErr == nil {
			m.firstErr = u.Err
		}
		m.dead[ns], m.ready[ns] = true, true
		if len(m.items[ns]) > 0 {
			m.resnap = true
		}
		delete(m.items, ns)
		m.partial = append(m.partial, NamespaceError{Namespace: ns, Err: u.Err})
		return
	case u.Err != nil:
		m.transient = u.Err
	case u.Snapshot != nil:
		byKey := make(map[string]*unstructured.Unstructured, len(u.Snapshot.Items))
		for _, it := range u.Snapshot.Items {
			byKey[objKey(it)] = it
		}
		m.items[ns] = byKey
		m.ready[ns] = true
		m.resnap = true
	}
	if len(u.Events) == 0 {
		return
	}
	byKey := m.items[ns]
	if byKey == nil {
		byKey = map[string]*unstructured.Unstructured{}
		m.items[ns] = byKey
	}
	for _, ev := range u.Events {
		if ev.Type == watch.Deleted {
			delete(byKey, objKey(ev.Object))
		} else {
			byKey[objKey(ev.Object)] = ev.Object
		}
	}
	// Before the first snapshot, or with a snapshot due, the events are
	// already part of what will be sent.
	if m.sent && !m.resnap {
		m.events = append(m.events, u.Events...)
	}
}

func (m *MultiSub) allReady() bool {
	for _, ns := range m.order {
		if !m.ready[ns] {
			return false
		}
	}
	return true
}

// merged is every live namespace's objects in namespace/name order.
func (m *MultiSub) merged() Snapshot {
	n := 0
	for _, byKey := range m.items {
		n += len(byKey)
	}
	keys := make([]string, 0, n)
	all := make(map[string]*unstructured.Unstructured, n)
	for _, byKey := range m.items {
		for k, u := range byKey {
			keys = append(keys, k)
			all[k] = u
		}
	}
	sort.Strings(keys)
	items := make([]*unstructured.Unstructured, len(keys))
	for i, k := range keys {
		items[i] = all[k]
	}
	return Snapshot{Items: items}
}
