package ttlcache

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCache(t *testing.T) {
	c := Cache[string, int]{OK: time.Hour, Fail: 30 * time.Millisecond}
	var n atomic.Int32
	ok := true
	load := func(context.Context) (int, bool) {
		time.Sleep(20 * time.Millisecond)
		return int(n.Add(1)), ok
	}
	ctx := context.Background()

	// Concurrent misses share one load; a later call hits.
	var wg sync.WaitGroup
	for range 5 {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = c.Get(ctx, "a", false, load) }()
	}
	wg.Wait()
	if v, _ := c.Get(ctx, "a", false, load); v != 1 || n.Load() != 1 {
		t.Fatalf("want one shared load, got v=%d loads=%d", v, n.Load())
	}
	// refresh bypasses the cache.
	if v, _ := c.Get(ctx, "a", true, load); v != 2 {
		t.Fatalf("refresh: got %d", v)
	}
	// A failure is cached only for the fail TTL.
	ok = false
	_, _ = c.Get(ctx, "b", false, load)
	if v, _ := c.Get(ctx, "b", false, load); v != 3 {
		t.Fatalf("failure should be cached, got %d", v)
	}
	time.Sleep(40 * time.Millisecond)
	if v, _ := c.Get(ctx, "b", false, load); v != 4 {
		t.Fatalf("failure should expire, got %d", v)
	}
}
