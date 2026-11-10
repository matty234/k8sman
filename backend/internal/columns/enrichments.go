package columns

import (
	"strings"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// Field is one enriched value the backend merges into objects under
// `.k8sman` before column evaluation (see metrics.Decorator). Path is the
// jq path a column query reads; Type is the cell type that suits it ("" for
// plain string).
type Field struct {
	Path        string `json:"path"`
	Description string `json:"description"`
	Type        string `json:"type,omitempty"`
}

// enrichment declares the fields one decorator adds, for the kinds it runs on.
type enrichment struct {
	applies func(rt cluster.ResourceType) bool
	fields  []Field
}

// enrichments is the registry the column editor lists as "Computed". A new
// decorator adds an entry here (and is only run when a column reads
// `.k8sman`, see Evaluator.UsesEnrichment).
var enrichments = []enrichment{
	{
		applies: func(rt cluster.ResourceType) bool { return rt.Group == "" && rt.Resource == "pods" },
		fields: []Field{
			{".k8sman.usage.cpuMillis", "CPU in use, millicores (metrics-server)", "number"},
			{".k8sman.usage.memoryBytes", "Memory in use, bytes", "number"},
			{".k8sman.usage.cpuPercent", "CPU as a percent of its limit or request", "percent"},
			{".k8sman.usage.memoryPercent", "Memory as a percent of its limit or request", "percent"},
			{".k8sman.usage.cpuBase", "CPU the percent is measured against, cores", "number"},
			{".k8sman.usage.memoryBase", "Memory the percent is measured against, bytes", "number"},
			{".k8sman.usage.containers", "Per-container usage, keyed by container name", ""},
		},
	},
	{
		applies: func(rt cluster.ResourceType) bool { return rt.Group == "" && rt.Resource == "nodes" },
		fields: []Field{
			{".k8sman.usage.cpuMillis", "CPU in use, millicores (metrics-server)", "number"},
			{".k8sman.usage.memoryBytes", "Memory in use, bytes", "number"},
			{".k8sman.usage.cpuPercent", "CPU as a percent of allocatable", "percent"},
			{".k8sman.usage.memoryPercent", "Memory as a percent of allocatable", "percent"},
			{".k8sman.usage.cpuAllocatableMillis", "Allocatable CPU, millicores", "number"},
			{".k8sman.usage.memoryAllocatableBytes", "Allocatable memory, bytes", "number"},
		},
	},
	{
		applies: func(rt cluster.ResourceType) bool { return rt.Group == "" && rt.Resource == "persistentvolumeclaims" },
		fields: []Field{
			{".k8sman.usage.usedBytes", "Disk space used, bytes (Prometheus or kubelet)", "number"},
			{".k8sman.usage.capacityBytes", "Volume capacity, bytes", "number"},
			{".k8sman.usage.availableBytes", "Disk space free, bytes", "number"},
			{".k8sman.usage.percent", "Used as a percent of capacity", "percent"},
		},
	},
}

// Enrichments lists the `.k8sman.*` fields available for a resource.
func Enrichments(rt cluster.ResourceType) []Field {
	out := []Field{}
	for _, e := range enrichments {
		if e.applies(rt) {
			out = append(out, e.fields...)
		}
	}
	return out
}

// UsesEnrichment reports whether any column reads `.k8sman`, so decorators
// need to run. It is decided once, when the evaluator is built. A plain
// substring match is deliberately conservative: a false positive only costs a
// fetch, a false negative would blank a column.
func (e *Evaluator) UsesEnrichment() bool { return e.enriched }

// enrichmentReader is implemented by plugin column programs that can say
// whether their CEL reads `object.k8sman` (the decorated object is what
// they are evaluated against).
type enrichmentReader interface{ ReadsK8sman() bool }

func usesEnrichment(cols []Column) bool {
	for _, c := range cols {
		if r, ok := c.Program.(enrichmentReader); ok && r.ReadsK8sman() {
			return true
		}
		if strings.Contains(c.Query, ".k8sman") || strings.Contains(c.Query, `"k8sman"`) {
			return true
		}
	}
	return false
}
