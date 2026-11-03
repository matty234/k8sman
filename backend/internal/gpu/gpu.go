// Package gpu builds an NVIDIA GPU inventory for the cluster: GPU nodes and
// what is allocated on them (from the Kubernetes API, so it works without
// any monitoring), merged with live per-device stats from the DCGM
// exporter when Prometheus has them.
//
// It is pure: the caller lists nodes and pods and runs the Prometheus
// queries ([MetricsQuery], [IdleQuery]), so the analysis is unit-testable
// with fixtures. See "NVIDIA GPUs" in API.md.
package gpu

import (
	"fmt"
	"sort"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"

	"github.com/matty234/k8sman/backend/internal/prom"
)

// ResourceGPU is the device plugin's whole-GPU resource.
const ResourceGPU = "nvidia.com/gpu"

// Thresholds.
const (
	// IdleWindow is the window of [IdleQuery]; an allocated GPU averaging
	// under IdleUtil over it is reported idle.
	IdleWindow = time.Hour
	IdleUtil   = 0.01
	// HotTempC is the GPU temperature (°C) reported as running hot.
	HotTempC = 85.0
)

// Monitoring states.
const (
	MonitoringDCGM         = "dcgm"         // DCGM exporter series found
	MonitoringNoExporter   = "noExporter"   // Prometheus reachable, no DCGM series
	MonitoringNoPrometheus = "noPrometheus" // no reachable Prometheus
	MonitoringError        = "error"        // queries failed
	MonitoringSkipped      = "skipped"      // live=false
)

// Severity levels (same strings as the overview).
const (
	Critical = "critical"
	Warning  = "warning"
	Info     = "info"
)

// Result is the GET /api/gpu payload.
type Result struct {
	GeneratedAt string `json:"generatedAt"`
	// Monitoring is one of the Monitoring* constants.
	Monitoring string `json:"monitoring"`
	// Prometheus is the instance queried ("<namespace>/<name>").
	Prometheus string `json:"prometheus,omitempty"`
	// Attribution is true when DCGM series name the pod using each device
	// (exported_pod/exported_namespace, or pod/namespace with honorLabels).
	Attribution bool              `json:"attribution"`
	Summary     Summary           `json:"summary"`
	Nodes       []Node            `json:"nodes"`
	Pods        []Pod             `json:"pods"`
	Issues      []Issue           `json:"issues"`
	Errors      map[string]string `json:"errors,omitempty"`
}

// Summary is the cluster-wide roll-up.
type Summary struct {
	Nodes       int   `json:"nodes"`
	Capacity    int64 `json:"capacity"`
	Allocatable int64 `json:"allocatable"`
	Allocated   int64 `json:"allocated"`
	// Devices is the number of devices reporting DCGM metrics.
	Devices int `json:"devices"`
	// Idle counts allocated GPUs idle over IdleWindow.
	Idle        int `json:"idle"`
	Unhealthy   int `json:"unhealthy"`
	Unmonitored int `json:"unmonitored"`
	PendingPods int `json:"pendingPods"`
	// AvgUtil is the mean utilisation of reporting devices (0..1).
	AvgUtil *float64 `json:"avgUtil,omitempty"`
}

// Resource is one extended GPU resource on a node (nvidia.com/gpu, a MIG
// profile such as nvidia.com/mig-1g.10gb, or nvidia.com/gpu.shared).
type Resource struct {
	Name        string `json:"name"`
	Capacity    int64  `json:"capacity"`
	Allocatable int64  `json:"allocatable"`
	Allocated   int64  `json:"allocated"`
}

