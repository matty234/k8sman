package hubble

import (
	"fmt"
	"testing"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"
	"google.golang.org/protobuf/types/known/wrapperspb"

	flowpb "github.com/matty234/k8sman/backend/internal/hubble/pb/flow"
)

// TestTraffic counts synthetic flows the way the relay sends them: each
// pod-to-pod packet traced at both nodes, with replies, world traffic both
// ways and drops; then rolls the windows forward until the counts age out,
// and checks the per-bucket limit.
func TestTraffic(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	tr := NewTraffic()
	tr.Now = func() time.Time { return now }
	tr.startedAt = now.Add(-time.Hour)

	pod := func(ns, name string) *flowpb.Endpoint {
		return &flowpb.Endpoint{Namespace: ns, PodName: name, Identity: 1000, Workloads: []*flowpb.Workload{{Kind: "Deployment", Name: name}}}
	}
	world := &flowpb.Endpoint{Identity: 2}
	tcp := func(port uint32) *flowpb.Layer4 {
		return &flowpb.Layer4{Protocol: &flowpb.Layer4_TCP{TCP: &flowpb.TCP{DestinationPort: port}}}
	}
	flow := func(src, dst *flowpb.Endpoint, point flowpb.TraceObservationPoint, reply bool, port uint32) *flowpb.Flow {
		return &flowpb.Flow{
			Time: timestamppb.New(now), Verdict: flowpb.Verdict_FORWARDED, Type: flowpb.FlowType_L3_L4,
			TraceObservationPoint: point, IsReply: wrapperspb.Bool(reply),
			Source: src, Destination: dst, L4: tcp(port), IP: &flowpb.IP{Source: "10.0.0.1", Destination: "10.0.0.2"},
		}
	}
	web, api := pod("web", "frontend"), pod("api", "orders")
	for range 10 {
		// Seen leaving web's node and reaching api's pod: counted once.
		tr.Add(flow(web, api, flowpb.TraceObservationPoint_TO_NETWORK, false, 8080))
		tr.Add(flow(web, api, flowpb.TraceObservationPoint_TO_ENDPOINT, false, 8080))
		// The reply and the socket-LB trace aren't counted.
		tr.Add(flow(api, web, flowpb.TraceObservationPoint_TO_ENDPOINT, true, 40000))
		tr.Add(&flowpb.Flow{Verdict: flowpb.Verdict_TRACED, Type: flowpb.FlowType_SOCK, Source: web, Destination: api})
	}
	for range 4 {
		out := flow(api, world, flowpb.TraceObservationPoint_TO_NETWORK, false, 443)
		out.IP.Destination = "203.0.113.7"
		out.DestinationNames = []string{"api.stripe.com"}
		tr.Add(out)
	}
	in := flow(world, web, flowpb.TraceObservationPoint_TO_ENDPOINT, false, 443)
	in.IP.Source = "198.51.100.4"
	tr.Add(in)
	tr.Add(&flowpb.Flow{
		Time: timestamppb.New(now), Verdict: flowpb.Verdict_DROPPED, DropReasonDesc: flowpb.DropReason_POLICY_DENIED,
		Type: flowpb.FlowType_L3_L4, Source: web, Destination: pod("payments", "ledger"), L4: tcp(5432),
	})

	edge := func(m TrafficMap, from, to string) TrafficEdge {
		t.Helper()
		for _, e := range m.Edges {
			if e.From == from && e.To == to {
				return e
			}
		}
		return TrafficEdge{}
	}
	m := tr.Snapshot(time.Minute)
	if m.Flows != 15 || m.Drops != 1 || len(m.Edges) != 4 {
		t.Fatalf("flows %d drops %d edges %d, want 15, 1, 4: %+v", m.Flows, m.Drops, len(m.Edges), m.Edges)
	}
	if e := edge(m, "web", "api"); e.Flows != 10 || len(e.Ports) != 1 || e.Ports[0] != (Count{"TCP/8080", 10}) ||
		e.FromWorkloads[0].Name != "Deployment/frontend" || e.ToWorkloads[0].Name != "Deployment/orders" {
		t.Errorf("web→api = %+v", e)
	}
	if e := edge(m, "api", NodeWorld); e.Flows != 4 || e.Peers[0] != (Count{"api.stripe.com", 4}) {
		t.Errorf("api→world = %+v", e)
	}
	if e := edge(m, NodeWorld, "web"); e.Flows != 1 || e.Peers[0].Name != "198.51.100.4" {
		t.Errorf("world→web = %+v", e)
	}
	if e := edge(m, "web", "payments"); e.Drops != 1 || e.Flows != 0 || e.Reasons[0].Name != "POLICY_DENIED" {
		t.Errorf("web→payments = %+v", e)
	}

	// Two minutes on, the 1m window is empty and the 5m one still has it
	// all; past 15 minutes the buckets are reused and it is gone.
	now = now.Add(2 * time.Minute)
	tr.Add(flow(web, api, flowpb.TraceObservationPoint_TO_ENDPOINT, false, 8080))
	if m := tr.Snapshot(time.Minute); m.Flows != 1 {
		t.Errorf("1m window after 2m: %d flows, want 1", m.Flows)
	}
	if m := tr.Snapshot(5 * time.Minute); m.Flows != 16 || edge(m, "web", "api").Flows != 11 {
		t.Errorf("5m window: %d flows, want 16", m.Flows)
	}
	now = now.Add(MaxTrafficWindow)
	tr.Add(flow(api, web, flowpb.TraceObservationPoint_TO_ENDPOINT, false, 80))
	if m := tr.Snapshot(MaxTrafficWindow); m.Flows != 1 || len(m.Edges) != 1 {
		t.Errorf("after 15m: %d flows in %d edges, want only the new one", m.Flows, len(m.Edges))
	}
	// A flow older than the ring isn't counted.
	old := flow(web, api, flowpb.TraceObservationPoint_TO_ENDPOINT, false, 8080)
	old.Time = timestamppb.New(now.Add(-time.Hour))
	tr.Add(old)
	if m := tr.Snapshot(MaxTrafficWindow); m.Flows != 1 {
		t.Errorf("old flow counted: %d", m.Flows)
	}

	// Bounded: one bucket keeps at most maxEdges pairs, and a pair at most
	// maxPeers world peers (the rest summed as other).
	now = now.Add(time.Hour)
	for i := range 50 {
		out := flow(api, world, flowpb.TraceObservationPoint_TO_NETWORK, false, 443)
		out.IP.Destination = fmt.Sprintf("192.0.2.%d", i)
		tr.Add(out)
	}
	for i := range maxEdges + 100 {
		tr.Add(flow(pod(fmt.Sprintf("ns%d", i), "a"), api, flowpb.TraceObservationPoint_TO_ENDPOINT, false, 80))
	}
	m = tr.Snapshot(time.Minute)
	if len(m.Edges) != maxEdges || m.Uncounted != 101 {
		t.Errorf("%d edges, %d uncounted; want %d and 101", len(m.Edges), m.Uncounted, maxEdges)
	}
	if e := edge(m, "api", NodeWorld); len(e.Peers) != maxPeers+1 || e.Peers[maxPeers] != (Count{"", 45}) {
		t.Errorf("api→world peers = %+v, want %d and 45 others", e.Peers, maxPeers)
	}
	var b *bucket
	for i := range tr.buckets {
		if len(tr.buckets[i].edges) > 0 {
			b = &tr.buckets[i]
		}
	}
	for k, e := range b.edges {
		if len(e.peers) > maxPeers || len(e.ports) > maxPorts {
			t.Errorf("%v keeps %d peers, %d ports", k, len(e.peers), len(e.ports))
		}
	}
}
