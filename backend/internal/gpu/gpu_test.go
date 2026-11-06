package gpu

import (
	"encoding/json"
	"os"
	"strconv"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"

	"github.com/matty234/k8sman/backend/internal/prom"
)

var testNow = time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)

func load(t *testing.T, name string, out any) {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, out); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

// loadVector reads a Prometheus /api/v1/query response.
func loadVector(t *testing.T, name string) []prom.Sample {
	var env struct {
		Data struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Value  [2]any            `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	load(t, name, &env)
	var out []prom.Sample
	for _, r := range env.Data.Result {
		v, err := strconv.ParseFloat(r.Value[1].(string), 64)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, prom.Sample{Metric: r.Metric, Value: v})
	}
	return out
}

func input(t *testing.T) Input {
	in := Input{Now: testNow, Monitoring: MonitoringDCGM, Prometheus: "monitoring/kube-prometheus-stack-prometheus"}
	load(t, "nodes.json", &in.Nodes)
	load(t, "pods.json", &in.Pods)
	in.Metrics = loadVector(t, "dcgm.json")
	in.AvgUtil = loadVector(t, "avg_util.json")
	return in
}

func node(t *testing.T, r *Result, name string) Node {
	t.Helper()
	for _, n := range r.Nodes {
		if n.Name == name {
			return n
		}
	}
	t.Fatalf("node %s missing", name)
	return Node{}
}

func reasons(r *Result) map[string]int {
	m := map[string]int{}
	for _, i := range r.Issues {
		m[i.Reason]++
	}
	return m
}

func TestBuildUnattributed(t *testing.T) {
	r := Build(input(t))
	if len(r.Nodes) != 2 {
		t.Fatalf("want 2 GPU nodes, got %d", len(r.Nodes))
	}
	if r.Monitoring != MonitoringDCGM || r.Attribution {
		t.Fatalf("monitoring=%s attribution=%v", r.Monitoring, r.Attribution)
	}

	a := node(t, r, "gpu-node-a")
	if a.Monitored || a.Capacity != 4 || a.Allocated != 1 || a.Product != "Tesla-V100-SXM2-32GB" || a.MemoryMiB != 32768 || a.DriverVersion != "570.211.01" {
		t.Errorf("gpu-node-a: %+v", a)
	}

	b := node(t, r, "gpu-node-b")
	// Hostname is the exporter pod's name, not the node's: mapped via the pod.
	if !b.Monitored || len(b.Devices) != 3 {
		t.Fatalf("gpu-node-b monitored=%v devices=%d", b.Monitored, len(b.Devices))
	}
	if b.Allocated != 2 || len(b.Pods) != 1 || b.Pods[0].Name != "trainer-0" {
		t.Errorf("gpu-node-b allocation: %d %+v (the Succeeded pod must not count)", b.Allocated, b.Pods)
	}
	if b.DriverVersion != "595.91.07" || b.CUDAVersion != "13.2" {
		t.Errorf("versions from split labels: %q %q", b.DriverVersion, b.CUDAVersion)
	}
	d0 := b.Devices[0]
	if d0.GPU != "0" || *d0.Util != 0.87 || *d0.TensorActive != 0.42 || *d0.PowerW != 131.2 {
		t.Errorf("device 0: %+v", d0)
	}
	if want := float64(18000+5988+479) * mib; d0.MemTotal == nil || *d0.MemTotal != want {
		t.Errorf("memTotal = %v, want %v", d0.MemTotal, want)
	}
	if d0.Selector != `UUID="GPU-11111111-aaaa-bbbb-cccc-000000000000"` {
		t.Errorf("selector %s", d0.Selector)
	}
	if len(b.Devices[2].Health) != 2 {
		t.Errorf("device 2 health: %v", b.Devices[2].Health)
	}
	// 2 allocated, only one device did any work in the last hour.
	if b.IdleAllocated != 1 {
		t.Errorf("idleAllocated = %d, want 1", b.IdleAllocated)
	}

	got := reasons(r)
	for reason, n := range map[string]int{ReasonPending: 1, ReasonIdle: 1, ReasonHot: 1, ReasonRemappedRows: 1} {
		if got[reason] != n {
			t.Errorf("issues[%s] = %d, want %d (all: %v)", reason, got[reason], n, got)
		}
	}
	if r.Issues[0].Severity != Warning {
		t.Errorf("issues not sorted by severity: %+v", r.Issues)
	}
	s := r.Summary
	if s.Nodes != 2 || s.Capacity != 7 || s.Allocated != 3 || s.Devices != 3 || s.Idle != 1 || s.Unhealthy != 1 || s.Unmonitored != 1 || s.PendingPods != 1 {
		t.Errorf("summary: %+v", s)
	}
	if len(r.Pods) != 4 {
		t.Errorf("want 4 GPU pods (incl. pending and succeeded), got %d", len(r.Pods))
	}
}

func TestBuildAttributed(t *testing.T) {
	in := input(t)
	// dcgm-exporter's pod mapping, scraped without honorLabels.
	for _, set := range [][]prom.Sample{in.Metrics, in.AvgUtil} {
		for _, s := range set {
			if g := s.Metric["gpu"]; g == "1" || g == "2" {
				s.Metric["exported_pod"], s.Metric["exported_namespace"] = "trainer-0", "ml"
			}
		}
	}
	r := Build(in)
	if !r.Attribution {
		t.Fatal("attribution not detected")
	}
	b := node(t, r, "gpu-node-b")
	if b.IdleAllocated != 2 || !b.Devices[1].Idle || !b.Devices[2].Idle || b.Devices[0].Idle {
		t.Errorf("idle: %d %v", b.IdleAllocated, []bool{b.Devices[0].Idle, b.Devices[1].Idle, b.Devices[2].Idle})
	}
	var trainer Pod
	for _, p := range r.Pods {
		if p.Name == "trainer-0" {
			trainer = p
		}
	}
	if !trainer.Idle || len(trainer.Devices) != 2 || trainer.Selector != `exported_namespace="ml",exported_pod="trainer-0"` {
		t.Errorf("trainer-0: %+v", trainer)
	}
	for _, i := range r.Issues {
		if i.Reason == ReasonIdle && i.Pod != "trainer-0" {
			t.Errorf("idle issue should name the pod: %+v", i)
		}
	}
}

func TestNodeMappingVariants(t *testing.T) {
	var nodes []corev1.Node
	var pods []corev1.Pod
	load(t, "nodes.json", &nodes)
	load(t, "pods.json", &pods)
	ix := newNodeIndex(nodes, pods)
	for _, tc := range []struct {
		name   string
		labels map[string]string
		want   string
	}{
		{"Hostname is the node", map[string]string{"Hostname": "gpu-node-a"}, "gpu-node-a"},
		{"relabelled node", map[string]string{"kubernetes_node": "gpu-node-a", "Hostname": "dcgm-x"}, "gpu-node-a"},
		{"exporter pod labels", map[string]string{"namespace": "monitoring", "pod": "dcgm-exporter-abcde"}, "gpu-node-b"},
		{"Hostname is the exporter pod", map[string]string{"Hostname": "dcgm-exporter-abcde"}, "gpu-node-b"},
		{"instance is the pod IP", map[string]string{"instance": "10.244.2.7:9400"}, "gpu-node-b"},
		{"hostNetwork exporter", map[string]string{"instance": "10.0.0.11:9400"}, "gpu-node-a"},
		{"unknown", map[string]string{"Hostname": "elsewhere", "instance": "192.0.2.1:9400"}, ""},
	} {
		if got := ix.nodeFor(tc.labels); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestBuildWithoutMonitoring(t *testing.T) {
	in := input(t)
	in.Metrics, in.AvgUtil, in.Monitoring = nil, nil, MonitoringNoPrometheus
	r := Build(in)
	if r.Summary.Allocated != 3 || r.Summary.Devices != 0 {
		t.Errorf("summary: %+v", r.Summary)
	}
	if got := reasons(r); got[ReasonNoExporter] != 0 || got[ReasonNoDCGM] != 0 || got[ReasonIdle] != 0 {
		t.Errorf("no monitoring issues expected without Prometheus: %v", got)
	}

	// Prometheus without any DCGM series: one cluster-level note.
	in.Monitoring = MonitoringDCGM
	r = Build(in)
	if r.Monitoring != MonitoringNoExporter || reasons(r)[ReasonNoDCGM] != 1 || r.Summary.Unmonitored != 2 {
		t.Errorf("monitoring=%s issues=%v", r.Monitoring, reasons(r))
	}
}

func TestDevicePluginUnhealthy(t *testing.T) {
	in := input(t)
	in.Nodes[0].Status.Allocatable["nvidia.com/gpu"] = resource.MustParse("3")
	if reasons(Build(in))[ReasonUnhealthyDevices] != 1 {
		t.Error("capacity > allocatable should be reported")
	}
}
