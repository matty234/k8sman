package hubble

import (
	"context"
	"errors"
	"sort"
	"strconv"
	"sync"
	"time"

	"google.golang.org/protobuf/types/known/fieldmaskpb"

	flowpb "github.com/matty234/k8sman/backend/internal/hubble/pb/flow"
	observerpb "github.com/matty234/k8sman/backend/internal/hubble/pb/observer"
)

// The traffic map: which namespaces talk to each other and to the world,
// counted from the relay's live flows over rolling windows (the relay's
// own buffer holds seconds on a busy cluster, so history has to be kept
// here). One Traffic per kube context runs while someone looks at the map.
//
// Each flow is counted once. The relay sends only what can be counted
// (trafficFilters): a pod-to-pod packet is traced both where it leaves the
// source node (to-network/to-overlay) and where it reaches the destination
// pod (to-endpoint), and replies, socket-LB traces and policy-verdict
// events repeat a connection that was already seen. Add applies the same
// rule again, so a relay that ignores a filter can't double-count.
//
// Memory is bounded: TrafficBuckets() buckets of TrafficBucket each, at
// most maxEdges namespace pairs per bucket, and a few top entries per pair
// for ports, world peers, workloads and drop reasons, with their strings
// shared. At worst about 16 MB (46 buckets × 512 pairs × ~670 bytes); a
// cluster with 30 namespaces and ~180 pairs used about 3 MB.

var (
	// TrafficBucket is the counting resolution.
	TrafficBucket = 20 * time.Second
	// TrafficIdle stops a map nobody asked for in this long.
	TrafficIdle = time.Minute
)

const (
	// MaxTrafficWindow is the longest window a snapshot covers.
	MaxTrafficWindow = 15 * time.Minute
	// maxEdges caps the namespace pairs one bucket keeps; flows of pairs
	// over it are counted in Uncounted.
	maxEdges = 512
	// Per pair and bucket: top ports and world peers, workloads on each
	// side, and drop reasons. Beyond these, the rest are summed as
	// "other" in the snapshot.
	maxPorts, maxPeers, maxWorkloads, maxReasons = 5, 5, 3, 3
	// maxInterned caps the shared-string table (reset when full).
	maxInterned = 8192
	// snapshotTop is how many entries each detail list has in a snapshot.
	snapshotTop = 5
)

// TrafficBuckets is how many buckets the ring holds: the longest window
// plus the one being filled.
func TrafficBuckets() int { return int(MaxTrafficWindow/TrafficBucket) + 1 }

// Node ids for endpoints that aren't in a namespace. Namespaces can't
// contain ':', so these never collide with one.
const (
	NodeWorld         = "reserved:world"
	NodeHost          = "reserved:host"
	NodeRemoteNode    = "reserved:remote-node"
	NodeKubeAPIServer = "reserved:kube-apiserver"
	NodeIngress       = "reserved:ingress"
	NodeHealth        = "reserved:health"
	NodeInit          = "reserved:init"
	NodeUnmanaged     = "reserved:unmanaged"
	// NodeUnknown is a cluster identity with no namespace in the flow
	// (e.g. a pod that already went away, or one in another cluster).
	NodeUnknown = "reserved:unknown"
)

// firstLocalIdentity is where Cilium's node-local identities start: CIDR
// and FQDN selections of addresses outside the cluster.
const firstLocalIdentity = 1 << 24

// NodeOf names the map node of one side of a flow: its namespace, or a
// reserved:… id.
func NodeOf(e *flowpb.Endpoint) string {
	if ns := e.GetNamespace(); ns != "" {
		return ns
	}
	switch id := e.GetIdentity(); {
	case id == 2 || id == 9 || id == 10 || id >= firstLocalIdentity:
		return NodeWorld
	case id == 1:
		return NodeHost
	case id == 3:
		return NodeUnmanaged
	case id == 4:
		return NodeHealth
	case id == 5:
		return NodeInit
	case id == 6:
		return NodeRemoteNode
	case id == 7:
		return NodeKubeAPIServer
	case id == 8:
		return NodeIngress
	}
	return NodeUnknown
}

