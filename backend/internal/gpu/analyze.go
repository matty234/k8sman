package gpu

import (
	"fmt"
	"sort"
)

// xidCritical are XID codes that mean the GPU needs attention (ECC double
// bit errors, fallen off the bus, uncontained errors, ...).
var xidCritical = map[int]bool{48: true, 63: true, 64: true, 74: true, 79: true, 92: true, 94: true, 95: true, 119: true, 120: true}

// healthIssues are the device's own problems (no node/pod context).
func (d *Device) healthIssues() []Issue {
	var out []Issue
	add := func(sev, reason, msg string) {
		out = append(out, Issue{Severity: sev, Reason: reason, Node: d.Node, GPU: d.GPU, Message: msg})
	}
	if d.XID != nil && *d.XID > 0 {
		x := int(*d.XID)
		sev := Warning
		if xidCritical[x] {
			sev = Critical
		}
		add(sev, ReasonXID, fmt.Sprintf("XID %d reported", x))
	}
	if d.RowRemapFailure != nil && *d.RowRemapFailure > 0 {
		add(Critical, ReasonRowRemapFailure, "Row remapping failed: the GPU should be replaced")
	}
	if d.UncorrectableRemapped != nil && *d.UncorrectableRemapped > 0 {
		add(Warning, ReasonRemappedRows, fmt.Sprintf("%.0f rows remapped after uncorrectable errors", *d.UncorrectableRemapped))
	}
	if d.ECCDoubleBit != nil && *d.ECCDoubleBit > 0 {
		add(Critical, ReasonECC, fmt.Sprintf("%.0f double-bit ECC errors", *d.ECCDoubleBit))
	}
	if d.TempC != nil && *d.TempC >= HotTempC {
		add(Warning, ReasonHot, fmt.Sprintf("Running hot at %.0f °C", *d.TempC))
	}
	return out
}

var severityRank = map[string]int{Critical: 0, Warning: 1, Info: 2}

// analyze fills the summary and issues once nodes and pods are built.
func analyze(res *Result) {
	s := &res.Summary
	var utils []float64
	monitoredAny := false
	for _, n := range res.Nodes {
		s.Nodes++
		s.Capacity += n.Capacity
		s.Allocatable += n.Allocatable
		s.Allocated += n.Allocated
		s.Devices += len(n.Devices)
		s.Idle += n.IdleAllocated
		if n.Monitored {
			monitoredAny = true
		}
		for _, d := range n.Devices {
			if d.Util != nil {
				utils = append(utils, *d.Util)
			}
			issues := d.healthIssues()
			if len(issues) > 0 {
				s.Unhealthy++
			}
			for _, i := range issues {
				i.Message = fmt.Sprintf("GPU %s on %s: %s", d.GPU, n.Name, i.Message)
				res.Issues = append(res.Issues, i)
			}
		}
		if n.Capacity > n.Allocatable && n.Capacity > 0 {
			k := n.Capacity - n.Allocatable
			res.Issues = append(res.Issues, Issue{Severity: Warning, Reason: ReasonUnhealthyDevices, Node: n.Name,
				Message: fmt.Sprintf("%s: %d of %d GPUs are not allocatable (marked unhealthy by the device plugin)", n.Name, k, n.Capacity)})
		}
		if n.Monitored {
			if want := n.Capacity; want > 0 && int64(countGPUs(n.Devices)) < want {
				res.Issues = append(res.Issues, Issue{Severity: Info, Reason: ReasonMissingDevices, Node: n.Name,
					Message: fmt.Sprintf("%s: DCGM reports %d of %d GPUs", n.Name, countGPUs(n.Devices), want)})
			}
		}
		if n.IdleAllocated > 0 {
			res.Issues = append(res.Issues, idleIssue(n, res.Pods))
		}
	}
	s.AvgUtil = mean(utils)
	// Unmonitored GPU nodes only matter once DCGM is in use somewhere;
	// otherwise one cluster-level note says there's no exporter at all.
	switch {
	case monitoredAny:
		for _, n := range res.Nodes {
			if !n.Monitored && n.Capacity > 0 {
				s.Unmonitored++
				res.Issues = append(res.Issues, Issue{Severity: Warning, Reason: ReasonNoExporter, Node: n.Name,
					Message: fmt.Sprintf("%s has %d GPUs but no DCGM exporter metrics", n.Name, n.Capacity)})
			}
		}
	case res.Monitoring == MonitoringNoExporter && len(res.Nodes) > 0:
		s.Unmonitored = len(res.Nodes)
		res.Issues = append(res.Issues, Issue{Severity: Info, Reason: ReasonNoDCGM,
			Message: "Prometheus has no DCGM exporter metrics: install NVIDIA's dcgm-exporter for per-GPU utilisation and health"})
	}
	for _, p := range res.Pods {
		if p.Node == "" && p.Phase == "Pending" {
			s.PendingPods++
			if p.Unschedulable != "" {
				res.Issues = append(res.Issues, Issue{Severity: Warning, Reason: ReasonPending, Namespace: p.Namespace, Pod: p.Name,
					Message: fmt.Sprintf("%s/%s is waiting for %s: %s", p.Namespace, p.Name, gpuCount(p.GPUs), p.Unschedulable)})
			}
		}
	}
	sort.SliceStable(res.Issues, func(i, j int) bool {
		return severityRank[res.Issues[i].Severity] < severityRank[res.Issues[j].Severity]
	})
}

// countGPUs counts physical GPUs (MIG instances of one GPU count once).
func countGPUs(devs []Device) int {
	seen := map[string]bool{}
	for _, d := range devs {
		k := d.UUID
		if k == "" {
			k = d.GPU
		}
		seen[k] = true
	}
	return len(seen)
}

func gpuCount(n int64) string {
	if n == 1 {
		return "1 GPU"
	}
	if n == 0 {
		return "GPU resources"
	}
	return fmt.Sprintf("%d GPUs", n)
}

func idleIssue(n Node, pods []Pod) Issue {
	window := "hour"
	if h := IdleWindow.Hours(); h != 1 {
		window = fmt.Sprintf("%.0f hours", h)
	}
	// Attributed: name the idle pods.
	var idle []Pod
	for _, p := range pods {
		if p.Node == n.Name && p.Idle {
			idle = append(idle, p)
		}
	}
	if len(idle) == 1 {
		p := idle[0]
		return Issue{Severity: Warning, Reason: ReasonIdle, Node: n.Name, Namespace: p.Namespace, Pod: p.Name,
			Message: fmt.Sprintf("%s/%s holds %s on %s but used none of it in the last %s", p.Namespace, p.Name, gpuCount(p.GPUs), n.Name, window)}
	}
	return Issue{Severity: Warning, Reason: ReasonIdle, Node: n.Name,
		Message: fmt.Sprintf("%s: %d of %d allocated GPUs idle for the last %s", n.Name, n.IdleAllocated, n.Allocated, window)}
}
