package metrics

// Kubelet Summary API (GET /api/v1/nodes/<node>/proxy/stats/summary through
// the API server, which needs get on nodes/proxy). It is the fallback for
// clusters without Prometheus: per-PVC volume usage for mounted claims, and
// cumulative network counters per pod and node, turned into rates from the
// difference between two cached samples.
//
// Everything here fails soft: a missing permission or an unreachable kubelet
// becomes State "unavailable" (or a per-node error), never an HTTP error.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

const (
	// SummaryTTL is how long one node's summary is reused (kubelet stats
	// refresh every ~10-15s anyway).
	summaryTTL = 12 * time.Second
	// summaryTimeout bounds one kubelet fetch (busy kubelets take seconds).
	summaryTimeout = 10 * time.Second
	// summaryStaleOK: a failed refresh still serves data this fresh.
	summaryStaleOK = time.Minute
	// rateMaxWindow: an older previous sample is too stale for a "live" rate.
	rateMaxWindow = 3 * time.Minute
	nodeListTTL   = 30 * time.Second
	summaryFanout = 16
)

// Summary states.
const (
	SummaryAvailable   = "available"
	SummaryUnavailable = "unavailable"
)

// VolumeUsage is one mounted PVC's filesystem usage as a kubelet reports it.
type VolumeUsage struct {
	Namespace      string `json:"namespace"`
	Claim          string `json:"claim"`
	Pod            string `json:"pod"`
	Node           string `json:"node"`
	Volume         string `json:"volume"`
	Time           string `json:"time,omitempty"`
	UsedBytes      *int64 `json:"usedBytes,omitempty"`
	CapacityBytes  *int64 `json:"capacityBytes,omitempty"`
	AvailableBytes *int64 `json:"availableBytes,omitempty"`
	Inodes         *int64 `json:"inodes,omitempty"`
	InodesUsed     *int64 `json:"inodesUsed,omitempty"`
	InodesFree     *int64 `json:"inodesFree,omitempty"`
}

// NetRate is one pod's or node's network counters and, once two samples
// exist, the rate between them. Rates are nil until then.
type NetRate struct {
	Namespace     string   `json:"namespace,omitempty"`
	Name          string   `json:"name"`
	Node          string   `json:"node,omitempty"`
	RxBytes       uint64   `json:"rxBytes"`
	TxBytes       uint64   `json:"txBytes"`
	RxBytesPerSec *float64 `json:"rxBytesPerSec,omitempty"`
	TxBytesPerSec *float64 `json:"txBytesPerSec,omitempty"`
	WindowSeconds float64  `json:"windowSeconds,omitempty"`
}

// KubeletSummary is the payload of GET /api/metrics/summary.
type KubeletSummary struct {
	State   string `json:"state"`
	Message string `json:"message,omitempty"`
	// Nodes asked, and how many answered.
	Nodes     int               `json:"nodes"`
	Reporting int               `json:"reporting"`
	Errors    map[string]string `json:"errors,omitempty"`
	Volumes   []VolumeUsage     `json:"volumes"`
	Pods      []NetRate         `json:"pods"`
	NodeNet   []NetRate         `json:"nodeNetwork"`
}

// ---- parsing ----------------------------------------------------------------

type rawIface struct {
	Name    string  `json:"name"`
	RxBytes *uint64 `json:"rxBytes"`
	TxBytes *uint64 `json:"txBytes"`
}

type rawNetwork struct {
	Time time.Time `json:"time"`
	rawIface
	Interfaces []rawIface `json:"interfaces"`
}

type rawSummary struct {
	Node struct {
		NodeName string      `json:"nodeName"`
		Network  *rawNetwork `json:"network"`
	} `json:"node"`
	Pods []struct {
		PodRef struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
			UID       string `json:"uid"`
		} `json:"podRef"`
		Network *rawNetwork `json:"network"`
		Volume  []struct {
			Time           time.Time `json:"time"`
			Name           string    `json:"name"`
			UsedBytes      *int64    `json:"usedBytes"`
			CapacityBytes  *int64    `json:"capacityBytes"`
			AvailableBytes *int64    `json:"availableBytes"`
			Inodes         *int64    `json:"inodes"`
			InodesUsed     *int64    `json:"inodesUsed"`
			InodesFree     *int64    `json:"inodesFree"`
			PVCRef         *struct {
				Name      string `json:"name"`
				Namespace string `json:"namespace"`
			} `json:"pvcRef"`
		} `json:"volume"`
	} `json:"pods"`
}

