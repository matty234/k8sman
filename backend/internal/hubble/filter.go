package hubble

import (
	"fmt"
	"net"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/types/known/fieldmaskpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	flowpb "github.com/matty234/k8sman/backend/internal/hubble/pb/flow"
	observerpb "github.com/matty234/k8sman/backend/internal/hubble/pb/observer"
)

// Query is what the UI asks for, translated into Hubble's own FlowFilters
// so the relay filters at the source (flows can run to thousands a second).
//
// The scope fields (Namespaces, Pod, Labels, Service) describe one set of
// endpoints, ANDed; a flow matches when either side is in it. From/To
// instead match flows from one endpoint to the other. The rest (verdicts,
// protocols, ports, direction) narrow either.
type Query struct {
	Namespaces []string // either side's namespace
	Pod        string   // namespace/name (Hubble matches it as a prefix)
	Labels     string   // a label selector, e.g. app=web,tier!=db
	Service    string   // namespace/name

	From, To string // endpoint specs, see parseEndpoint

	Verdicts  []string // FORWARDED, DROPPED, ERROR, AUDIT, …
	Protocols []string // tcp, udp, icmp, http, dns, …
	Ports     []string // destination ports
	Direction string   // ingress | egress

	Since  time.Duration // only flows newer than this
	Last   uint64        // the last N flows (before following)
	Follow bool
}

// Limits on what a request may ask for.
const (
	MaxLast     = 10000
	DefaultLast = 200
)

// ParseQuery reads a Query from URL parameters (see API.md):
// namespace (comma-separated), pod, labels, service, from, to, verdict,
// protocol, port, direction, since (a Go duration), last, follow.
func ParseQuery(v url.Values) (Query, error) {
	q := Query{
		Namespaces: list(v.Get("namespace")),
		Pod:        strings.TrimSpace(v.Get("pod")),
		Labels:     strings.TrimSpace(v.Get("labels")),
		Service:    strings.TrimSpace(v.Get("service")),
		From:       strings.TrimSpace(v.Get("from")),
		To:         strings.TrimSpace(v.Get("to")),
		Protocols:  list(strings.ToLower(v.Get("protocol"))),
		Ports:      list(v.Get("port")),
		Direction:  strings.ToLower(strings.TrimSpace(v.Get("direction"))),
		Follow:     v.Get("follow") == "true",
	}
	for _, s := range list(strings.ToUpper(v.Get("verdict"))) {
		if _, ok := flowpb.Verdict_value[s]; !ok || s == "VERDICT_UNKNOWN" {
			return q, fmt.Errorf("unknown verdict %q", s)
		}
		q.Verdicts = append(q.Verdicts, s)
	}
	for _, p := range q.Ports {
		if n, err := strconv.Atoi(p); err != nil || n < 0 || n > 65535 {
			return q, fmt.Errorf("bad port %q", p)
		}
	}
	switch q.Direction {
	case "", "ingress", "egress":
	default:
		return q, fmt.Errorf("direction must be ingress or egress, not %q", q.Direction)
	}
	if q.Pod != "" && !strings.Contains(q.Pod, "/") {
		return q, fmt.Errorf("pod must be namespace/name")
	}
	if q.Service != "" && !strings.Contains(q.Service, "/") {
		return q, fmt.Errorf("service must be namespace/name")
	}
	if (q.From != "" || q.To != "") && q.scoped() {
		return q, fmt.Errorf("from/to can't be combined with namespace, pod, labels or service")
	}
	if s := v.Get("since"); s != "" {
		d, err := time.ParseDuration(s)
		if err != nil || d < 0 {
			return q, fmt.Errorf("bad since %q (want a duration like 5m)", s)
		}
		q.Since = d
	}
	if s := v.Get("last"); s != "" {
		n, err := strconv.ParseUint(s, 10, 64)
		if err != nil {
			return q, fmt.Errorf("bad last %q", s)
		}
		q.Last = min(n, MaxLast)
	}
	for _, e := range []string{q.From, q.To} {
		if e != "" {
			if _, err := parseEndpoint(e); err != nil {
				return q, err
			}
		}
	}
	return q, nil
}

// Narrow reports whether the query selects a small part of the traffic:
// some endpoints, or only verdicts other than FORWARDED.
func (q Query) Narrow() bool {
	if q.scoped() || q.From != "" || q.To != "" {
		return true
	}
	return len(q.Verdicts) > 0 && !slices.Contains(q.Verdicts, "FORWARDED")
}

func (q Query) scoped() bool {
	return len(q.Namespaces) > 0 || q.Pod != "" || q.Labels != "" || q.Service != ""
}

// Request builds the GetFlows request. Without since or last, a request
// that doesn't follow returns the last DefaultLast flows.
func (q Query) Request(now time.Time) *observerpb.GetFlowsRequest {
	req := &observerpb.GetFlowsRequest{Number: q.Last, Follow: q.Follow, Whitelist: q.Filters(), FieldMask: flowFields}
	if q.Since > 0 {
		req.Since = timestamppb.New(now.Add(-q.Since))
	}
	if req.Number == 0 && req.Since == nil && !q.Follow {
		req.Number = DefaultLast
	}
	return req
}

