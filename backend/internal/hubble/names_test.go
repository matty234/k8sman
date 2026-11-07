package hubble

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestNamer(t *testing.T) {
	var calls atomic.Int32
	n := NewNamer()
	n.lookup = func(_ context.Context, ip string) ([]string, error) {
		calls.Add(1)
		if ip == "198.51.100.9" {
			return nil, errors.New("no such host")
		}
		return []string{"host.example.net."}, nil
	}
	for _, ip := range []string{"10.0.0.1", "100.64.1.1", "127.0.0.1", "169.254.1.1", "fd00::1"} {
		if n.Name(ip) != "" {
			t.Errorf("%s answered", ip)
		}
	}
	if n.Name("192.0.2.1") != "" {
		t.Fatal("first call must not wait on DNS")
	}
	n.Name("192.0.2.1")
	n.Name("198.51.100.9")
	var got string
	for i := 0; i < 100 && got == ""; i++ {
		time.Sleep(10 * time.Millisecond)
		got = n.Name("192.0.2.1")
	}
	if got != "host.example.net" {
		t.Fatalf("name = %q", got)
	}
	time.Sleep(50 * time.Millisecond)
	n.Name("198.51.100.9")
	if c := calls.Load(); c != 2 {
		t.Errorf("lookups = %d, want 2 (deduplicated, misses cached)", c)
	}

	peers := []string{"192.0.2.1", "203.0.113.5", "example.net", "10.0.0.1"}
	cl := map[string]string{"192.0.2.1": "svc/web/lb", "10.0.0.1": "node/n1"}
	names := ResolveNames(peers, cl, n, true)
	if names["192.0.2.1"] != (Name{"svc/web/lb", NameCluster}) || names["10.0.0.1"].Source != NameCluster || len(names) != 2 {
		t.Errorf("names = %v", names)
	}
	if got := ResolveNames([]string{"192.0.2.1"}, nil, n, false); got != nil {
		t.Errorf("rdns off: %v", got)
	}
}