// virtualIface matches loopback, per-pod veths, CNI bridges and tunnels:
// counting them would double count traffic already seen on the physical NIC.
var virtualIface = regexp.MustCompile(`^(lo|veth|cali|flannel|cni|docker|br-|virbr|vxlan|tunl|gre|gretap|erspan|ip_vti|ip6_vti|sit|ip6tnl|ip6gre|kube-ipvs|cilium|lxc|genev|nodelocaldns|dummy)`)

// netSample is a cumulative counter reading.
type netSample struct {
	t      time.Time
	uid    string
	rx, tx uint64
}

// sample sums the non-virtual interfaces, falling back to the default
// interface's counters when the kubelet sends no list.
func (n *rawNetwork) sample(uid string) (netSample, bool) {
	if n == nil || n.Time.IsZero() {
		return netSample{}, false
	}
	s := netSample{t: n.Time, uid: uid}
	found := false
	for _, i := range n.Interfaces {
		if virtualIface.MatchString(i.Name) || i.RxBytes == nil || i.TxBytes == nil {
			continue
		}
		s.rx += *i.RxBytes
		s.tx += *i.TxBytes
		found = true
	}
	if !found {
		if n.RxBytes == nil || n.TxBytes == nil {
			return netSample{}, false
		}
		s.rx, s.tx = *n.RxBytes, *n.TxBytes
	}
	return s, true
}

// parsedSummary is one node's summary reduced to what k8sman shows.
type parsedSummary struct {
	node    string
	volumes []VolumeUsage
	nodeNet *netSample
	podNet  map[string]netSample // "namespace/name"
}

func parseSummary(node string, body []byte) (*parsedSummary, error) {
	var raw rawSummary
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("decode kubelet summary: %w", err)
	}
	if raw.Node.NodeName != "" {
		node = raw.Node.NodeName
	}
	p := &parsedSummary{node: node, podNet: map[string]netSample{}}
	if s, ok := raw.Node.Network.sample(""); ok {
		p.nodeNet = &s
	}
	for _, pod := range raw.Pods {
		ref := pod.PodRef
		if s, ok := pod.Network.sample(ref.UID); ok {
			p.podNet[ref.Namespace+"/"+ref.Name] = s
		}
		for _, v := range pod.Volume {
			if v.PVCRef == nil || v.PVCRef.Name == "" {
				continue
			}
			ns := v.PVCRef.Namespace
			if ns == "" {
				ns = ref.Namespace
			}
			vu := VolumeUsage{
				Namespace: ns, Claim: v.PVCRef.Name, Pod: ref.Name, Node: node, Volume: v.Name,
				UsedBytes: v.UsedBytes, CapacityBytes: v.CapacityBytes, AvailableBytes: v.AvailableBytes,
				Inodes: v.Inodes, InodesUsed: v.InodesUsed, InodesFree: v.InodesFree,
			}
			if !v.Time.IsZero() {
				vu.Time = v.Time.UTC().Format(time.RFC3339)
			}
			p.volumes = append(p.volumes, vu)
		}
	}
	return p, nil
}

// netPair holds the last two distinct samples of one counter.
type netPair struct{ prev, cur *netSample }

// push records s, keeping the previous sample when s is newer.
func (p *netPair) push(s netSample) {
	switch {
	case p.cur == nil:
		p.cur = &s
	case s.uid != p.cur.uid: // pod recreated under the same name
		p.prev, p.cur = nil, &s
	case s.t.After(p.cur.t):
		p.prev, p.cur = p.cur, &s
	}
}

