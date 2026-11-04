package metrics

import (
	"context"
	"math"
	"time"
)

// Per-row PVC usage for the PVC table ("Used" column): the same merged
// sources as Volumes (Prometheus' kubelet_volume_stats, else the kubelets'
// Summary API), cached per namespace so opening or refreshing a table never
// waits long on a slow cluster.

const (
	// claimUsageTTL is how long a snapshot is reused before refetching.
	claimUsageTTL = 20 * time.Second
	// claimUsageWait is the most a table build waits for a refetch; past
	// that it uses what it has and the live refresh fills in the rest.
	claimUsageWait = 1500 * time.Millisecond
	// claimUsageTimeout bounds one background fetch.
	claimUsageTimeout = 20 * time.Second
)

type cachedClaims struct {
	at       time.Time
	byClaim  map[string]ClaimUsage // "<namespace>/<claim>"
	inflight chan struct{}
}

// ClaimUsageDecorator merges `.k8sman.usage` into PersistentVolumeClaims:
// usedBytes, capacityBytes, availableBytes, percent (0–100, one decimal) and
// source ("prometheus" or "kubelet"). Claims without stats are left as is.
// query may be nil (no Prometheus). Returns nil when nothing is known yet.
func (s *Service) ClaimUsageDecorator(ctx context.Context, namespace string, query PromQuery) Decorator {
	by := s.claimUsage(ctx, namespace, query)
	if len(by) == 0 {
		return nil
	}
	return func(obj map[string]any) map[string]any {
		ns, _ := nested(obj, "metadata", "namespace").(string)
		name, _ := nested(obj, "metadata", "name").(string)
		u, ok := by[ns+"/"+name]
		if !ok || u.Used == nil {
			return obj
		}
		m := map[string]any{"usedBytes": *u.Used, "source": u.Source}
		if u.Capacity != nil {
			m["capacityBytes"] = *u.Capacity
			if *u.Capacity > 0 {
				m["percent"] = math.Round(*u.Used / *u.Capacity * 1000) / 10
			}
		}
		if u.Available != nil {
			m["availableBytes"] = *u.Available
		}
		return withUsage(obj, m)
	}
}

// claimUsage returns the namespace's snapshot, refetching in the background
// when stale and waiting at most claimUsageWait for it.
func (s *Service) claimUsage(ctx context.Context, namespace string, query PromQuery) map[string]ClaimUsage {
	s.mu.Lock()
	if s.claims == nil {
		s.claims = map[string]*cachedClaims{}
	}
	c := s.claims[namespace]
	if c == nil {
		c = &cachedClaims{}
		s.claims[namespace] = c
	}
	if !c.at.IsZero() && s.now().Sub(c.at) < claimUsageTTL {
		by := c.byClaim
		s.mu.Unlock()
		return by
	}
	done := c.inflight
	if done == nil {
		done = make(chan struct{})
		c.inflight = done
		go func() {
			fctx, cancel := context.WithTimeout(context.Background(), claimUsageTimeout)
			defer cancel()
			res := s.Volumes(fctx, namespace, query)
			by := make(map[string]ClaimUsage, len(res.Items))
			for _, u := range res.Items {
				by[u.Namespace+"/"+u.Claim] = u
			}
			s.mu.Lock()
			c.byClaim, c.at, c.inflight = by, s.now(), nil
			s.mu.Unlock()
			close(done)
		}()
	}
	s.mu.Unlock()

	select {
	case <-done:
	case <-time.After(claimUsageWait):
	case <-ctx.Done():
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return c.byClaim
}