// flowFields are the parts of a flow FromProto reads. Asking the relay for
// only these cuts a flow from ~3.5 KB (endpoint and node labels dominate)
// to a few hundred bytes, which matters through a port-forward tunnel.
// Relays before Cilium 1.17 ignore the mask and send whole flows.
var flowFields = &fieldmaskpb.FieldMask{Paths: []string{
	"time", "verdict", "drop_reason_desc", "traffic_direction", "is_reply", "Type", "node_name",
	"IP.source", "IP.destination", "l4", "l7",
	"source.namespace", "source.pod_name", "source.identity", "source.workloads",
	"destination.namespace", "destination.pod_name", "destination.identity", "destination.workloads",
	"source_service", "destination_service", "source_names", "destination_names",
	"trace_observation_point",
	"ingress_allowed_by", "egress_allowed_by", "ingress_denied_by", "egress_denied_by",
}}

// Filters translates the query into Hubble's whitelist. Filters in the
// list are ORed; the fields of one filter are ANDed.
func (q Query) Filters() []*flowpb.FlowFilter {
	var out []*flowpb.FlowFilter
	switch {
	case q.From != "" || q.To != "":
		f := &flowpb.FlowFilter{}
		if q.From != "" {
			e, _ := parseEndpoint(q.From)
			e.apply(f, true)
		}
		if q.To != "" {
			e, _ := parseEndpoint(q.To)
			e.apply(f, false)
		}
		out = []*flowpb.FlowFilter{f}
	case q.scoped():
		src, dst := &flowpb.FlowFilter{}, &flowpb.FlowFilter{}
		q.scope(src, true)
		q.scope(dst, false)
		out = []*flowpb.FlowFilter{src, dst}
	default:
		out = []*flowpb.FlowFilter{{}}
	}
	for _, f := range out {
		for _, v := range q.Verdicts {
			f.Verdict = append(f.Verdict, flowpb.Verdict(flowpb.Verdict_value[v]))
		}
		f.Protocol = q.Protocols
		f.DestinationPort = q.Ports
		switch q.Direction {
		case "ingress":
			f.TrafficDirection = []flowpb.TrafficDirection{flowpb.TrafficDirection_INGRESS}
		case "egress":
			f.TrafficDirection = []flowpb.TrafficDirection{flowpb.TrafficDirection_EGRESS}
		}
	}
	// An empty filter matches everything; send none instead.
	if len(out) == 1 && isEmpty(out[0]) {
		return nil
	}
	return out
}

// scope puts the query's endpoint set on one side of f.
func (q Query) scope(f *flowpb.FlowFilter, source bool) {
	var pods, labels, services []string
	switch {
	case q.Pod != "":
		pods = []string{q.Pod}
	default:
		for _, ns := range q.Namespaces {
			pods = append(pods, ns+"/")
		}
	}
	if q.Labels != "" {
		labels = []string{q.Labels}
	}
	if q.Service != "" {
		services = []string{q.Service}
	}
	if source {
		f.SourcePod, f.SourceLabel, f.SourceService = pods, labels, services
	} else {
		f.DestinationPod, f.DestinationLabel, f.DestinationService = pods, labels, services
	}
}

// endpointSpec is one end of from/to: "namespace/pod" (a prefix, so a
// workload's name matches its pods), "svc:namespace/name", "ns:namespace",
// "fqdn:name", or an IP address.
type endpointSpec struct {
	pod, service, namespace, fqdn, ip string
}

func parseEndpoint(s string) (endpointSpec, error) {
	var e endpointSpec
	switch {
	case strings.HasPrefix(s, "svc:"):
		e.service = strings.TrimPrefix(s, "svc:")
	case strings.HasPrefix(s, "ns:"):
		e.namespace = strings.TrimPrefix(s, "ns:")
	case strings.HasPrefix(s, "fqdn:"):
		e.fqdn = strings.TrimPrefix(s, "fqdn:")
	case net.ParseIP(s) != nil:
		e.ip = s
	case strings.Count(s, "/") == 1:
		e.pod = s
	default:
		return e, fmt.Errorf("bad endpoint %q: want namespace/pod, svc:namespace/name, ns:namespace, fqdn:name or an IP", s)
	}
	if (e.service != "" && !strings.Contains(e.service, "/")) || e.namespace == "" && e.service == "" && e.fqdn == "" && e.ip == "" && e.pod == "" {
		return e, fmt.Errorf("bad endpoint %q", s)
	}
	return e, nil
}

func (e endpointSpec) apply(f *flowpb.FlowFilter, source bool) {
	one := func(s string) []string {
		if s == "" {
			return nil
		}
		return []string{s}
	}
	pod := one(e.pod)
	if e.namespace != "" {
		pod = []string{e.namespace + "/"}
	}
	if source {
		f.SourcePod, f.SourceService, f.SourceFqdn, f.SourceIp = pod, one(e.service), one(e.fqdn), one(e.ip)
	} else {
		f.DestinationPod, f.DestinationService, f.DestinationFqdn, f.DestinationIp = pod, one(e.service), one(e.fqdn), one(e.ip)
	}
}

func isEmpty(f *flowpb.FlowFilter) bool {
	return len(f.SourcePod)+len(f.DestinationPod)+len(f.SourceLabel)+len(f.DestinationLabel)+
		len(f.SourceService)+len(f.DestinationService)+len(f.SourceFqdn)+len(f.DestinationFqdn)+
		len(f.SourceIp)+len(f.DestinationIp)+len(f.Verdict)+len(f.Protocol)+len(f.DestinationPort)+
		len(f.TrafficDirection) == 0
}

func list(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
