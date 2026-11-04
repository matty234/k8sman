package metrics

import (
	"context"
	"testing"
)

func TestClaimUsageDecorator(t *testing.T) {
	g := &mapGetter{body: map[string]string{
		"/api/v1/nodes": `{"items":[{"metadata":{"name":"node1"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}`,
		node1Path:       summaryFixture(t),
	}, hits: map[string]int{}}
	svc := New(g)
	dec := svc.ClaimUsageDecorator(context.Background(), "demo", nil)
	if dec == nil {
		t.Fatal("no decorator although the kubelet reports demo/data-redis-0")
	}
	pvc := func(name string) map[string]any {
		return map[string]any{"metadata": map[string]any{"namespace": "demo", "name": name}}
	}
	usage, _ := nested(dec(pvc("data-redis-0")), UsageKey, "usage").(map[string]any)
	if usage["usedBytes"] != 966367642.0 || usage["source"] != SourceKubelet {
		t.Fatalf("usage: %v", usage)
	}
	if p, ok := usage["percent"].(float64); !ok || p <= 0 || p > 100 {
		t.Fatalf("percent: %v", usage["percent"])
	}
	if got := dec(pvc("unknown")); nested(got, UsageKey) != nil {
		t.Fatalf("a claim without stats should be untouched: %v", got)
	}

	// Within the TTL a second table build reuses the snapshot.
	hits := g.hits[node1Path]
	svc.ClaimUsageDecorator(context.Background(), "demo", nil)
	if g.hits[node1Path] != hits {
		t.Fatal("refetched within the TTL")
	}
}
