package prom

import (
	"context"
	"encoding/json"
	"net/url"
	"time"

	"github.com/matty234/k8sman/backend/internal/ttlcache"
)

// Prometheus and Alertmanager answers the inspector asks for on every
// object it opens (targets, rules, alerts) are cached briefly per kube
// context and instance: opening ten pods in a row costs one /api/v1/targets.
var (
	targetsCache = ttlcache.Cache[string, loaded[[]promTarget]]{OK: 15 * time.Second, Fail: 5 * time.Second, Timeout: readTimeout}
	droppedCache = ttlcache.Cache[string, loaded[[]promTarget]]{OK: 30 * time.Second, Fail: 10 * time.Second, Timeout: readTimeout}
	rulesCache   = ttlcache.Cache[string, loaded[[]RuleGroup]]{OK: 15 * time.Second, Fail: 5 * time.Second, Timeout: readTimeout}
	alertsCache  = ttlcache.Cache[string, loaded[*AlertsResult]]{OK: 10 * time.Second, Fail: 5 * time.Second, Timeout: readTimeout}
	amCfgCache   = ttlcache.Cache[string, loaded[*AMStatus]]{OK: 30 * time.Second, Fail: 10 * time.Second, Timeout: readTimeout}
)

// loaded is a cached answer: the value or the error that came instead.
type loaded[V any] struct {
	v   V
	err error
}

// cacheKey scopes a cached answer to the kube context (with its settings)
// and the instance.
func cacheKey(e env, in *Instance, what string) string {
	return e.key + "|" + in.Kind + "|" + in.ID + "|" + what
}

// cachedResult runs load through c, returning its error too. A failed load
// is cached for c.Fail, so a broken instance isn't hammered.
func cachedResult[V any](ctx context.Context, c *ttlcache.Cache[string, loaded[V]], key string, load func(context.Context) (V, error)) (V, error) {
	r, err := c.Get(ctx, key, false, func(ctx context.Context) (loaded[V], bool) {
		v, err := load(ctx)
		return loaded[V]{v, err}, err == nil
	})
	if err != nil {
		var zero V
		return zero, err
	}
	return r.v, r.err
}

// cachedTargets is fetchTargets (active targets), cached.
func cachedTargets(ctx context.Context, e env, p *Instance) ([]promTarget, error) {
	return cachedResult(ctx, &targetsCache, cacheKey(e, p, "targets"), func(ctx context.Context) ([]promTarget, error) {
		return fetchTargets(ctx, e.req, p)
	})
}

// cachedDropped returns the targets service discovery found and relabelling
// dropped. They say why a pod that Prometheus sees isn't scraped.
func cachedDropped(ctx context.Context, e env, p *Instance) ([]promTarget, error) {
	return cachedResult(ctx, &droppedCache, cacheKey(e, p, "dropped"), func(ctx context.Context) ([]promTarget, error) {
		data, _, err := promGet(ctx, e.req, p, "/api/v1/targets", url.Values{"state": {"dropped"}})
		if err != nil {
			return nil, err
		}
		var d struct {
			DroppedTargets []promTarget `json:"droppedTargets"`
		}
		if err := json.Unmarshal(data, &d); err != nil {
			return nil, &UpstreamError{Status: 502, Message: "decode prometheus targets: " + err.Error()}
		}
		return d.DroppedTargets, nil
	})
}

// cachedRules is fetchRules mapped to PrometheusRules, cached.
func cachedRules(ctx context.Context, e env, p *Instance) ([]RuleGroup, error) {
	return cachedResult(ctx, &rulesCache, cacheKey(e, p, "rules"), func(ctx context.Context) ([]RuleGroup, error) {
		groups, err := fetchRules(ctx, e.req, p)
		if err != nil {
			return nil, err
		}
		refs, _ := listPrometheusRules(ctx, e.dyn, "")
		MapRuleSources(groups, refs)
		return groups, nil
	})
}