// Node is one node with GPU capacity.
type Node struct {
	Name          string `json:"name"`
	Ready         bool   `json:"ready"`
	Unschedulable bool   `json:"unschedulable,omitempty"`
	// From GPU feature discovery labels (empty when absent).
	Product         string `json:"product,omitempty"`
	Family          string `json:"family,omitempty"`
	MemoryMiB       int64  `json:"memoryMiB,omitempty"`
	Count           int64  `json:"count,omitempty"`
	DriverVersion   string `json:"driverVersion,omitempty"`
	CUDAVersion     string `json:"cudaVersion,omitempty"`
	MIGStrategy     string `json:"migStrategy,omitempty"`
	MIGCapable      bool   `json:"migCapable,omitempty"`
	SharingStrategy string `json:"sharingStrategy,omitempty"`
	Replicas        int64  `json:"replicas,omitempty"`
	// Whole GPUs (nvidia.com/gpu).
	Capacity    int64 `json:"capacity"`
	Allocatable int64 `json:"allocatable"`
	Allocated   int64 `json:"allocated"`
	// Resources lists every GPU resource, nvidia.com/gpu first.
	Resources []Resource `json:"resources"`
	// Monitored is true when DCGM series map to this node.
	Monitored bool     `json:"monitored"`
	Devices   []Device `json:"devices"`
	// Pods are the running pods holding GPU resources here.
	Pods []PodRef `json:"pods"`
	// IdleAllocated is how many allocated GPUs are idle over IdleWindow
	// (a lower bound when devices can't be attributed to pods).
	IdleAllocated int `json:"idleAllocated,omitempty"`
	// Selector matches this node's DCGM series in PromQL (e.g.
	// `UUID=~"GPU-a|GPU-b"`); empty when unmonitored.
	Selector string `json:"selector,omitempty"`
}

// Device is one GPU (or MIG instance) reporting DCGM metrics.
type Device struct {
	Node        string `json:"node"`
	GPU         string `json:"gpu"`
	UUID        string `json:"uuid,omitempty"`
	Model       string `json:"model,omitempty"`
	PCIBusID    string `json:"pciBusId,omitempty"`
	Device      string `json:"device,omitempty"`
	MIGProfile  string `json:"migProfile,omitempty"`
	MIGInstance string `json:"migInstance,omitempty"`
	Driver      string `json:"driver,omitempty"`
	// Utilisation fractions (0..1).
	Util         *float64 `json:"util,omitempty"`
	MemCopyUtil  *float64 `json:"memCopyUtil,omitempty"`
	EncUtil      *float64 `json:"encUtil,omitempty"`
	DecUtil      *float64 `json:"decUtil,omitempty"`
	GrActive     *float64 `json:"grActive,omitempty"`
	TensorActive *float64 `json:"tensorActive,omitempty"`
	DRAMActive   *float64 `json:"dramActive,omitempty"`
	// AvgUtil is the mean utilisation over IdleWindow.
	AvgUtil *float64 `json:"avgUtil,omitempty"`
	// Framebuffer memory in bytes.
	MemUsed  *float64 `json:"memUsed,omitempty"`
	MemTotal *float64 `json:"memTotal,omitempty"`
	TempC    *float64 `json:"tempC,omitempty"`
	MemTempC *float64 `json:"memTempC,omitempty"`
	PowerW   *float64 `json:"powerW,omitempty"`
	SMClock  *float64 `json:"smClockMHz,omitempty"`
	// Health counters.
	XID                   *float64 `json:"xid,omitempty"`
	UncorrectableRemapped *float64 `json:"uncorrectableRemappedRows,omitempty"`
	CorrectableRemapped   *float64 `json:"correctableRemappedRows,omitempty"`
	RowRemapFailure       *float64 `json:"rowRemapFailure,omitempty"`
	ECCDoubleBit          *float64 `json:"eccDbe,omitempty"`
	PCIeReplays           *float64 `json:"pcieReplays,omitempty"`
	Pods                  []PodRef `json:"pods,omitempty"`
	Health                []string `json:"health,omitempty"`
	Idle                  bool     `json:"idle,omitempty"`
	// Selector matches this device's DCGM series in PromQL.
	Selector string `json:"selector"`

	key                string
	fbFree, fbReserved *float64
}

// PodRef names a pod and how many GPU resources it holds.
type PodRef struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	GPUs      int64  `json:"gpus,omitempty"`
}

// Pod is a pod requesting GPU resources.
type Pod struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Node      string `json:"node,omitempty"`
	Phase     string `json:"phase"`
	// GPUs is the effective request of nvidia.com/gpu; Resources has every
	// GPU resource requested (incl. MIG profiles).
	GPUs      int64            `json:"gpus"`
	Resources map[string]int64 `json:"resources"`
	StartedAt string           `json:"startedAt,omitempty"`
	// Devices are the UUIDs attributed to this pod by DCGM labels.
	Devices []string `json:"devices,omitempty"`
	// Util is the mean current utilisation of its devices (0..1).
	Util *float64 `json:"util,omitempty"`
	// AvgUtil is the mean utilisation over IdleWindow of its devices.
	AvgUtil *float64 `json:"avgUtil,omitempty"`
	Idle    bool     `json:"idle,omitempty"`
	// Selector matches its devices' DCGM series in PromQL (by pod labels);
	// empty without attribution.
	Selector string `json:"selector,omitempty"`
	// Unschedulable carries the scheduler's message for pending pods.
	Unschedulable string `json:"unschedulable,omitempty"`
}