// TrafficMap is the GET /api/hubble/map payload.
type TrafficMap struct {
	// Window is what was asked for; Since is where the counts really
	// start (later than now-Window while the map is younger than that).
	Window    string    `json:"window"`
	Since     time.Time `json:"since"`
	Now       time.Time `json:"now"`
	StartedAt time.Time `json:"startedAt"`
	// Flows and Drops are totals over the window. Rate is counted flows
	// per second lately (the last bucket and the current one).
	Flows uint64  `json:"flows"`
	Drops uint64  `json:"drops"`
	Rate  float64 `json:"rate"`
	// Lost is what the relay reported it couldn't send (its buffers
	// overflowed): the counts are then a lower bound. Uncounted is flows
	// of pairs over the per-bucket limit.
	Lost      uint64 `json:"lost,omitempty"`
	Uncounted uint64 `json:"uncounted,omitempty"`
	// State is starting (no flows yet), live, or error (reconnecting;
	// Error says why). Counts so far are kept across reconnects.
	State string        `json:"state"`
	Error string        `json:"error,omitempty"`
	Edges []TrafficEdge `json:"edges"`
	// Names labels the IP peers on the edges: a cluster object owning the
	// address, else its reverse DNS name once looked up. Only IPs in Edges.
	Names map[string]Name `json:"names,omitempty"`
}

// TrafficEdge is the traffic from one node to another (From == To for
// traffic within a namespace).
type TrafficEdge struct {
	From  string `json:"from"`
	To    string `json:"to"`
	Flows uint64 `json:"flows"`
	Drops uint64 `json:"drops"`
	// Rate is flows per second lately (0 when the pair went quiet).
	Rate float64 `json:"rate,omitempty"`
	// Ports are destination ports as PROTO/port (ICMP as just the
	// protocol); Peers are the world addresses (a DNS name Hubble knew,
	// else the IP) on world edges.
	Ports         []Count `json:"ports,omitempty"`
	Peers         []Count `json:"peers,omitempty"`
	FromWorkloads []Count `json:"fromWorkloads,omitempty"`
	ToWorkloads   []Count `json:"toWorkloads,omitempty"`
	Reasons       []Count `json:"reasons,omitempty"`
}

// Count is one entry of a top list. Name "" sums the entries that didn't
// make the list (or weren't kept).
type Count struct {
	Name string `json:"name"`
	N    uint64 `json:"n"`
}

type edgeKey struct{ from, to string }

// tally is a small top list kept as a slice: linear search over a handful
// of entries beats a map, and the cap bounds it.
type tally struct {
	name string
	n    uint32
}

type tallies []tally

// add counts name, or reports false when the list is full without it.
func (t *tallies) add(name string, limit int) bool {
	for i := range *t {
		if (*t)[i].name == name {
			(*t)[i].n++
			return true
		}
	}
	if len(*t) >= limit {
		return false
	}
	*t = append(*t, tally{name, 1})
	return true
}

type edgeBucket struct {
	flows, drops                        uint32
	ports, peers, fromWl, toWl, reasons tallies
	// Flows whose port, peer, workload or reason didn't fit its list.
	otherPorts, otherPeers, otherFrom, otherTo, otherReasons uint32
}

type bucket struct {
	epoch     int64 // start / TrafficBucket; 0 = unused
	edges     map[edgeKey]*edgeBucket
	lost      uint64
	uncounted uint64
}

// Traffic counts flows into the ring. Safe for concurrent use.
type Traffic struct {
	mu        sync.Mutex
	buckets   []bucket
	strs      map[string]string
	startedAt time.Time
	state     string
	err       string
	lastUsed  time.Time
	stop      context.CancelFunc
	done      chan struct{}

	// Now is the clock (tests set it).
	Now func() time.Time
}

