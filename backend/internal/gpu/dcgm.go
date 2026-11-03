package gpu

import (
	"net"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"
)

// nodeIndex maps DCGM series to nodes. Exporter setups differ: some set
// Hostname to the node name, some to the exporter pod's name, some relabel
// a node/kubernetes_node label; pod/namespace usually name the exporter pod
// (or the workload, with honorLabels); instance is the scrape address.
type nodeIndex struct {
	nodes   map[string]bool
	nodeIPs map[string]string   // node address -> node
	pods    map[string]string   // namespace/name -> node
	podName map[string][]string // name -> nodes
	podIPs  map[string]string   // pod IP -> node
}

func newNodeIndex(nodes []corev1.Node, pods []corev1.Pod) *nodeIndex {
	ix := &nodeIndex{nodes: map[string]bool{}, nodeIPs: map[string]string{}, pods: map[string]string{}, podName: map[string][]string{}, podIPs: map[string]string{}}
	for i := range nodes {
		n := &nodes[i]
		ix.nodes[n.Name] = true
		for _, a := range n.Status.Addresses {
			ix.nodeIPs[a.Address] = n.Name
		}
	}
	for i := range pods {
		p := &pods[i]
		if p.Spec.NodeName == "" {
			continue
		}
		ix.pods[p.Namespace+"/"+p.Name] = p.Spec.NodeName
		ix.podName[p.Name] = append(ix.podName[p.Name], p.Spec.NodeName)
		if p.Status.PodIP != "" && !p.Spec.HostNetwork {
			ix.podIPs[p.Status.PodIP] = p.Spec.NodeName
		}
	}
	return ix
}

// nodeLabels name the node directly in common exporter/relabel setups.
var nodeLabels = []string{"node", "kubernetes_node", "nodename", "node_name", "Hostname", "hostname"}

func (ix *nodeIndex) nodeFor(m map[string]string) string {
	for _, k := range nodeLabels {
		if v := m[k]; v != "" && ix.nodes[v] {
			return v
		}
	}
	// The pod that produced (or, with honorLabels, uses) the series.
	for _, k := range [][2]string{{"namespace", "pod"}, {"exported_namespace", "exported_pod"}} {
		if node := ix.pods[m[k[0]]+"/"+m[k[1]]]; node != "" {
			return node
		}
	}
	// Hostname is often the exporter pod's name.
	for _, k := range []string{"Hostname", "hostname", "pod"} {
		if ns := ix.podName[m[k]]; len(ns) == 1 {
			return ns[0]
		}
	}
	// The scrape address: the exporter pod's IP, or the node's with hostNetwork.
	if inst := m["instance"]; inst != "" {
		host := inst
		if h, _, err := net.SplitHostPort(inst); err == nil {
			host = h
		}
		if node := ix.podIPs[host]; node != "" {
			return node
		}
		if node := ix.nodeIPs[host]; node != "" {
			return node
		}
	}
	return ""
}

// deviceKey identifies a device (or MIG instance) across series.
func deviceKey(m map[string]string) string {
	id := m["UUID"]
	if id == "" {
		id = m["instance"] + "/" + m["gpu"]
	}
	if gi := m["GPU_I_ID"]; gi != "" {
		id += "/" + gi
	}
	return id
}

func deviceFor(devs map[string]*Device, m map[string]string, ix *nodeIndex) *Device {
	key := deviceKey(m)
	if d := devs[key]; d != nil {
		if d.Node == "" {
			d.Node = ix.nodeFor(m)
		}
		return d
	}
	d := &Device{
		key:         key,
		Node:        ix.nodeFor(m),
		GPU:         m["gpu"],
		UUID:        m["UUID"],
		Model:       m["modelName"],
		PCIBusID:    m["pci_bus_id"],
		Device:      m["device"],
		MIGProfile:  m["GPU_I_PROFILE"],
		MIGInstance: m["GPU_I_ID"],
		Driver:      m["DCGM_FI_DRIVER_VERSION"],
	}
	var sel []string
	if d.UUID != "" {
		sel = append(sel, `UUID="`+promQuote(d.UUID)+`"`)
	} else {
		sel = append(sel, `instance="`+promQuote(m["instance"])+`"`, `gpu="`+promQuote(d.GPU)+`"`)
	}
	if d.MIGInstance != "" {
		sel = append(sel, `GPU_I_ID="`+promQuote(d.MIGInstance)+`"`)
	}
	d.Selector = strings.Join(sel, ",")
	devs[key] = d
	return d
}

func promQuote(s string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(s)
}

func ptr(v float64) *float64 { return &v }

const mib = 1024 * 1024