// Issue is one GPU problem, for the GPU view and the overview.
type Issue struct {
	Severity  string `json:"severity"`
	Reason    string `json:"reason"`
	Node      string `json:"node,omitempty"`
	Namespace string `json:"namespace,omitempty"`
	Pod       string `json:"pod,omitempty"`
	GPU       string `json:"gpu,omitempty"`
	Message   string `json:"message"`
}

// Issue reasons.
const (
	ReasonIdle             = "IdleAllocated"
	ReasonNoExporter       = "NoExporter"
	ReasonNoDCGM           = "NoDCGM"
	ReasonUnhealthyDevices = "DevicePluginUnhealthy"
	ReasonMissingDevices   = "DevicesNotReported"
	ReasonXID              = "XIDError"
	ReasonRowRemapFailure  = "RowRemapFailure"
	ReasonRemappedRows     = "UncorrectableRemappedRows"
	ReasonECC              = "ECCDoubleBitErrors"
	ReasonHot              = "HighTemperature"
	ReasonPending          = "PendingGPU"
)

// Input is what [Build] analyses.
type Input struct {
	Now   time.Time
	Nodes []corev1.Node
	// Pods should be every pod in the cluster: GPU pods are picked out, and
	// all of them help map exporter pods to nodes.
	Pods []corev1.Pod
	// Monitoring is a Monitoring* constant describing Metrics/AvgUtil.
	Monitoring string
	Prometheus string
	// Metrics is the result of [MetricsQuery]; AvgUtil of [IdleQuery].
	Metrics []prom.Sample
	AvgUtil []prom.Sample
}

// dcgmMetrics are the series fetched in one instant query.
var dcgmMetrics = []string{
	"DCGM_FI_DEV_GPU_UTIL", "DCGM_FI_DEV_MEM_COPY_UTIL", "DCGM_FI_DEV_ENC_UTIL", "DCGM_FI_DEV_DEC_UTIL",
	"DCGM_FI_DEV_FB_USED", "DCGM_FI_DEV_FB_FREE", "DCGM_FI_DEV_FB_RESERVED",
	"DCGM_FI_DEV_GPU_TEMP", "DCGM_FI_DEV_MEMORY_TEMP", "DCGM_FI_DEV_POWER_USAGE", "DCGM_FI_DEV_SM_CLOCK",
	"DCGM_FI_DEV_XID_ERRORS", "DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS", "DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS",
	"DCGM_FI_DEV_ROW_REMAP_FAILURE", "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL", "DCGM_FI_DEV_PCIE_REPLAY_COUNTER",
	"DCGM_FI_PROF_GR_ENGINE_ACTIVE", "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE", "DCGM_FI_PROF_DRAM_ACTIVE",
}

// MetricsQuery fetches every DCGM series the inventory uses in one query.
func MetricsQuery() string {
	return `{__name__=~"` + strings.Join(dcgmMetrics, "|") + `"}`
}

// IdleQuery is the mean utilisation of each device over IdleWindow.
func IdleQuery() string {
	return fmt.Sprintf("avg_over_time(DCGM_FI_DEV_GPU_UTIL[%dm])", int(IdleWindow.Minutes()))
}

// IsGPUResource reports whether name is an NVIDIA GPU extended resource.
func IsGPUResource(name string) bool {
	return name == ResourceGPU || name == "nvidia.com/gpu.shared" || strings.HasPrefix(name, "nvidia.com/mig-")
}