// NewTraffic returns an empty map (not following anything yet: see Run).
func NewTraffic() *Traffic {
	t := &Traffic{buckets: make([]bucket, TrafficBuckets()), strs: map[string]string{}, state: "starting", Now: time.Now}
	t.startedAt = t.Now()
	t.lastUsed = t.startedAt
	return t
}

func (t *Traffic) epoch(at time.Time) int64 { return at.UnixNano() / int64(TrafficBucket) }

// intern shares the strings the buckets keep (namespace, port, workload
// and peer names repeat across buckets).
func (t *Traffic) intern(s string) string {
	if v, ok := t.strs[s]; ok {
		return v
	}
	if len(t.strs) >= maxInterned {
		clear(t.strs) // still bounded: the buckets' own caps hold
	}
	t.strs[s] = s
	return s
}

// countable says whether f is counted, and whether as a drop.
func countable(f *flowpb.Flow) (ok, drop bool) {
	switch f.GetVerdict() {
	case flowpb.Verdict_DROPPED:
		return true, true
	case flowpb.Verdict_FORWARDED, flowpb.Verdict_AUDIT:
	default:
		return false, false
	}
	if f.GetIsReply().GetValue() || f.GetType() != flowpb.FlowType_L3_L4 {
		return false, false
	}
	switch f.GetTraceObservationPoint() {
	case flowpb.TraceObservationPoint_TO_ENDPOINT:
		return true, false
	case flowpb.TraceObservationPoint_TO_NETWORK, flowpb.TraceObservationPoint_TO_OVERLAY,
		flowpb.TraceObservationPoint_TO_STACK, flowpb.TraceObservationPoint_TO_HOST:
		// Leaving the node: counted here only when no pod receives it
		// (a pod would be counted at its to-endpoint trace).
		return f.GetDestination().GetPodName() == "", false
	}
	return false, false
}

// Add counts one flow (ignoring those that aren't counted, see countable).
func (t *Traffic) Add(f *flowpb.Flow) {
	ok, drop := countable(f)
	if !ok {
		return
	}
	now := t.Now()
	at := now
	if ts := f.GetTime(); ts != nil {
		if ft := ts.AsTime(); ft.Before(now) {
			at = ft
		}
	}
	from, to := NodeOf(f.GetSource()), NodeOf(f.GetDestination())
	proto, port := l4Of(f.GetL4())
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.state == "starting" {
		t.state = "live"
	}
	b := t.bucketAt(at, now)
	if b == nil {
		return // older than the ring
	}
	k := edgeKey{t.intern(from), t.intern(to)}
	e := b.edges[k]
	if e == nil {
		if len(b.edges) >= maxEdges {
			b.uncounted++
			return
		}
		e = &edgeBucket{}
		b.edges[k] = e
	}
	if drop {
		e.drops++
		r := f.GetDropReasonDesc().String()
		if f.GetDropReasonDesc() == flowpb.DropReason_DROP_REASON_UNKNOWN {
			r = ""
		}
		if !e.reasons.add(t.intern(r), maxReasons) {
			e.otherReasons++
		}
	} else {
		e.flows++
	}
	if proto != "" {
		name := proto
		if port > 0 {
			name += "/" + strconv.FormatUint(uint64(port), 10)
		}
		if !e.ports.add(t.intern(name), maxPorts) {
			e.otherPorts++
		}
	}
	var peer string
	switch {
	case to == NodeWorld:
		peer = peerName(f.GetDestinationNames(), f.GetIP().GetDestination())
	case from == NodeWorld:
		peer = peerName(f.GetSourceNames(), f.GetIP().GetSource())
	}
	if peer != "" && !e.peers.add(t.intern(peer), maxPeers) {
		e.otherPeers++
	}
	if w := workloadOf(f.GetSource()); w != "" && !e.fromWl.add(t.intern(w), maxWorkloads) {
		e.otherFrom++
	}
	if w := workloadOf(f.GetDestination()); w != "" && !e.toWl.add(t.intern(w), maxWorkloads) {
		e.otherTo++
	}
}

// AddLost counts flows the relay reported lost.
func (t *Traffic) AddLost(n uint64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.Now()
	if b := t.bucketAt(now, now); b != nil {
		b.lost += n
	}
}