// apply records one DCGM sample. Utilisation percentages become fractions
// and framebuffer MiB become bytes.
func (d *Device) apply(name string, v float64) {
	switch name {
	case "DCGM_FI_DEV_GPU_UTIL":
		d.Util = maxPtr(d.Util, v/100)
	case "DCGM_FI_DEV_MEM_COPY_UTIL":
		d.MemCopyUtil = maxPtr(d.MemCopyUtil, v/100)
	case "DCGM_FI_DEV_ENC_UTIL":
		d.EncUtil = maxPtr(d.EncUtil, v/100)
	case "DCGM_FI_DEV_DEC_UTIL":
		d.DecUtil = maxPtr(d.DecUtil, v/100)
	case "DCGM_FI_PROF_GR_ENGINE_ACTIVE":
		d.GrActive = maxPtr(d.GrActive, v)
	case "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE":
		d.TensorActive = maxPtr(d.TensorActive, v)
	case "DCGM_FI_PROF_DRAM_ACTIVE":
		d.DRAMActive = maxPtr(d.DRAMActive, v)
	case "DCGM_FI_DEV_FB_USED":
		d.MemUsed = maxPtr(d.MemUsed, v*mib)
	case "DCGM_FI_DEV_FB_FREE":
		d.fbFree = maxPtr(d.fbFree, v*mib)
	case "DCGM_FI_DEV_FB_RESERVED":
		d.fbReserved = maxPtr(d.fbReserved, v*mib)
	case "DCGM_FI_DEV_GPU_TEMP":
		d.TempC = maxPtr(d.TempC, v)
	case "DCGM_FI_DEV_MEMORY_TEMP":
		d.MemTempC = maxPtr(d.MemTempC, v)
	case "DCGM_FI_DEV_POWER_USAGE":
		d.PowerW = maxPtr(d.PowerW, v)
	case "DCGM_FI_DEV_SM_CLOCK":
		d.SMClock = maxPtr(d.SMClock, v)
	case "DCGM_FI_DEV_XID_ERRORS":
		d.XID = maxPtr(d.XID, v)
	case "DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS":
		d.UncorrectableRemapped = maxPtr(d.UncorrectableRemapped, v)
	case "DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS":
		d.CorrectableRemapped = maxPtr(d.CorrectableRemapped, v)
	case "DCGM_FI_DEV_ROW_REMAP_FAILURE":
		d.RowRemapFailure = maxPtr(d.RowRemapFailure, v)
	case "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL":
		d.ECCDoubleBit = maxPtr(d.ECCDoubleBit, v)
	case "DCGM_FI_DEV_PCIE_REPLAY_COUNTER":
		d.PCIeReplays = maxPtr(d.PCIeReplays, v)
	}
}

// maxPtr keeps the larger value when a device has duplicate series (e.g.
// one per pod sharing it, or scraped by two jobs).
func maxPtr(cur *float64, v float64) *float64 {
	if cur != nil && *cur >= v {
		return cur
	}
	return ptr(v)
}

// finish derives the memory total and the health notes.
func (d *Device) finish() {
	if d.MemUsed != nil && d.fbFree != nil {
		t := *d.MemUsed + *d.fbFree
		if d.fbReserved != nil {
			t += *d.fbReserved
		}
		d.MemTotal = &t
	}
	sort.Slice(d.Pods, func(i, j int) bool {
		if d.Pods[i].Namespace != d.Pods[j].Namespace {
			return d.Pods[i].Namespace < d.Pods[j].Namespace
		}
		return d.Pods[i].Name < d.Pods[j].Name
	})
	for _, h := range d.healthIssues() {
		d.Health = append(d.Health, h.Message)
	}
}

func (d *Device) addPod(ref PodRef) {
	for _, p := range d.Pods {
		if p.Namespace == ref.Namespace && p.Name == ref.Name {
			return
		}
	}
	d.Pods = append(d.Pods, ref)
}

// attribution returns the workload pod a series is about, when the exporter
// reports it: exported_pod/exported_namespace (the exporter's pod labels
// renamed at scrape), or pod/namespace when that pod holds GPUs (so not the
// exporter itself, i.e. honorLabels). sel matches the pod's series.
func attribution(m map[string]string, gpuPods map[string]*Pod) (ref PodRef, sel string, ok bool) {
	if p := m["exported_pod"]; p != "" {
		ns := m["exported_namespace"]
		return PodRef{Namespace: ns, Name: p}, `exported_namespace="` + promQuote(ns) + `",exported_pod="` + promQuote(p) + `"`, true
	}
	ns, p := m["namespace"], m["pod"]
	if p != "" && gpuPods[ns+"/"+p] != nil {
		return PodRef{Namespace: ns, Name: p}, `namespace="` + promQuote(ns) + `",pod="` + promQuote(p) + `"`, true
	}
	return PodRef{}, "", false
}
