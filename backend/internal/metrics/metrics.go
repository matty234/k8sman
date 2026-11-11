// Package metrics reads the Kubernetes metrics APIs: resource metrics
// (metrics.k8s.io, served by metrics-server), custom metrics
// (custom.metrics.k8s.io, e.g. prometheus-adapter) and external metrics
// (external.metrics.k8s.io, e.g. KEDA). See docs/METRICS.md.
//
// Everything goes through one raw REST getter on the cluster's REST config, so
// the aggregated APIs need no generated clients and tests can fake every path
// with one httptest server.
package metrics

import (
	"context"
	"net/url"
	"sync"
	"time"

	"k8s.io/client-go/rest"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/kapi"
)

// API groups k8sman reads. Their versions, newest first, are in
// backend/internal/kapi.
var (
	ResourceGroup = kapi.ResourceMetrics.Name
	CustomGroup   = kapi.CustomMetrics.Name
	ExternalGroup = kapi.ExternalMetrics.Name
)

// Getter performs a GET on an absolute API path (e.g. /apis/metrics.k8s.io/v1/nodes).
// Errors for non-2xx responses are *apierrors.StatusError.
type Getter interface {
	Get(ctx context.Context, path string, params url.Values) ([]byte, error)
}

// RESTGetter adapts a rest.Interface (e.g. Clientset.Discovery().RESTClient()).
type RESTGetter struct{ RC rest.Interface }

// Get implements Getter.
func (g RESTGetter) Get(ctx context.Context, path string, params url.Values) ([]byte, error) {
	req := g.RC.Get().AbsPath(path)
	for k, vs := range params {
		for _, v := range vs {
			req = req.Param(k, v)
		}
	}
	return req.DoRaw(ctx)
}

// Service reads metrics for one cluster connection and caches short-lived
// snapshots so a table list and its re-evaluations share one fetch.
type Service struct {
	get Getter
	now func() time.Time

	// UsageTTL is how long a node/pod metrics snapshot is reused (~10s).
	UsageTTL time.Duration
	// StatusTTL is how long APIService availability is reused.
	StatusTTL time.Duration

	mu     sync.Mutex
	nodes  *cachedNodes
	pods   map[string]*cachedPods // by namespace, "" = all
	status *cachedStatus

	// kubelet holds per-node Summary API samples (see summary.go).
	kubelet *kubeletCache

	// claims holds per-namespace PVC usage snapshots (see claim_usage.go).
	claims map[string]*cachedClaims
}

type cachedNodes struct {
	at    time.Time
	items []NodeUsage
	err   error
}

type cachedPods struct {
	at    time.Time
	items []PodUsage
	err   error
}

type cachedStatus struct {
	at  time.Time
	val Status
	// resFallback: the newest metrics.k8s.io version answered NotFound,
	// use the oldest.
	resFallback bool
}

// New builds a Service over a Getter.
func New(g Getter) *Service {
	return &Service{get: g, now: time.Now, UsageTTL: 10 * time.Second, StatusTTL: 15 * time.Second, pods: map[string]*cachedPods{}}
}

var (
	registryMu sync.Mutex
	registry   = map[*cluster.Clients]*Service{}
)

// For returns the (cached) Service for a client snapshot. Each kube context
// has its own Clients, so caches never mix clusters.
func For(c *cluster.Clients) *Service {
	registryMu.Lock()
	defer registryMu.Unlock()
	if s, ok := registry[c]; ok {
		return s
	}
	s := New(RESTGetter{RC: c.Typed.Discovery().RESTClient()})
	registry[c] = s
	return s
}