// bucketAt returns the bucket for at, clearing it when it last held an
// older period, or nil when at is older than the ring. Call with mu held.
func (t *Traffic) bucketAt(at, now time.Time) *bucket {
	ep, cur := t.epoch(at), t.epoch(now)
	if cur-ep >= int64(len(t.buckets)) {
		return nil
	}
	b := &t.buckets[ep%int64(len(t.buckets))]
	if b.epoch != ep {
		if b.epoch > ep {
			return nil
		}
		*b = bucket{epoch: ep, edges: make(map[edgeKey]*edgeBucket, max(len(b.edges), 16))}
	}
	return b
}

func l4Of(l *flowpb.Layer4) (string, uint32) {
	switch p := l.GetProtocol().(type) {
	case *flowpb.Layer4_TCP:
		return "TCP", p.TCP.GetDestinationPort()
	case *flowpb.Layer4_UDP:
		return "UDP", p.UDP.GetDestinationPort()
	case *flowpb.Layer4_SCTP:
		return "SCTP", p.SCTP.GetDestinationPort()
	case *flowpb.Layer4_ICMPv4:
		return "ICMPv4", 0
	case *flowpb.Layer4_ICMPv6:
		return "ICMPv6", 0
	}
	return "", 0
}

func peerName(names []string, ip string) string {
	if len(names) > 0 && names[0] != "" {
		return names[0]
	}
	return ip
}

func workloadOf(e *flowpb.Endpoint) string {
	if ws := e.GetWorkloads(); len(ws) > 0 && ws[0].GetName() != "" {
		return ws[0].GetKind() + "/" + ws[0].GetName()
	}
	return ""
}

// edgeSum merges an edge's buckets for a snapshot.
type edgeSum struct {
	flows, drops, recent                                     uint64
	ports, peers, fromWl, toWl, reasons                      map[string]uint64
	otherPorts, otherPeers, otherFrom, otherTo, otherReasons uint64
}

func addAll(m *map[string]uint64, ts tallies) {
	if len(ts) == 0 {
		return
	}
	if *m == nil {
		*m = make(map[string]uint64, len(ts))
	}
	for _, x := range ts {
		(*m)[x.name] += uint64(x.n)
	}
}

// top sorts m into at most snapshotTop entries, with the rest (and other)
// summed under "".
func top(m map[string]uint64, other uint64) []Count {
	if len(m) == 0 && other == 0 {
		return nil
	}
	out := make([]Count, 0, len(m))
	for k, v := range m {
		if k == "" {
			other += v
			continue
		}
		out = append(out, Count{k, v})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].N != out[j].N {
			return out[i].N > out[j].N
		}
		return out[i].Name < out[j].Name
	})
	if len(out) > snapshotTop {
		for _, c := range out[snapshotTop:] {
			other += c.N
		}
		out = out[:snapshotTop]
	}
	if other > 0 {
		out = append(out, Count{"", other})
	}
	return out
}

