package hubble

import (
	"context"
	"net"
	"net/url"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	flowpb "github.com/matty234/k8sman/backend/internal/hubble/pb/flow"
	observerpb "github.com/matty234/k8sman/backend/internal/hubble/pb/observer"
)

// fakeObserver records the request and sends n flows (every third
// DROPPED), one lost-events notice, then (when following) more flows than
// the rate cap lets through.
type fakeObserver struct {
	observerpb.UnimplementedObserverServer
	n   int
	got chan *observerpb.GetFlowsRequest
}

func (f *fakeObserver) GetFlows(req *observerpb.GetFlowsRequest, s observerpb.Observer_GetFlowsServer) error {
	f.got <- req
	send := func(i int) error {
		fl := &flowpb.Flow{
			Time: timestamppb.New(time.Unix(1700000000+int64(i), 0)), Verdict: flowpb.Verdict_FORWARDED,
			Source:      &flowpb.Endpoint{Namespace: "demo", PodName: "web-1", Identity: 1001},
			Destination: &flowpb.Endpoint{Namespace: "demo", PodName: "api-1", Identity: 1002},
			L4:          &flowpb.Layer4{Protocol: &flowpb.Layer4_TCP{TCP: &flowpb.TCP{SourcePort: 40000, DestinationPort: 8080}}},
		}
		if i%3 == 0 {
			fl.Verdict, fl.DropReasonDesc = flowpb.Verdict_DROPPED, flowpb.DropReason_POLICY_DENIED
		}
		return s.Send(&observerpb.GetFlowsResponse{ResponseTypes: &observerpb.GetFlowsResponse_Flow{Flow: fl}})
	}
	for i := range f.n {
		if err := send(i); err != nil {
			return err
		}
	}
	lost := &observerpb.GetFlowsResponse_LostEvents{LostEvents: &flowpb.LostEvent{NumEventsLost: 7}}
	if err := s.Send(&observerpb.GetFlowsResponse{ResponseTypes: lost}); err != nil {
		return err
	}
	if !req.GetFollow() {
		return nil
	}
	for i := range 50 { // a burst well over MaxRate
		if err := send(f.n + i); err != nil {
			return err
		}
	}
	<-s.Context().Done()
	return nil
}

func TestFiltersAndBatching(t *testing.T) {
	// Translation: a scope becomes "either side", narrowed by the rest.
	v, _ := url.ParseQuery("namespace=demo,shop&verdict=dropped&port=8080&direction=ingress&protocol=TCP&since=5m")
	q, err := ParseQuery(v)
	if err != nil {
		t.Fatal(err)
	}
	fs := q.Filters()
	if len(fs) != 2 {
		t.Fatalf("want a source and a destination filter, got %d", len(fs))
	}
	src, dst := fs[0], fs[1]
	if !equal(src.SourcePod, "demo/", "shop/") || len(src.DestinationPod) != 0 || !equal(dst.DestinationPod, "demo/", "shop/") || len(dst.SourcePod) != 0 {
		t.Errorf("scope: src %v / %v, dst %v / %v", src.SourcePod, src.DestinationPod, dst.SourcePod, dst.DestinationPod)
	}
	for _, f := range fs {
		if len(f.Verdict) != 1 || f.Verdict[0] != flowpb.Verdict_DROPPED || !equal(f.DestinationPort, "8080") ||
			!equal(f.Protocol, "tcp") || len(f.TrafficDirection) != 1 || f.TrafficDirection[0] != flowpb.TrafficDirection_INGRESS {
			t.Errorf("narrowing not applied to %v", f)
		}
	}
	v, _ = url.ParseQuery("from=demo/web&to=svc:demo/api")
	q, _ = ParseQuery(v)
	if fs := q.Filters(); len(fs) != 1 || !equal(fs[0].SourcePod, "demo/web") || !equal(fs[0].DestinationService, "demo/api") {
		t.Errorf("from/to: %v", fs)
	}
	for _, bad := range []string{"verdict=MAYBE", "port=http", "direction=up", "pod=web", "from=demo/web&namespace=demo", "to=nowhere"} {
		v, _ = url.ParseQuery(bad)
		if _, err := ParseQuery(v); err == nil {
			t.Errorf("%s: want an error", bad)
		}
	}

	// Batching against a fake relay.
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	fake := &fakeObserver{n: 10, got: make(chan *observerpb.GetFlowsRequest, 2)}
	observerpb.RegisterObserverServer(srv, fake)
	go func() { _ = srv.Serve(lis) }()
	defer srv.Stop()
	cc, err := grpc.NewClient("passthrough:///fake", grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }))
	if err != nil {
		t.Fatal(err)
	}
	defer cc.Close()
	client := observerpb.NewObserverClient(cc)
	defer func(b, r int, e time.Duration) { MaxBatch, MaxRate, FlushEvery = b, r, e }(MaxBatch, MaxRate, FlushEvery)
	MaxBatch, MaxRate, FlushEvery = 4, 1, 20*time.Millisecond

	// Finite: everything arrives, in frames of at most MaxBatch, then End.
	q = Query{Namespaces: []string{"demo"}, Verdicts: []string{"DROPPED", "FORWARDED"}, Last: 10}
	var frames []Frame
	if err := Stream(context.Background(), client, q.Request(time.Now()), func(f Frame) error { frames = append(frames, f); return nil }); err != nil {
		t.Fatal(err)
	}
	req := <-fake.got
	if !proto.Equal(&observerpb.GetFlowsRequest{Whitelist: req.Whitelist}, &observerpb.GetFlowsRequest{Whitelist: q.Filters()}) || req.GetNumber() != 10 || req.GetFieldMask() == nil {
		t.Errorf("relay got %v", req)
	}
	flows, lost, drops := 0, uint64(0), 0
	for _, f := range frames {
		if len(f.Flows) > MaxBatch {
			t.Errorf("frame of %d flows, cap %d", len(f.Flows), MaxBatch)
		}
		flows += len(f.Flows)
		lost += f.Lost
		for _, fl := range f.Flows {
			if fl.Verdict == "DROPPED" {
				drops++
				if fl.DropReason != "POLICY_DENIED" || fl.Source.Label() != "demo/web-1" || fl.Dest.Port != 8080 || fl.L4.Protocol != "TCP" {
					t.Errorf("drop converted as %+v", fl)
				}
			}
		}
	}
	if flows != 10 || drops != 4 || lost != 7 || !frames[len(frames)-1].End {
		t.Errorf("flows %d drops %d lost %d end %v", flows, drops, lost, frames[len(frames)-1].End)
	}

	// Following: the burst past the rate cap is counted as lost, not sent.
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	flows, lost = 0, 0
	q.Follow = true
	_ = Stream(ctx, client, q.Request(time.Now()), func(f Frame) error { flows += len(f.Flows); lost += f.Lost; return nil })
	<-fake.got
	if flows+int(lost) != 10+7+50 || flows > 10+2 {
		t.Errorf("following: %d flows passed, %d lost (want ~10 passed, the rest lost)", flows, lost)
	}
}

func equal(got []string, want ...string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}
