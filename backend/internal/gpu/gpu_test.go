package gpu

import (
	"encoding/json"
	"os"
	"strconv"
	"testing"
	"time"

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