// Snapshot sums the buckets of the last window (at most MaxTrafficWindow),
// busiest pairs first, and marks the map as in use.
func (t *Traffic) Snapshot(window time.Duration) TrafficMap {
	window = min(max(window, TrafficBucket), MaxTrafficWindow)
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.Now()
	t.lastUsed = now
	cur := t.epoch(now)
	n := int64(window / TrafficBucket) // buckets: the current one and n-1 before it
	first := cur - n + 1
	recentFrom := cur - 1
	since := time.Unix(0, first*int64(TrafficBucket))
	if since.Before(t.startedAt) {
		since = t.startedAt
	}
	recentStart := time.Unix(0, recentFrom*int64(TrafficBucket))
	if recentStart.Before(t.startedAt) {
		recentStart = t.startedAt
	}
	res := TrafficMap{Window: window.String(), Since: since, Now: now, StartedAt: t.startedAt, State: t.state, Error: t.err, Edges: []TrafficEdge{}}
	sums := map[edgeKey]*edgeSum{}
	var recent uint64
	for i := range t.buckets {
		b := &t.buckets[i]
		if b.epoch < first || b.epoch > cur {
			continue
		}
		res.Lost += b.lost
		res.Uncounted += b.uncounted
		for k, e := range b.edges {
			s := sums[k]
			if s == nil {
				s = &edgeSum{}
				sums[k] = s
			}
			s.flows += uint64(e.flows)
			s.drops += uint64(e.drops)
			if b.epoch >= recentFrom {
				s.recent += uint64(e.flows + e.drops)
				recent += uint64(e.flows + e.drops)
			}
			addAll(&s.ports, e.ports)
			addAll(&s.peers, e.peers)
			addAll(&s.fromWl, e.fromWl)
			addAll(&s.toWl, e.toWl)
			addAll(&s.reasons, e.reasons)
			s.otherPorts += uint64(e.otherPorts)
			s.otherPeers += uint64(e.otherPeers)
			s.otherFrom += uint64(e.otherFrom)
			s.otherTo += uint64(e.otherTo)
			s.otherReasons += uint64(e.otherReasons)
		}
	}
	secs := now.Sub(recentStart).Seconds()
	rate := func(n uint64) float64 {
		if secs < 1 {
			return 0
		}
		return float64(n) / secs
	}
	for k, s := range sums {
		res.Flows += s.flows
		res.Drops += s.drops
		res.Edges = append(res.Edges, TrafficEdge{
			From: k.from, To: k.to, Flows: s.flows, Drops: s.drops, Rate: rate(s.recent),
			Ports: top(s.ports, s.otherPorts), Peers: top(s.peers, s.otherPeers),
			FromWorkloads: top(s.fromWl, s.otherFrom), ToWorkloads: top(s.toWl, s.otherTo),
			Reasons: top(s.reasons, s.otherReasons),
		})
	}
	res.Rate = rate(recent)
	sort.Slice(res.Edges, func(i, j int) bool {
		a, b := res.Edges[i], res.Edges[j]
		if a.Flows+a.Drops != b.Flows+b.Drops {
			return a.Flows+a.Drops > b.Flows+b.Drops
		}
		if a.From != b.From {
			return a.From < b.From
		}
		return a.To < b.To
	})
	return res
}

// Idle reports whether nobody asked for a snapshot in TrafficIdle.
func (t *Traffic) Idle() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.Now().Sub(t.lastUsed) >= TrafficIdle
}

// trafficFields is what Add reads: a flow is ~150 bytes with this mask.
var trafficFields = &fieldmaskpb.FieldMask{Paths: []string{
	"time", "verdict", "drop_reason_desc", "is_reply", "Type", "trace_observation_point",
	"IP.source", "IP.destination", "l4",
	"source.namespace", "source.pod_name", "source.identity", "source.workloads",
	"destination.namespace", "destination.pod_name", "destination.identity", "destination.workloads",
	"source_names", "destination_names",
}}

// Monitor event types and trace sub-types (cilium pkg/monitor/api).
const (
	eventDrop        = 1
	eventTrace       = 4
	traceToEndpoint  = 0
	traceToHost      = 2
	traceToStack     = 3
	traceToOverlay   = 4
	traceToNetwork   = 11
	reservedIdentMax = 10
)

// trafficFilters ask the relay for only what is counted (see countable):
// to-endpoint traces, traces leaving a node for a reserved identity or the
// world, and drops, without replies. On a busy cluster this was about a
// quarter of all flows. The world is matched by label too, for CIDR
// identities (addresses a policy selects), which carry reserved:world*.
func trafficFilters() []*flowpb.FlowFilter {
	trace := func(sub int32) *flowpb.EventTypeFilter {
		return &flowpb.EventTypeFilter{Type: eventTrace, MatchSubType: true, SubType: sub}
	}
	leaving := []*flowpb.EventTypeFilter{trace(traceToNetwork), trace(traceToOverlay), trace(traceToStack), trace(traceToHost)}
	reserved := make([]uint32, 0, reservedIdentMax)
	for id := uint32(1); id <= reservedIdentMax; id++ {
		reserved = append(reserved, id)
	}
	return []*flowpb.FlowFilter{
		{EventType: []*flowpb.EventTypeFilter{trace(traceToEndpoint)}, Reply: []bool{false}},
		{
			EventType:           leaving,
			Reply:               []bool{false},
			DestinationIdentity: reserved,
		},
		{
			EventType:        leaving,
			Reply:            []bool{false},
			DestinationLabel: []string{"reserved:world", "reserved:world-ipv4", "reserved:world-ipv6"},
		},
		{EventType: []*flowpb.EventTypeFilter{{Type: eventDrop}}},
	}
}

