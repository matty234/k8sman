package server

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/gpu"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/prom"
)

// gpuCacheTTL bounds how often the GPU inventory hits Prometheus; node and
// pod lists come from the watch cache anyway.
const gpuCacheTTL = 10 * time.Second

// gpuModule is the NVIDIA GPU integration: the GPU inventory (/api/gpu),
// merged with DCGM exporter stats from Prometheus when there are any.
type gpuModule struct{ d Deps }

func (m *gpuModule) Name() string { return "gpus" }

func (m *gpuModule) Routes(r httpx.Router, d Deps) {
	m.d = d
	r.HandleFunc("GET /api/gpu", m.handleGPU)
}

type gpuCacheEntry struct {
	at  time.Time
	res *gpu.Result
}

var gpuCache = struct {
	sync.Mutex
	m map[string]gpuCacheEntry
}{m: map[string]gpuCacheEntry{}}

// handleGPU serves the GPU inventory. live=false skips Prometheus (for the
// nav's "does this cluster have GPUs" check).
func (m *gpuModule) handleGPU(w http.ResponseWriter, r *http.Request) {
	live := r.URL.Query().Get("live") != "false"
	c := m.d.Mgr.Clients()
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	res, err := gpuInventory(ctx, c, live, r.URL.Query().Get("refresh") == "true")
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, res)
}

func gpuInventory(ctx context.Context, c *cluster.Clients, live, refresh bool) (*gpu.Result, error) {
	key := c.Context
	if !live {
		key += "\x00static"
	}
	gpuCache.Lock()
	e, ok := gpuCache.m[key]
	gpuCache.Unlock()
	if ok && !refresh && time.Since(e.at) < gpuCacheTTL {
		return e.res, nil
	}

	kc := kcache.For(c)
	in := gpu.Input{Now: time.Now(), Monitoring: gpu.MonitoringSkipped}
	errs := map[string]string{}
	var err error
	if in.Nodes, err = listTyped[corev1.Node](ctx, kc, gvrNodes, "", ""); err != nil {
		return nil, err
	}
	if in.Pods, err = listTyped[corev1.Pod](ctx, kc, gvrPods, "", ""); err != nil {
		// Without pods there is no allocation, but capacity still shows.
		errs["pods"] = err.Error()
	}
	if live && hasGPUNodes(in.Nodes) {
		promGPU(ctx, c, &in, errs)
	}
	res := gpu.Build(in)
	if len(errs) > 0 {
		res.Errors = errs
	}
	gpuCache.Lock()
	gpuCache.m[key] = gpuCacheEntry{at: time.Now(), res: res}
	gpuCache.Unlock()
	return res, nil
}

func hasGPUNodes(nodes []corev1.Node) bool {
	for i := range nodes {
		for r, q := range nodes[i].Status.Capacity {
			if gpu.IsGPUResource(string(r)) && !q.IsZero() {
				return true
			}
		}
	}
	return false
}

// promGPU runs the DCGM queries in parallel. Failures are soft: they land
// in errs and the inventory is served without live stats.
func promGPU(ctx context.Context, c *cluster.Clients, in *gpu.Input, errs map[string]string) {
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	var (
		wg           sync.WaitGroup
		metrics, avg []prom.Sample
		inst         *prom.Instance
		mErr, aErr   error
	)
	wg.Add(2)
	go func() { defer wg.Done(); metrics, inst, mErr = prom.QueryVector(ctx, c, gpu.MetricsQuery()) }()
	go func() { defer wg.Done(); avg, _, aErr = prom.QueryVector(ctx, c, gpu.IdleQuery()) }()
	wg.Wait()
	if inst != nil {
		in.Prometheus = inst.ID
	}
	switch {
	case errors.Is(mErr, prom.ErrNoPrometheus):
		in.Monitoring = gpu.MonitoringNoPrometheus
		return
	case mErr != nil:
		in.Monitoring = gpu.MonitoringError
		errs["prometheus"] = mErr.Error()
		return
	}
	in.Monitoring = gpu.MonitoringDCGM // Build downgrades to noExporter when empty
	in.Metrics = metrics
	if aErr != nil {
		errs["idle"] = aErr.Error()
	} else {
		in.AvgUtil = avg
	}
}