// Build assembles the inventory. It never fails: missing inputs just leave
// parts of the result empty.
func Build(in Input) *Result {
	now := in.Now
	if now.IsZero() {
		now = time.Now()
	}
	res := &Result{
		GeneratedAt: now.UTC().Format(time.RFC3339),
		Monitoring:  in.Monitoring,
		Prometheus:  in.Prometheus,
		Nodes:       []Node{},
		Pods:        []Pod{},
		Issues:      []Issue{},
	}
	nodes := map[string]*Node{}
	var order []string
	for i := range in.Nodes {
		if n, ok := nodeFrom(&in.Nodes[i]); ok {
			nodes[n.Name] = n
			order = append(order, n.Name)
		}
	}

	// GPU pods, and allocation per node.
	podsByKey := map[string]*Pod{}
	var pods []*Pod
	for i := range in.Pods {
		p := podFrom(&in.Pods[i])
		if p == nil {
			continue
		}
		pods = append(pods, p)
		podsByKey[p.Namespace+"/"+p.Name] = p
		if !p.holding() {
			continue
		}
		n := nodes[p.Node]
		if n == nil {
			continue
		}
		n.Pods = append(n.Pods, PodRef{Namespace: p.Namespace, Name: p.Name, GPUs: p.GPUs})
		n.Allocated += p.GPUs
		for name, q := range p.Resources {
			r := n.resource(name)
			r.Allocated += q
		}
	}

	// Live device stats.
	devices := map[string]*Device{}
	if len(in.Metrics) > 0 {
		ix := newNodeIndex(in.Nodes, in.Pods)
		for _, s := range in.Metrics {
			d := deviceFor(devices, s.Metric, ix)
			d.apply(s.Metric["__name__"], s.Value)
			if ref, sel, ok := attribution(s.Metric, podsByKey); ok {
				res.Attribution = true
				d.addPod(ref)
				if p := podsByKey[ref.Namespace+"/"+ref.Name]; p != nil {
					p.Selector = sel
				}
			}
		}
		for _, s := range in.AvgUtil {
			if d := devices[deviceKey(s.Metric)]; d != nil {
				v := s.Value / 100
				d.AvgUtil = &v
			}
		}
	}
	for _, d := range devices {
		d.finish()
		if n := nodes[d.Node]; n != nil {
			n.Monitored = true
			n.Devices = append(n.Devices, *d)
		}
	}

	if in.Monitoring == MonitoringDCGM && len(devices) == 0 {
		res.Monitoring = MonitoringNoExporter
	}
	for _, name := range order {
		n := nodes[name]
		n.finish(podsByKey, now)
		res.Nodes = append(res.Nodes, *n)
	}
	podDevices(res.Nodes, podsByKey)
	for _, p := range pods {
		res.Pods = append(res.Pods, *p)
	}
	sort.Slice(res.Pods, func(i, j int) bool {
		a, b := res.Pods[i], res.Pods[j]
		if a.Namespace != b.Namespace {
			return a.Namespace < b.Namespace
		}
		return a.Name < b.Name
	})
	analyze(res)
	return res
}

// ---- nodes ------------------------------------------------------------------

func qty(l corev1.ResourceList, name string) int64 {
	q, ok := l[corev1.ResourceName(name)]
	if !ok {
		return 0
	}
	return q.Value()
}

func nodeFrom(k *corev1.Node) (*Node, bool) {
	n := &Node{Name: k.Name, Unschedulable: k.Spec.Unschedulable, Devices: []Device{}, Pods: []PodRef{}}
	names := map[string]bool{}
	for r := range k.Status.Capacity {
		if IsGPUResource(string(r)) {
			names[string(r)] = true
		}
	}
	for r := range k.Status.Allocatable {
		if IsGPUResource(string(r)) {
			names[string(r)] = true
		}
	}
	l := k.Labels
	if len(names) == 0 && l["nvidia.com/gpu.present"] != "true" {
		return nil, false
	}
	for name := range names {
		n.Resources = append(n.Resources, Resource{Name: name, Capacity: qty(k.Status.Capacity, name), Allocatable: qty(k.Status.Allocatable, name)})
	}
	sort.Slice(n.Resources, func(i, j int) bool {
		a, b := n.Resources[i].Name, n.Resources[j].Name
		if (a == ResourceGPU) != (b == ResourceGPU) {
			return a == ResourceGPU
		}
		return a < b
	})
	if n.Resources == nil {
		n.Resources = []Resource{}
	}
	var total int64
	for _, r := range n.Resources {
		total += r.Capacity
	}
	if total == 0 && l["nvidia.com/gpu.present"] != "true" {
		return nil, false
	}
	n.Capacity = qty(k.Status.Capacity, ResourceGPU)
	n.Allocatable = qty(k.Status.Allocatable, ResourceGPU)
	for _, c := range k.Status.Conditions {
		if c.Type == corev1.NodeReady {
			n.Ready = c.Status == corev1.ConditionTrue
		}
	}
	n.Product = l["nvidia.com/gpu.product"]
	n.Family = l["nvidia.com/gpu.family"]
	n.MemoryMiB = labelInt(l["nvidia.com/gpu.memory"])
	n.Count = labelInt(l["nvidia.com/gpu.count"])
	n.DriverVersion = l["nvidia.com/cuda.driver-version.full"]
	if n.DriverVersion == "" && l["nvidia.com/cuda.driver.major"] != "" {
		n.DriverVersion = joinVersion(l["nvidia.com/cuda.driver.major"], l["nvidia.com/cuda.driver.minor"], l["nvidia.com/cuda.driver.rev"])
	}
	n.CUDAVersion = l["nvidia.com/cuda.runtime-version.full"]
	if n.CUDAVersion == "" && l["nvidia.com/cuda.runtime.major"] != "" {
		n.CUDAVersion = joinVersion(l["nvidia.com/cuda.runtime.major"], l["nvidia.com/cuda.runtime.minor"])
	}
	n.MIGStrategy = l["nvidia.com/mig.strategy"]
	n.MIGCapable = l["nvidia.com/mig.capable"] == "true"
	n.SharingStrategy = l["nvidia.com/gpu.sharing-strategy"]
	n.Replicas = labelInt(l["nvidia.com/gpu.replicas"])
	return n, true
}

