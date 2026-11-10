package plugins

import (
	"slices"
	"strings"
	"sync"
	"time"
)

// Contribution kinds that are timed separately.
const (
	statColumn = "column"
	statPanel  = "panel"
	statAction = "action"
	statAlert  = "alert"
	// statBudget counts inspections where a "*" entry went over its
	// lookup budget.
	statBudget = "budget"
)

// stats records a plugin's evaluations: counts, errors, cost-limit hits
// and the most recent durations (for p50/p95/max on the Plugins page).
type stats struct {
	mu sync.Mutex
	by map[string]*bucket
}

const ringSize = 512

type bucket struct {
	count, errors, limitHits uint64
	ring                     [ringSize]time.Duration
	n                        int
	max                      time.Duration
}

// StatsOut is one contribution type's numbers (GET /api/plugins).
type StatsOut struct {
	Count     uint64  `json:"count"`
	Errors    uint64  `json:"errors"`
	LimitHits uint64  `json:"limitHits"`
	P50Micros float64 `json:"p50Us"`
	P95Micros float64 `json:"p95Us"`
	MaxMicros float64 `json:"maxUs"`
}

func newStats() *stats { return &stats{by: map[string]*bucket{}} }

func (s *stats) record(kind string, d time.Duration, err error) {
	if s == nil {
		return
	}
	s.mu.Lock()
	b := s.by[kind]
	if b == nil {
		b = &bucket{}
		s.by[kind] = b
	}
	b.count++
	b.ring[b.n%ringSize] = d
	b.n++
	if d > b.max {
		b.max = d
	}
	if err != nil {
		b.errors++
		if strings.Contains(err.Error(), "cost limit exceeded") || strings.Contains(err.Error(), "operation interrupted") {
			b.limitHits++
		}
	}
	s.mu.Unlock()
}

func (s *stats) snapshot() map[string]StatsOut {
	out := map[string]StatsOut{}
	if s == nil {
		return out
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, b := range s.by {
		n := min(b.n, ringSize)
		ds := slices.Clone(b.ring[:n])
		slices.Sort(ds)
		pct := func(p float64) float64 {
			if n == 0 {
				return 0
			}
			return float64(ds[min(n-1, int(p*float64(n)))].Nanoseconds()) / 1000
		}
		out[k] = StatsOut{Count: b.count, Errors: b.errors, LimitHits: b.limitHits, P50Micros: pct(0.5), P95Micros: pct(0.95), MaxMicros: float64(b.max.Nanoseconds()) / 1000}
	}
	return out
}
