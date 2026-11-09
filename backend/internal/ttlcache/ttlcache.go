// Package ttlcache is a keyed cache with separate lifetimes for good and
// failed loads, where concurrent misses share one load.
package ttlcache

import (
	"context"
	"sync"
	"time"
)

// Cache's zero value is ready to use. OK and Fail are how long a good and a
// failed result are served; Timeout (when positive) bounds each load.
type Cache[K comparable, V any] struct {
	OK, Fail, Timeout time.Duration

	mu      sync.Mutex
	entries map[K]entry[V]
	flights map[K]*flight[V]
}

type entry[V any] struct {
	v   V
	at  time.Time
	ttl time.Duration
}

type flight[V any] struct {
	done chan struct{}
	v    V
}

// Get returns the cached value for key, or runs load (ok reports whether it
// succeeded, which picks the TTL) when there is none, it has expired, or
// refresh is set. Concurrent callers for a key share one load. The load runs
// detached from ctx's cancellation so a cancelled caller doesn't poison the
// cache; a caller that stops waiting gets ctx's error.
func (c *Cache[K, V]) Get(ctx context.Context, key K, refresh bool, load func(context.Context) (V, bool)) (V, error) {
	c.mu.Lock()
	if e, ok := c.entries[key]; ok && !refresh && time.Since(e.at) < e.ttl {
		c.mu.Unlock()
		return e.v, nil
	}
	if f := c.flights[key]; f != nil {
		c.mu.Unlock()
		select {
		case <-f.done:
			return f.v, nil
		case <-ctx.Done():
			var zero V
			return zero, ctx.Err()
		}
	}
	f := &flight[V]{done: make(chan struct{})}
	if c.flights == nil {
		c.flights = map[K]*flight[V]{}
	}
	c.flights[key] = f
	c.mu.Unlock()

	lctx := context.WithoutCancel(ctx)
	if c.Timeout > 0 {
		var cancel context.CancelFunc
		lctx, cancel = context.WithTimeout(lctx, c.Timeout)
		defer cancel()
	}
	var ok, loaded bool
	defer func() { // also runs if load panics, so waiters never hang
		c.mu.Lock()
		if loaded {
			ttl := c.Fail
			if ok {
				ttl = c.OK
			}
			c.put(key, f.v, ttl)
		}
		delete(c.flights, key)
		c.mu.Unlock()
		close(f.done)
	}()
	f.v, ok = load(lctx)
	loaded = true
	return f.v, nil
}

func (c *Cache[K, V]) put(key K, v V, ttl time.Duration) {
	if c.entries == nil {
		c.entries = map[K]entry[V]{}
	}
	c.entries[key] = entry[V]{v: v, at: time.Now(), ttl: ttl}
}
