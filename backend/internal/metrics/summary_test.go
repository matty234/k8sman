package metrics

import (
	"context"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// mapGetter answers paths from a map; a missing path is a 404.
type mapGetter struct {
	mu   sync.Mutex
	body map[string]string
	err  map[string]error
	hits map[string]int
}

func (g *mapGetter) Get(_ context.Context, path string, _ url.Values) ([]byte, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.hits[path]++
	if err := g.err[path]; err != nil {
		return nil, err
	}
	if b, ok := g.body[path]; ok {
		return []byte(b), nil
	}
	return nil, apierrors.NewNotFound(schema.GroupResource{Resource: "nodes"}, path)
}

const node1Path = "/api/v1/nodes/node1/proxy/stats/summary"

func summaryFixture(t *testing.T) string {
	b, err := os.ReadFile("testdata/summary-node1.json")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestParseSummary(t *testing.T) {
	p, err := parseSummary("x", []byte(summaryFixture(t)))
	if err != nil {
		t.Fatal(err)
	}
	if p.node != "node1" || len(p.volumes) != 1 {
		t.Fatalf("node %q, volumes %+v", p.node, p.volumes)
	}
	v := p.volumes[0]
	if v.Namespace != "demo" || v.Claim != "data-redis-0" || v.Pod != "redis-0" || v.Node != "node1" || *v.UsedBytes != 966367642 || *v.CapacityBytes != 1073741824 || *v.InodesUsed != 536 {
		t.Fatalf("volume: %+v", v)
	}
	// Node: eth0 + eth1; lo, veth, tunnels and the VLAN eth0.20 excluded
	// (bond0 is idle, so the NICs count).
	if n := p.nodeNet; n == nil || n.rx != 34725685779+1000 || n.tx != 917021855+2000 {
		t.Fatalf("node net: %+v", n)
	}
	// No interface list: the default interface's counters.
	if w := p.podNet["demo/web-6fd47b8fcb-442dt"]; w.rx != 10000 || w.tx != 20000 {
		t.Fatalf("web net: %+v", w)
	}
}

func TestSummaryRatesFromTwoSamples(t *testing.T) {
	first := summaryFixture(t)
	// Ten seconds later redis received 10 kB and sent 20 kB; web's sample is unchanged.
	second := strings.NewReplacer("23:24:04Z", "23:24:14Z", "446000", "456000", "1776000", "1796000").Replace(first)
	g := &mapGetter{body: map[string]string{node1Path: first}, hits: map[string]int{}}
	s := New(g)
	now := time.Date(2026, 11, 3, 23, 25, 0, 0, time.UTC)
	s.now = func() time.Time { return now }

	sum := s.Summary(context.Background(), "demo", []string{"node1"})
	if sum.State != SummaryAvailable || sum.Reporting != 1 || len(sum.Volumes) != 1 || len(sum.Pods) != 2 {
		t.Fatalf("first: %+v", sum)
	}
	if sum.Pods[0].RxBytesPerSec != nil {
		t.Fatal("no rate from a single sample")
	}

	// Within the TTL: served from cache.
	s.Summary(context.Background(), "demo", []string{"node1"})
	if g.hits[node1Path] != 1 {
		t.Fatalf("want 1 kubelet fetch, got %d", g.hits[node1Path])
	}

	g.body[node1Path] = second
	now = now.Add(15 * time.Second)
	sum = s.Summary(context.Background(), "demo", []string{"node1"})
	redis := sum.Pods[0]
	if redis.Name != "redis-0" || redis.RxBytesPerSec == nil || *redis.RxBytesPerSec != 1000 || *redis.TxBytesPerSec != 2000 || redis.WindowSeconds != 10 {
		t.Fatalf("redis rate: %+v", redis)
	}
	if sum.Pods[1].RxBytesPerSec != nil {
		t.Fatalf("web had no newer sample: %+v", sum.Pods[1])
	}
	for _, p := range sum.Pods {
		if p.Namespace != "demo" {
			t.Fatalf("namespace filter: %+v", p)
		}
	}
	if len(sum.NodeNet) != 1 || sum.NodeNet[0].Name != "node1" {
		t.Fatalf("node net: %+v", sum.NodeNet)
	}
}

func TestSummaryFailsSoft(t *testing.T) {
	forbidden := apierrors.NewForbidden(schema.GroupResource{Resource: "nodes/proxy"}, "node1", nil)
	g := &mapGetter{
		body: map[string]string{"/api/v1/nodes": `{"items":[
			{"metadata":{"name":"node1"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
			{"metadata":{"name":"down"},"status":{"conditions":[{"type":"Ready","status":"Unknown"}]}}]}`},
		err:  map[string]error{node1Path: forbidden},
		hits: map[string]int{},
	}
	sum := New(g).Summary(context.Background(), "", nil)
	if sum.State != SummaryUnavailable || !strings.Contains(sum.Message, "nodes/proxy") || sum.Nodes != 1 {
		t.Fatalf("want unavailable for the one Ready node: %+v", sum)
	}
	if g.hits["/api/v1/nodes/down/proxy/stats/summary"] != 0 {
		t.Fatal("NotReady nodes are skipped")
	}
}

func TestVolumesMergesPrometheusAndKubelet(t *testing.T) {
	g := &mapGetter{body: map[string]string{
		"/api/v1/nodes": `{"items":[{"metadata":{"name":"node1"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}`,
		node1Path:       summaryFixture(t),
	}, hits: map[string]int{}}
	var mu sync.Mutex
	var queries []string
	// Prometheus has only demo/logs: no stats for data-redis-0, as on clusters
	// that scrape the kubelet but drop its volume stats.
	q := func(_ context.Context, query string) ([]PromSample, error) {
		mu.Lock()
		queries = append(queries, query)
		mu.Unlock()
		return []PromSample{{Metric: map[string]string{"namespace": "demo", "persistentvolumeclaim": "logs"}, Value: 42}}, nil
	}
	res := New(g).Volumes(context.Background(), "demo", q)
	if !res.Prometheus || res.Kubelet != SummaryAvailable || len(res.Items) != 2 {
		t.Fatalf("result: %+v", res)
	}
	if a, b := res.Items[0], res.Items[1]; a.Claim != "data-redis-0" || a.Source != SourceKubelet || *a.Used != 966367642 || b.Claim != "logs" || b.Source != SourcePrometheus {
		t.Fatalf("items: %+v %+v", a, b)
	}
	if len(queries) != 5 || !strings.Contains(queries[0], `{namespace="demo"}`) {
		t.Fatalf("queries: %v", queries)
	}

	// Prometheus has the claim: it wins.
	res = New(g).Volumes(context.Background(), "demo", func(context.Context, string) ([]PromSample, error) {
		return []PromSample{{Metric: map[string]string{"namespace": "demo", "persistentvolumeclaim": "data-redis-0"}, Value: 1}}, nil
	})
	if len(res.Items) != 1 || res.Items[0].Source != SourcePrometheus {
		t.Fatalf("prometheus should win: %+v", res.Items)
	}
	// No Prometheus at all: kubelet only.
	res = New(g).Volumes(context.Background(), "demo", nil)
	if res.Prometheus || len(res.Items) != 1 || res.Items[0].Source != SourceKubelet {
		t.Fatalf("kubelet only: %+v", res)
	}
}
