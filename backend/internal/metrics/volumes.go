package metrics

import (
	"context"
	"sort"
	"strconv"
	"sync"
)

// Usage sources of a ClaimUsage.
const (
	SourcePrometheus = "prometheus"
	SourceKubelet    = "kubelet"
)

// ClaimUsage is one PVC's usage from whichever source has it.
type ClaimUsage struct {
	Namespace  string   `json:"namespace"`
	Claim      string   `json:"claim"`
	Source     string   `json:"source"`
	Used       *float64 `json:"usedBytes,omitempty"`
	Capacity   *float64 `json:"capacityBytes,omitempty"`
	Available  *float64 `json:"availableBytes,omitempty"`
	Inodes     *float64 `json:"inodes,omitempty"`
	InodesUsed *float64 `json:"inodesUsed,omitempty"`
}

// VolumesResult is the payload of GET /api/metrics/volumes.
type VolumesResult struct {
	Items []ClaimUsage `json:"items"`
	// Prometheus is true when Prometheus had any kubelet volume stats.
	Prometheus bool `json:"prometheus"`
	// Kubelet is the Summary API state ("available"/"unavailable") and why.
	Kubelet        string `json:"kubelet"`
	KubeletMessage string `json:"kubeletMessage,omitempty"`
}

// PromQuery runs an instant PromQL query, returning each series' labels and
// value (uncapped). It errors when there is no Prometheus.
type PromQuery func(ctx context.Context, query string) ([]PromSample, error)

// PromSample is one series of an instant vector.
type PromSample struct {
	Metric map[string]string
	Value  float64
}

var volumeStats = []string{"used_bytes", "capacity_bytes", "available_bytes", "inodes", "inodes_used"}

// Volumes merges claim usage per claim: Prometheus' kubelet_volume_stats
// where it has the claim, the kubelet Summary API for the rest (some
// Prometheus setups scrape the kubelet but drop the volume stats).
func (s *Service) Volumes(ctx context.Context, namespace string, query PromQuery) VolumesResult {
	var (
		wg      sync.WaitGroup
		summary KubeletSummary
		prom    = map[string]*ClaimUsage{}
		mu      sync.Mutex
	)
	wg.Add(1)
	go func() { defer wg.Done(); summary = s.Summary(ctx, namespace, nil) }()
	if query != nil {
		sel := ""
		if namespace != "" {
			sel = "namespace=" + strconv.Quote(namespace)
		}
		for _, m := range volumeStats {
			wg.Add(1)
			go func() {
				defer wg.Done()
				res, err := query(ctx, "max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_"+m+"{"+sel+"})")
				if err != nil {
					return
				}
				mu.Lock()
				defer mu.Unlock()
				for _, r := range res {
					ns, c := r.Metric["namespace"], r.Metric["persistentvolumeclaim"]
					if c == "" {
						continue
					}
					u := prom[ns+"/"+c]
					if u == nil {
						u = &ClaimUsage{Namespace: ns, Claim: c, Source: SourcePrometheus}
						prom[ns+"/"+c] = u
					}
					v := r.Value
					switch m {
					case "used_bytes":
						u.Used = &v
					case "capacity_bytes":
						u.Capacity = &v
					case "available_bytes":
						u.Available = &v
					case "inodes":
						u.Inodes = &v
					case "inodes_used":
						u.InodesUsed = &v
					}
				}
			}()
		}
	}
	wg.Wait()

	out := VolumesResult{Items: []ClaimUsage{}, Kubelet: summary.State, KubeletMessage: summary.Message}
	for _, u := range prom {
		if u.Used != nil {
			out.Items = append(out.Items, *u)
			out.Prometheus = true
		}
	}
	// Kubelet for claims Prometheus lacks; the largest report wins (an RWX
	// claim mounted on several nodes is reported once per pod).
	kube := map[string]ClaimUsage{}
	for _, v := range summary.Volumes {
		key := v.Namespace + "/" + v.Claim
		if p := prom[key]; p != nil && p.Used != nil {
			continue
		}
		u := ClaimUsage{Namespace: v.Namespace, Claim: v.Claim, Source: SourceKubelet,
			Used: f64(v.UsedBytes), Capacity: f64(v.CapacityBytes), Available: f64(v.AvailableBytes),
			Inodes: f64(v.Inodes), InodesUsed: f64(v.InodesUsed)}
		if prev, ok := kube[key]; !ok || val(u.Used) > val(prev.Used) {
			kube[key] = u
		}
	}
	for _, u := range kube {
		out.Items = append(out.Items, u)
	}
	sort.Slice(out.Items, func(i, j int) bool {
		a, b := out.Items[i], out.Items[j]
		return a.Namespace+"/"+a.Claim < b.Namespace+"/"+b.Claim
	})
	return out
}

func f64(p *int64) *float64 {
	if p == nil {
		return nil
	}
	v := float64(*p)
	return &v
}

func val(p *float64) float64 {
	if p == nil {
		return -1
	}
	return *p
}
