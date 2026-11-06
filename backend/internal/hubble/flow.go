// Package hubble reads network flows from Cilium's Hubble Relay over gRPC
// (observer.Observer/GetFlows and ServerStatus), reached through an
// in-process port-forward to a relay pod. Discovery, filters, the compact
// JSON flow model, and batched streaming live here; the HTTP/WS routes are
// the hubble module in internal/server.
package hubble

import (
	"fmt"
	"strings"
	"time"

	flowpb "github.com/matty234/k8sman/backend/internal/hubble/pb/flow"
)

// Flow is one flow as sent to the UI: a flattened subset of flow.Flow.
type Flow struct {
	Time    time.Time `json:"time"`
	Verdict string    `json:"verdict"`
	// DropReason is set for DROPPED flows, e.g. POLICY_DENIED.
	DropReason string `json:"dropReason,omitempty"`
	// Direction is INGRESS or EGRESS (relative to the observing endpoint).
	Direction string    `json:"direction,omitempty"`
	IsReply   bool      `json:"isReply,omitempty"`
	Type      string    `json:"type,omitempty"` // L3_L4, L7, SOCK
	Source    Endpoint  `json:"source"`
	Dest      Endpoint  `json:"destination"`
	L4        *L4       `json:"l4,omitempty"`
	L7        *L7       `json:"l7,omitempty"`
	Node      string    `json:"node,omitempty"`
	Policies  *Policies `json:"policies,omitempty"`
	// Event is the trace observation point or event type, e.g. to-endpoint.
	Event string `json:"event,omitempty"`
}

// Endpoint is one side of a flow.
type Endpoint struct {
	Namespace string `json:"namespace,omitempty"`
	Pod       string `json:"pod,omitempty"`
	// Workload is the pod's top controller, e.g. Deployment/web.
	WorkloadKind string `json:"workloadKind,omitempty"`
	WorkloadName string `json:"workloadName,omitempty"`
	Service      string `json:"service,omitempty"` // namespace/name
	IP           string `json:"ip,omitempty"`
	Port         uint32 `json:"port,omitempty"`
	Identity     uint32 `json:"identity,omitempty"`
	// Names are DNS names Hubble resolved for the IP (world endpoints).
	Names []string `json:"names,omitempty"`
	// Reserved names an endpoint that isn't a pod by Cilium's reserved
	// identity: world, host, remote-node, kube-apiserver, …
	Reserved string `json:"reserved,omitempty"`
}

// L4 is the transport layer.
type L4 struct {
	Protocol string   `json:"protocol"` // TCP, UDP, ICMPv4, ICMPv6, SCTP
	Flags    []string `json:"flags,omitempty"`
}

// L7 is an HTTP or DNS record (Kafka and others are summarised only).
type L7 struct {
	Kind      string  `json:"kind"` // REQUEST, RESPONSE, SAMPLE
	LatencyMs float64 `json:"latencyMs,omitempty"`
	HTTP      *HTTP   `json:"http,omitempty"`
	DNS       *DNS    `json:"dns,omitempty"`
}

type HTTP struct {
	Method string `json:"method,omitempty"`
	URL    string `json:"url,omitempty"`
	Code   uint32 `json:"code,omitempty"`
}

type DNS struct {
	Query string   `json:"query,omitempty"`
	RCode uint32   `json:"rcode,omitempty"`
	IPs   []string `json:"ips,omitempty"`
}

// Policies are the network policies Hubble correlated with the flow (needs
// Cilium's policy correlation; otherwise empty).
type Policies struct {
	AllowedBy []PolicyRef `json:"allowedBy,omitempty"`
	DeniedBy  []PolicyRef `json:"deniedBy,omitempty"`
}

type PolicyRef struct {
	Kind      string `json:"kind,omitempty"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name"`
}

