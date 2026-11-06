package hubble

import (
	"context"
	"errors"
	"io"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	observerpb "github.com/matty234/k8sman/backend/internal/hubble/pb/observer"
)

// Streaming tunables; tests shorten them.
var (
	// FlushEvery is how often pending flows go out as one frame.
	FlushEvery = 100 * time.Millisecond
	// MaxBatch caps the flows in one frame (a full batch goes out at once).
	MaxBatch = 500
	// MaxRate caps the flows per second a following stream passes on;
	// flows over it are counted in Frame.Lost instead. The initial "last N"
	// burst is allowed through.
	MaxRate = 1000
)

// Frame is one WebSocket frame on /api/hubble/flows.
type Frame struct {
	Flows []Flow `json:"flows,omitempty"`
	// Lost counts flows not delivered since the last frame: the relay's own
	// lost events (its ring buffer overflowed) plus flows over MaxRate.
	Lost uint64 `json:"lost,omitempty"`
	// End is set on the last frame of a stream that doesn't follow.
	End   bool   `json:"end,omitempty"`
	Error string `json:"error,omitempty"`
}

// Stream runs req against the relay and hands the flows to emit in
// batches until the stream ends, ctx is cancelled or emit fails.
func Stream(ctx context.Context, client observerpb.ObserverClient, req *observerpb.GetFlowsRequest, emit func(Frame) error) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stream, err := client.GetFlows(ctx, req)
	if err != nil {
		return err
	}
	type item struct {
		resp *observerpb.GetFlowsResponse
		err  error
	}
	in := make(chan item, MaxBatch)
	go func() {
		for {
			r, err := stream.Recv()
			select {
			case in <- item{r, err}:
			case <-ctx.Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()

	burst := float64(max(int(req.GetNumber()), MaxBatch))
	tokens, refilled := burst, time.Now()
	var pending []Flow
	var lost uint64
	flush := func(end bool) error {
		if len(pending) == 0 && lost == 0 && !end {
			return nil
		}
		f := Frame{Flows: pending, Lost: lost, End: end}
		pending, lost = nil, 0
		return emit(f)
	}
	tick := time.NewTicker(FlushEvery)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
			if err := flush(false); err != nil {
				return err
			}
		case it := <-in:
			if it.err != nil {
				if errors.Is(it.err, io.EOF) {
					return flush(true)
				}
				if status.Code(it.err) == codes.Canceled && ctx.Err() != nil {
					return nil
				}
				_ = flush(false)
				return it.err
			}
			switch r := it.resp.GetResponseTypes().(type) {
			case *observerpb.GetFlowsResponse_Flow:
				if req.GetFollow() {
					now := time.Now()
					tokens = min(burst, tokens+now.Sub(refilled).Seconds()*float64(MaxRate))
					refilled = now
					if tokens < 1 {
						lost++
						continue
					}
					tokens--
				}
				pending = append(pending, FromProto(r.Flow))
				if len(pending) >= MaxBatch {
					if err := flush(false); err != nil {
						return err
					}
				}
			case *observerpb.GetFlowsResponse_LostEvents:
				lost += r.LostEvents.GetNumEventsLost()
			}
		}
	}
}

// Collected is what a request that doesn't follow returned.
type Collected struct {
	Flows []Flow
	// Lost is what the relay reported lost.
	Lost uint64
	// Partial is true when ctx ran out first: Flows is what arrived.
	Partial bool
}

// Oldest is the time of the oldest flow (zero when none): on busy
// clusters the relay's buffers hold seconds, not minutes, so this is how
// far back the answer really goes.
func (c Collected) Oldest() time.Time {
	var t time.Time
	for _, f := range c.Flows {
		if t.IsZero() || f.Time.Before(t) {
			t = f.Time
		}
	}
	return t
}

// Collect runs a request that doesn't follow and returns its flows (at
// most limit). When ctx runs out after some flows arrived, they are
// returned as a partial result rather than an error.
func Collect(ctx context.Context, client observerpb.ObserverClient, req *observerpb.GetFlowsRequest, limit int) (Collected, error) {
	req.Follow = false
	var c Collected
	stream, err := client.GetFlows(ctx, req)
	if err != nil {
		return c, err
	}
	for {
		r, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return c, nil
		}
		if err != nil {
			if ctx.Err() != nil && len(c.Flows) > 0 {
				c.Partial = true
				return c, nil
			}
			return c, err
		}
		switch x := r.GetResponseTypes().(type) {
		case *observerpb.GetFlowsResponse_Flow:
			if len(c.Flows) < limit {
				c.Flows = append(c.Flows, FromProto(x.Flow))
			}
		case *observerpb.GetFlowsResponse_LostEvents:
			c.Lost += x.LostEvents.GetNumEventsLost()
		}
	}
}
