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