// FromProto converts a Hubble flow.
func FromProto(f *flowpb.Flow) Flow {
	out := Flow{
		Verdict:   f.GetVerdict().String(),
		Direction: dirName(f.GetTrafficDirection()),
		IsReply:   f.GetIsReply().GetValue(),
		Node:      f.GetNodeName(),
		Source:    endpoint(f.GetSource(), f.GetSourceService(), f.GetIP().GetSource(), f.GetSourceNames()),
		Dest:      endpoint(f.GetDestination(), f.GetDestinationService(), f.GetIP().GetDestination(), f.GetDestinationNames()),
	}
	if t := f.GetTime(); t != nil {
		out.Time = t.AsTime()
	}
	if f.GetType() != flowpb.FlowType_UNKNOWN_TYPE {
		out.Type = f.GetType().String()
	}
	if f.GetVerdict() == flowpb.Verdict_DROPPED {
		if r := f.GetDropReasonDesc(); r != flowpb.DropReason_DROP_REASON_UNKNOWN {
			out.DropReason = r.String()
		}
	}
	if p := f.GetTraceObservationPoint(); p != flowpb.TraceObservationPoint_UNKNOWN_POINT {
		out.Event = strings.ReplaceAll(strings.ToLower(p.String()), "_", "-")
	}
	if l4 := f.GetL4(); l4 != nil {
		switch p := l4.GetProtocol().(type) {
		case *flowpb.Layer4_TCP:
			out.L4 = &L4{Protocol: "TCP", Flags: tcpFlags(p.TCP.GetFlags())}
			out.Source.Port, out.Dest.Port = p.TCP.GetSourcePort(), p.TCP.GetDestinationPort()
		case *flowpb.Layer4_UDP:
			out.L4 = &L4{Protocol: "UDP"}
			out.Source.Port, out.Dest.Port = p.UDP.GetSourcePort(), p.UDP.GetDestinationPort()
		case *flowpb.Layer4_SCTP:
			out.L4 = &L4{Protocol: "SCTP"}
			out.Source.Port, out.Dest.Port = p.SCTP.GetSourcePort(), p.SCTP.GetDestinationPort()
		case *flowpb.Layer4_ICMPv4:
			out.L4 = &L4{Protocol: "ICMPv4"}
		case *flowpb.Layer4_ICMPv6:
			out.L4 = &L4{Protocol: "ICMPv6"}
		}
	}
	if l7 := f.GetL7(); l7 != nil {
		r := &L7{Kind: l7.GetType().String(), LatencyMs: float64(l7.GetLatencyNs()) / 1e6}
		if h := l7.GetHttp(); h != nil {
			r.HTTP = &HTTP{Method: h.GetMethod(), URL: h.GetUrl(), Code: h.GetCode()}
		}
		if d := l7.GetDns(); d != nil {
			r.DNS = &DNS{Query: d.GetQuery(), RCode: d.GetRcode(), IPs: d.GetIps()}
		}
		out.L7 = r
	}
	var pol Policies
	pol.AllowedBy = append(policyRefs(f.GetIngressAllowedBy()), policyRefs(f.GetEgressAllowedBy())...)
	pol.DeniedBy = append(policyRefs(f.GetIngressDeniedBy()), policyRefs(f.GetEgressDeniedBy())...)
	if len(pol.AllowedBy)+len(pol.DeniedBy) > 0 {
		out.Policies = &pol
	}
	return out
}

func endpoint(e *flowpb.Endpoint, svc *flowpb.Service, ip string, names []string) Endpoint {
	out := Endpoint{Namespace: e.GetNamespace(), Pod: e.GetPodName(), IP: ip, Identity: e.GetIdentity(), Names: names}
	if ws := e.GetWorkloads(); len(ws) > 0 {
		out.WorkloadKind, out.WorkloadName = ws[0].GetKind(), ws[0].GetName()
	}
	if svc.GetName() != "" {
		out.Service = svc.GetNamespace() + "/" + svc.GetName()
	}
	if out.Pod == "" {
		out.Reserved = reservedIdentities[out.Identity]
	}
	return out
}

// reservedIdentities are Cilium's fixed numeric identities. Flows are
// fetched without endpoint labels (they are most of a flow's size), so
// these name non-pod endpoints instead of their reserved: labels.
var reservedIdentities = map[uint32]string{
	1: "host", 2: "world", 3: "unmanaged", 4: "health", 5: "init",
	6: "remote-node", 7: "kube-apiserver", 8: "ingress", 9: "world-ipv4", 10: "world-ipv6",
}

func policyRefs(ps []*flowpb.Policy) []PolicyRef {
	var out []PolicyRef
	for _, p := range ps {
		out = append(out, PolicyRef{Kind: p.GetKind(), Namespace: p.GetNamespace(), Name: p.GetName()})
	}
	return out
}

func dirName(d flowpb.TrafficDirection) string {
	if d == flowpb.TrafficDirection_TRAFFIC_DIRECTION_UNKNOWN {
		return ""
	}
	return d.String()
}

func tcpFlags(f *flowpb.TCPFlags) []string {
	if f == nil {
		return nil
	}
	var out []string
	for _, x := range []struct {
		on   bool
		name string
	}{{f.GetSYN(), "SYN"}, {f.GetACK(), "ACK"}, {f.GetFIN(), "FIN"}, {f.GetRST(), "RST"}, {f.GetPSH(), "PSH"}} {
		if x.on {
			out = append(out, x.name)
		}
	}
	return out
}

// Label names the endpoint for grouping: namespace/pod, the service, a DNS
// name, a reserved identity (world, host, …) or the IP.
func (e Endpoint) Label() string {
	switch {
	case e.Pod != "":
		return e.Namespace + "/" + e.Pod
	case e.Service != "":
		return e.Service
	case len(e.Names) > 0:
		return e.Names[0]
	case e.Reserved != "":
		return e.Reserved
	case e.IP != "":
		return e.IP
	}
	return fmt.Sprintf("identity %d", e.Identity)
}