// rate fills r's counters and, when a usable previous sample exists, rates.
func (p *netPair) rate(r *NetRate) {
	if p.cur == nil {
		return
	}
	r.RxBytes, r.TxBytes = p.cur.rx, p.cur.tx
	if p.prev == nil {
		return
	}
	dt := p.cur.t.Sub(p.prev.t)
	if dt <= 0 || dt > rateMaxWindow || p.cur.rx < p.prev.rx || p.cur.tx < p.prev.tx {
		return // counter reset or stale baseline
	}
	rx := float64(p.cur.rx-p.prev.rx) / dt.Seconds()
	tx := float64(p.cur.tx-p.prev.tx) / dt.Seconds()
	r.RxBytesPerSec, r.TxBytesPerSec, r.WindowSeconds = &rx, &tx, dt.Seconds()
}

// ---- per-node cache ---------------------------------------------------------

type kubeletNode struct {
	fetchedAt time.Time
	okAt      time.Time // last successful fetch
	err       error
	volumes   []VolumeUsage
	net       map[string]*netPair // "node" or "pod:<ns>/<name>"
	inflight  chan struct{}
}

type kubeletCache struct {
	nodes      map[string]*kubeletNode
	nodeList   []string
	nodeListAt time.Time
	nodeErr    error
}

func (s *Service) kc() *kubeletCache {
	if s.kubelet == nil {
		s.kubelet = &kubeletCache{nodes: map[string]*kubeletNode{}}
	}
	return s.kubelet
}

// readyNodes lists nodes whose Ready condition is True (others' kubelets
// would only time out). Cached for nodeListTTL.
func (s *Service) readyNodes(ctx context.Context) ([]string, error) {
	s.mu.Lock()
	kc := s.kc()
	if !kc.nodeListAt.IsZero() && s.now().Sub(kc.nodeListAt) < nodeListTTL {
		defer s.mu.Unlock()
		return kc.nodeList, kc.nodeErr
	}
	s.mu.Unlock()
	body, err := s.get.Get(ctx, "/api/v1/nodes", nil)
	var names []string
	if err == nil {
		var list struct {
			Items []struct {
				Metadata struct {
					Name string `json:"name"`
				} `json:"metadata"`
				Status struct {
					Conditions []struct {
						Type   string `json:"type"`
						Status string `json:"status"`
					} `json:"conditions"`
				} `json:"status"`
			} `json:"items"`
		}
		if err = json.Unmarshal(body, &list); err == nil {
			for _, n := range list.Items {
				for _, c := range n.Status.Conditions {
					if c.Type == "Ready" && c.Status == "True" {
						names = append(names, n.Metadata.Name)
					}
				}
			}
		}
	}
	if ctx.Err() == nil {
		s.mu.Lock()
		kc.nodeList, kc.nodeErr, kc.nodeListAt = names, err, s.now()
		s.mu.Unlock()
	}
	return names, err
}

// refreshNode fetches one node's summary unless a fresh one is cached;
// concurrent callers share one fetch.
func (s *Service) refreshNode(ctx context.Context, name string) {
	s.mu.Lock()
	kc := s.kc()
	n := kc.nodes[name]
	if n == nil {
		n = &kubeletNode{net: map[string]*netPair{}}
		kc.nodes[name] = n
	}
	if ch := n.inflight; ch != nil {
		s.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
		}
		return
	}
	if !n.fetchedAt.IsZero() && s.now().Sub(n.fetchedAt) < summaryTTL {
		s.mu.Unlock()
		return
	}
	ch := make(chan struct{})
	n.inflight = ch
	s.mu.Unlock()

	// Detached from the caller so a shared fetch survives one caller leaving.
	fctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), summaryTimeout)
	body, err := s.get.Get(fctx, "/api/v1/nodes/"+url.PathEscape(name)+"/proxy/stats/summary", nil)
	cancel()
	var p *parsedSummary
	if err == nil {
		p, err = parseSummary(name, body)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	n.inflight = nil
	close(ch)
	n.fetchedAt, n.err = s.now(), err
	if err != nil {
		return
	}
	n.okAt = n.fetchedAt
	n.volumes = p.volumes
	seen := map[string]bool{}
	if p.nodeNet != nil {
		n.pair("node").push(*p.nodeNet)
		seen["node"] = true
	}
	for k, v := range p.podNet {
		n.pair("pod:" + k).push(v)
		seen["pod:"+k] = true
	}
	for k := range n.net {
		if !seen[k] {
			delete(n.net, k)
		}
	}
}

