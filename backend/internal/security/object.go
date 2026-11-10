package security

import (
	"github.com/matty234/k8sman/backend/internal/kube"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// maxObjectCVEs caps the CVEs returned per container image.
const maxObjectCVEs = 300

// ObjectImage is one container's image of an object, with its full scan
// result when there is one.
type ObjectImage struct {
	Container string     `json:"container"`
	Image     string     `json:"image"`
	Scanned   bool       `json:"scanned"`
	Source    string     `json:"source,omitempty"` // trivy-operator | trivy-cli
	ScannedAt string     `json:"scannedAt,omitempty"`
	Counts    VulnCounts `json:"counts"`
	// CVEs, most severe and fixable first (deduplicated, capped).
	CVEs []CVE `json:"cves"`
	// Report is the VulnerabilityReport read, if any.
	Report *ObjectRef `json:"report,omitempty"`
}

// ObjectResult is the GET /api/security/object payload: the security
// findings and image scans of one Pod or workload.
type ObjectResult struct {
	Object ObjectRef `json:"object"`
	// Target is what findings are reported against: the object itself, or
	// the controller at the top of its owner chain (a Pod's Deployment).
	Target   ObjectRef        `json:"target"`
	Findings []Finding        `json:"findings"`
	Ignored  []IgnoredFinding `json:"ignored"`
	Images   []ObjectImage    `json:"images"`
	// TrivyOperator is true when the VulnerabilityReport CRD is served.
	TrivyOperator bool              `json:"trivyOperator"`
	Pending       []string          `json:"pending,omitempty"`
	Errors        map[string]string `json:"errors,omitempty"`
}

// AnalyzeObject runs the analysis over in (one namespace) and keeps what
// concerns obj: the findings against it (or its top owner) after rules, and
// its containers' images with every CVE of their latest report. Image
// vulnerability findings are left out: the images carry them in full.
func AnalyzeObject(in Input, obj ObjectRef, rules []IgnoreRule) *ObjectResult {
	a := analyze(in)
	ApplyIgnores(a.res, rules)
	target, direct := a.targetOf(obj)
	out := &ObjectResult{Object: obj, Target: target, Findings: []Finding{}, Ignored: []IgnoredFinding{}, Images: []ObjectImage{},
		TrivyOperator: in.TrivyOperator, Pending: a.res.Pending}
	concerns := func(f Finding) bool {
		if f.Check == "images.vulnerable" {
			return false
		}
		for _, o := range f.Objects {
			if sameObject(o, target) {
				return true
			}
		}
		return false
	}
	for _, f := range a.res.Findings {
		if concerns(f) {
			out.Findings = append(out.Findings, f)
		}
	}
	for _, f := range a.res.Ignored {
		if concerns(f.Finding) {
			out.Ignored = append(out.Ignored, f)
		}
	}
	spec := a.specOf(obj)
	if spec == nil {
		return out
	}
	imagesPending := false
	for _, p := range a.res.Pending {
		imagesPending = imagesPending || p == CatImages
	}
	for _, c := range allContainers(spec) {
		img := ObjectImage{Container: c.Name, Image: c.Image, CVEs: []CVE{}}
		if !imagesPending {
			if r := a.reportFor(target, direct, c.Name); r != nil {
				cves := reportVulns(r)
				SortCVEs(cves)
				cves = dedupeByPackage(cves)
				img.Scanned, img.Source, img.ScannedAt = true, "trivy-operator", kube.Str(r.Object, "report", "updateTimestamp")
				img.Counts = Tally(cves)
				img.CVEs = cves[:min(len(cves), maxObjectCVEs)]
				img.Report = &ObjectRef{Group: "aquasecurity.github.io", Kind: "VulnerabilityReport", Name: r.GetName(), Namespace: r.GetNamespace()}
			}
		}
		out.Images = append(out.Images, img)
	}
	return out
}

func sameObject(a, b ObjectRef) bool {
	return a.Namespace == b.Namespace && a.Kind == b.Kind && a.Name == b.Name
}

func dedupeByPackage(cs []CVE) []CVE {
	out := make([]CVE, 0, len(cs))
	seen := map[string]bool{}
	for _, c := range cs {
		k := c.ID + "|" + c.Package
		if !seen[k] {
			seen[k] = true
			out = append(out, c)
		}
	}
	return out
}

// targetOf resolves obj to the unit its findings are reported against, and
// the objects a report may name directly (obj and its controller), most
// specific first.
func (a *analyzer) targetOf(obj ObjectRef) (ObjectRef, []ObjectRef) {
	direct := []ObjectRef{obj}
	switch obj.Kind {
	case "Pod":
		for i := range a.in.Pods {
			p := &a.in.Pods[i]
			if p.Namespace != obj.Namespace || p.Name != obj.Name {
				continue
			}
			if c := kube.ControllerOf(p.OwnerReferences); c != nil {
				direct = append(direct, *refFromOwner(p.Namespace, c))
			}
			if o := a.topOwner(p.Namespace, p.OwnerReferences); o != nil {
				return *o, direct
			}
		}
	case "ReplicaSet":
		if o := a.rsOwn[kube.Key(obj.Namespace, obj.Name)]; o != nil {
			return *o, direct
		}
	case "Job":
		if o := a.jobOwn[kube.Key(obj.Namespace, obj.Name)]; o != nil {
			return *o, direct
		}
	}
	return obj, direct
}

// specOf is obj's pod spec: a Pod's own, a workload's template.
func (a *analyzer) specOf(obj ObjectRef) *corev1.PodSpec {
	match := func(ns, name string) bool { return ns == obj.Namespace && name == obj.Name }
	switch obj.Kind {
	case "Pod":
		for i := range a.in.Pods {
			if p := &a.in.Pods[i]; match(p.Namespace, p.Name) {
				return &p.Spec
			}
		}
	case "Deployment":
		for i := range a.in.Deployments {
			if d := &a.in.Deployments[i]; match(d.Namespace, d.Name) {
				return &d.Spec.Template.Spec
			}
		}
	case "StatefulSet":
		for i := range a.in.StatefulSets {
			if d := &a.in.StatefulSets[i]; match(d.Namespace, d.Name) {
				return &d.Spec.Template.Spec
			}
		}
	case "DaemonSet":
		for i := range a.in.DaemonSets {
			if d := &a.in.DaemonSets[i]; match(d.Namespace, d.Name) {
				return &d.Spec.Template.Spec
			}
		}
	case "ReplicaSet":
		for i := range a.in.ReplicaSets {
			if d := &a.in.ReplicaSets[i]; match(d.Namespace, d.Name) {
				return &d.Spec.Template.Spec
			}
		}
	case "Job":
		for i := range a.in.Jobs {
			if d := &a.in.Jobs[i]; match(d.Namespace, d.Name) {
				return &d.Spec.Template.Spec
			}
		}
	case "CronJob":
		for i := range a.in.CronJobs {
			if d := &a.in.CronJobs[i]; match(d.Namespace, d.Name) {
				return &d.Spec.JobTemplate.Spec.Template.Spec
			}
		}
	}
	return nil
}

// reportFor picks the VulnerabilityReport of container in target: one that
// names a direct object (the pod's own ReplicaSet) first, else the most
// recently updated.
func (a *analyzer) reportFor(target ObjectRef, direct []ObjectRef, container string) *unstructured.Unstructured {
	var best *unstructured.Unstructured
	bestRank, bestUpdated := len(direct), ""
	for i := range a.in.VulnerabilityReports {
		r := &a.in.VulnerabilityReports[i]
		if r.GetNamespace() != target.Namespace || r.GetLabels()["trivy-operator.container.name"] != container {
			continue
		}
		kind, name, _ := reportResource(r)
		rank := len(direct)
		for j, d := range direct {
			if d.Kind == kind && d.Name == name {
				rank = j
				break
			}
		}
		if rank == len(direct) {
			u := a.reportTarget(r)
			if u == nil || !sameObject(u.ref, target) {
				continue
			}
		}
		updated := kube.Str(r.Object, "report", "updateTimestamp")
		if best == nil || rank < bestRank || (rank == bestRank && updated > bestUpdated) {
			best, bestRank, bestUpdated = r, rank, updated
		}
	}
	return best
}