func labelInt(s string) int64 {
	if s == "" {
		return 0
	}
	q, err := resource.ParseQuantity(s)
	if err != nil {
		return 0
	}
	return q.Value()
}

func joinVersion(parts ...string) string {
	var out []string
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, ".")
}

func (n *Node) resource(name string) *Resource {
	for i := range n.Resources {
		if n.Resources[i].Name == name {
			return &n.Resources[i]
		}
	}
	n.Resources = append(n.Resources, Resource{Name: name})
	return &n.Resources[len(n.Resources)-1]
}

// finish sorts devices, builds the selector and works out idle GPUs.
func (n *Node) finish(pods map[string]*Pod, now time.Time) {
	sort.Slice(n.Devices, func(i, j int) bool { return lessGPU(n.Devices[i], n.Devices[j]) })
	sort.Slice(n.Pods, func(i, j int) bool {
		if n.Pods[i].Namespace != n.Pods[j].Namespace {
			return n.Pods[i].Namespace < n.Pods[j].Namespace
		}
		return n.Pods[i].Name < n.Pods[j].Name
	})
	var uuids []string
	seen := map[string]bool{}
	for _, d := range n.Devices {
		if d.UUID != "" && !seen[d.UUID] {
			seen[d.UUID] = true
			uuids = append(uuids, d.UUID)
		}
	}
	if len(uuids) > 0 {
		n.Selector = `UUID=~"` + strings.Join(uuids, "|") + `"`
	}
	n.markIdle(pods, now)
}

func lessGPU(a, b Device) bool {
	ai, aerr := parseIndex(a.GPU)
	bi, berr := parseIndex(b.GPU)
	if aerr == nil && berr == nil && ai != bi {
		return ai < bi
	}
	if a.GPU != b.GPU {
		return a.GPU < b.GPU
	}
	return a.MIGInstance < b.MIGInstance
}

func parseIndex(s string) (int, error) {
	var i int
	_, err := fmt.Sscanf(s, "%d", &i)
	return i, err
}

// markIdle flags idle allocated GPUs. With attribution it's exact: a pod
// whose devices all averaged under IdleUtil (and that has run for the whole
// window) is idle. Without it, the node reports how many allocated GPUs
// must be idle: allocated minus devices that did any work.
func (n *Node) markIdle(pods map[string]*Pod, now time.Time) {
	if !n.Monitored || n.Allocated == 0 {
		return
	}
	oldEnough := func(p *Pod) bool {
		t, err := time.Parse(time.RFC3339, p.StartedAt)
		return err == nil && now.Sub(t) >= IdleWindow
	}
	attributed := false
	for _, d := range n.Devices {
		if len(d.Pods) > 0 {
			attributed = true
		}
	}
	if attributed {
		for i := range n.Devices {
			d := &n.Devices[i]
			if len(d.Pods) == 0 || d.AvgUtil == nil || *d.AvgUtil >= IdleUtil {
				continue
			}
			all := true
			for _, ref := range d.Pods {
				if p := pods[ref.Namespace+"/"+ref.Name]; p == nil || !oldEnough(p) {
					all = false
				}
			}
			if all {
				d.Idle = true
				n.IdleAllocated++
			}
		}
		return
	}
	// Unattributed: every GPU pod here must predate the window, and every
	// device must have an average, or we can't say anything.
	for _, ref := range n.Pods {
		if p := pods[ref.Namespace+"/"+ref.Name]; p == nil || p.GPUs == 0 || !oldEnough(p) {
			return
		}
	}
	busy := 0
	for _, d := range n.Devices {
		if d.AvgUtil == nil {
			return
		}
		if *d.AvgUtil >= IdleUtil {
			busy++
		}
	}
	if idle := int(n.Allocated) - busy; idle > 0 {
		n.IdleAllocated = idle
	}
}