// TrafficRequest is the relay request a map follows: from now on, with no
// history. Each node's reader then starts at the head of its buffer.
// Started further back (the relay holds seconds on a busy cluster), a
// reader works through a backlog while new flows keep arriving, can fall
// a whole buffer behind its writer and then stays there, overwritten flow
// after flow (measured: half the flows lost for as long as it ran).
func TrafficRequest() *observerpb.GetFlowsRequest {
	return &observerpb.GetFlowsRequest{Follow: true, Whitelist: trafficFilters(), FieldMask: trafficFields}
}

// errBehind ends a stream whose readers fell behind for good (see follow).
var errBehind = errors.New("relay readers fell behind")

// Over a lapWindow, a stream that lost more than it delivered (and at
// least lapMin) is restarted at the head.
var (
	lapWindow = 10 * time.Second
	lapMin    = uint64(1000)
)

// Start follows the relay until Stop, reconnecting (with backoff) when the
// stream fails. connect returns the relay's client.
func (t *Traffic) Start(connect func(ctx context.Context) (observerpb.ObserverClient, error)) {
	ctx, cancel := context.WithCancel(context.Background())
	t.mu.Lock()
	t.stop, t.done = cancel, make(chan struct{})
	t.mu.Unlock()
	go func() {
		defer close(t.done)
		backoff := time.Second
		for ctx.Err() == nil {
			err := t.follow(ctx, connect)
			if ctx.Err() != nil {
				return
			}
			if errors.Is(err, errBehind) {
				continue // straight back, at the head
			}
			t.mu.Lock()
			t.state = "error"
			t.err = "stream ended"
			if err != nil {
				t.err = ErrorMessage(err)
			}
			t.mu.Unlock()
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			backoff = min(backoff*2, 30*time.Second)
		}
	}()
}

// follow counts one stream's flows until it fails. A node's reader that
// falls a whole buffer behind its writer stays there, losing every flow
// after (the relay reports them lost one by one); when that is most of
// the stream, it is restarted so the readers start again at the head.
func (t *Traffic) follow(ctx context.Context, connect func(ctx context.Context) (observerpb.ObserverClient, error)) error {
	obs, err := connect(ctx)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stream, err := obs.GetFlows(ctx, TrafficRequest())
	if err != nil {
		return err
	}
	since := time.Now()
	var flows, lost uint64
	for {
		r, err := stream.Recv()
		if err != nil {
			return err
		}
		switch x := r.GetResponseTypes().(type) {
		case *observerpb.GetFlowsResponse_Flow:
			flows++
			t.mu.Lock()
			if t.state == "error" {
				t.state, t.err = "live", ""
			}
			t.mu.Unlock()
			t.Add(x.Flow)
		case *observerpb.GetFlowsResponse_LostEvents:
			n := x.LostEvents.GetNumEventsLost()
			lost += n
			t.AddLost(n)
		}
		if time.Since(since) >= lapWindow {
			if lost >= lapMin && lost > flows {
				return errBehind
			}
			since, flows, lost = time.Now(), 0, 0
		}
	}
}

// Stop ends the stream and waits for it.
func (t *Traffic) Stop() {
	t.mu.Lock()
	stop, done := t.stop, t.done
	t.mu.Unlock()
	if stop != nil {
		stop()
		<-done
	}
}