func (n *kubeletNode) pair(key string) *netPair {
	p := n.net[key]
	if p == nil {
		p = &netPair{}
		n.net[key] = p
	}
	return p
}

// Summary returns PVC usage and network rates from the kubelets of nodes
// (all Ready nodes when empty), filtered to namespace ("" = all).
func (s *Service) Summary(ctx context.Context, namespace string, nodes []string) KubeletSummary {
	out := KubeletSummary{State: SummaryAvailable, Volumes: []VolumeUsage{}, Pods: []NetRate{}, NodeNet: []NetRate{}}
	if len(nodes) == 0 {
		var err error
		if nodes, err = s.readyNodes(ctx); err != nil {
			out.State, out.Message = SummaryUnavailable, explainKubelet(err, "list nodes")
			return out
		}
	}
	out.Nodes = len(nodes)
	if len(nodes) == 0 {
		out.State, out.Message = SummaryUnavailable, "no ready nodes"
		return out
	}

	sem := make(chan struct{}, summaryFanout)
	var wg sync.WaitGroup
	for _, n := range nodes {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; wg.Done() }()
			s.refreshNode(ctx, n)
		}()
	}
	wg.Wait()

	s.mu.Lock()
	defer s.mu.Unlock()
	kc := s.kc()
	var firstErr error
	for _, name := range nodes {
		n := kc.nodes[name]
		if n == nil || n.fetchedAt.IsZero() {
			continue // the caller left before the fetch finished
		}
		if n.err != nil && (n.okAt.IsZero() || s.now().Sub(n.okAt) > summaryStaleOK) {
			if out.Errors == nil {
				out.Errors = map[string]string{}
			}
			out.Errors[name] = explainKubelet(n.err, "read kubelet stats")
			if firstErr == nil || apierrors.IsForbidden(n.err) {
				firstErr = n.err
			}
			continue
		}
		out.Reporting++
		for _, v := range n.volumes {
			if namespace == "" || v.Namespace == namespace {
				out.Volumes = append(out.Volumes, v)
			}
		}
		for key, p := range n.net {
			r := NetRate{Node: name}
			if key == "node" {
				r.Name, r.Node = name, ""
				p.rate(&r)
				out.NodeNet = append(out.NodeNet, r)
				continue
			}
			ns, pod, _ := strings.Cut(strings.TrimPrefix(key, "pod:"), "/")
			if namespace != "" && ns != namespace {
				continue
			}
			r.Namespace, r.Name = ns, pod
			p.rate(&r)
			out.Pods = append(out.Pods, r)
		}
	}
	if out.Reporting == 0 && firstErr != nil {
		out.State, out.Message = SummaryUnavailable, explainKubelet(firstErr, "read kubelet stats")
	}
	sort.Slice(out.Volumes, func(i, j int) bool {
		a, b := out.Volumes[i], out.Volumes[j]
		return a.Namespace+"/"+a.Claim+"/"+a.Pod < b.Namespace+"/"+b.Claim+"/"+b.Pod
	})
	sort.Slice(out.Pods, func(i, j int) bool {
		return out.Pods[i].Namespace+"/"+out.Pods[i].Name < out.Pods[j].Namespace+"/"+out.Pods[j].Name
	})
	sort.Slice(out.NodeNet, func(i, j int) bool { return out.NodeNet[i].Name < out.NodeNet[j].Name })
	return out
}

// explainKubelet turns an API error into a short, calm message.
func explainKubelet(err error, what string) string {
	switch {
	case apierrors.IsForbidden(err):
		if what == "list nodes" {
			return "no permission to list nodes"
		}
		return "no permission to read kubelet stats (needs get on nodes/proxy)"
	case errors.Is(err, context.DeadlineExceeded), apierrors.IsTimeout(err), apierrors.IsServerTimeout(err):
		return "kubelet did not answer in time"
	case apierrors.IsServiceUnavailable(err), apierrors.IsInternalError(err):
		return "kubelet unreachable"
	}
	return fmt.Sprintf("could not %s: %v", what, err)
}