// ---- pods -------------------------------------------------------------------

func podFrom(k *corev1.Pod) *Pod {
	res := map[string]int64{}
	add := func(c corev1.Container, into map[string]int64) {
		for name, q := range c.Resources.Limits {
			if IsGPUResource(string(name)) {
				into[string(name)] = q.Value()
			}
		}
		// Extended resources must have request == limit; a request alone is
		// invalid, but take it if that's all there is.
		for name, q := range c.Resources.Requests {
			if IsGPUResource(string(name)) {
				if _, ok := into[string(name)]; !ok {
					into[string(name)] = q.Value()
				}
			}
		}
	}
	for _, c := range k.Spec.Containers {
		one := map[string]int64{}
		add(c, one)
		for n, v := range one {
			res[n] += v
		}
	}
	// Effective request: max(sum of containers, any init container).
	for _, c := range k.Spec.InitContainers {
		one := map[string]int64{}
		add(c, one)
		for n, v := range one {
			if v > res[n] {
				res[n] = v
			}
		}
	}
	for n, v := range res {
		if v == 0 {
			delete(res, n)
		}
	}
	if len(res) == 0 {
		return nil
	}
	p := &Pod{Namespace: k.Namespace, Name: k.Name, Node: k.Spec.NodeName, Phase: string(k.Status.Phase), GPUs: res[ResourceGPU], Resources: res}
	if k.DeletionTimestamp != nil {
		p.Phase = "Terminating"
	}
	if k.Status.StartTime != nil {
		p.StartedAt = k.Status.StartTime.UTC().Format(time.RFC3339)
	}
	if p.Node == "" {
		for _, c := range k.Status.Conditions {
			if c.Type == corev1.PodScheduled && c.Status == corev1.ConditionFalse && c.Reason == corev1.PodReasonUnschedulable {
				p.Unschedulable = c.Message
				if p.Unschedulable == "" {
					p.Unschedulable = "Unschedulable"
				}
			}
		}
	}
	return p
}

// podDevices fills each pod's devices and utilisation from attributed
// devices.
func podDevices(nodes []Node, pods map[string]*Pod) {
	type acc struct {
		util, avg   []float64
		idle, total int
	}
	accs := map[*Pod]*acc{}
	for _, n := range nodes {
		for _, d := range n.Devices {
			for _, ref := range d.Pods {
				p := pods[ref.Namespace+"/"+ref.Name]
				if p == nil {
					continue
				}
				a := accs[p]
				if a == nil {
					a = &acc{}
					accs[p] = a
				}
				if d.UUID != "" {
					p.Devices = append(p.Devices, d.UUID)
				}
				a.total++
				if d.Util != nil {
					a.util = append(a.util, *d.Util)
				}
				if d.AvgUtil != nil {
					a.avg = append(a.avg, *d.AvgUtil)
				}
				if d.Idle {
					a.idle++
				}
			}
		}
	}
	for p, a := range accs {
		p.Util = mean(a.util)
		p.AvgUtil = mean(a.avg)
		p.Idle = a.total > 0 && a.idle == a.total
	}
}

func mean(v []float64) *float64 {
	if len(v) == 0 {
		return nil
	}
	var s float64
	for _, x := range v {
		s += x
	}
	m := s / float64(len(v))
	return &m
}

// holding reports whether the pod currently holds its GPUs on a node.
func (p *Pod) holding() bool {
	return p.Node != "" && p.Phase != string(corev1.PodSucceeded) && p.Phase != string(corev1.PodFailed)
}
