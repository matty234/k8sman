package security

import "slices"

// workloadSources are the lists every category builds on: workloads and
// their pods (the units findings are reported against).
var workloadSources = []string{"pods", "deployments", "statefulsets", "daemonsets", "replicasets", "jobs", "cronjobs"}

// categorySources names, per category, the lists (by resource name, as the
// server names its sources) whose findings feed it besides workloadSources.
// A category whose list is still loading is pending: its findings and tiles
// are unknown, not zero.
var categorySources = map[string][]string{
	CatNetwork: {"namespaces", "services", "ingresses", "networkpolicies", "gateways", "httproutes"},
	CatRBAC: {"serviceaccounts", "roles", "rolebindings", "clusterroles", "clusterrolebindings",
		"rbacassessmentreports", "clusterrbacassessmentreports"},
	CatWorkloads: {"namespaces", "configauditreports"},
	CatImages:    {"vulnerabilityreports", "exposedsecretreports"},
	// Best practices also report on Services, Ingresses and Gateways (no
	// TLS, privileged NodePorts) and on NetworkPolicy/RBAC objects.
	CatPractices: {"services", "ingresses", "gateways", "httproutes", "networkpolicies", "serviceaccounts",
		"roles", "rolebindings", "clusterroles", "clusterrolebindings"},
}

// PendingCategories maps the sources still listing onto the categories that
// need them, in display order.
func PendingCategories(sources []string) []string {
	out := []string{}
	if len(sources) == 0 {
		return out
	}
	needs := func(list []string) bool {
		return slices.ContainsFunc(sources, func(s string) bool { return slices.Contains(list, s) })
	}
	all := needs(workloadSources)
	for _, c := range categoryTitles {
		if all || needs(categorySources[c.id]) {
			out = append(out, c.id)
		}
	}
	return out
}

// dropPending removes what was computed for pending categories (from
// incomplete lists): their findings, and the sections that belong to them.
func (a *analyzer) dropPending() {
	if len(a.in.Pending) == 0 {
		return
	}
	pending := func(c string) bool { return slices.Contains(a.in.Pending, c) }
	a.res.Findings = slices.DeleteFunc(a.res.Findings, func(f Finding) bool { return pending(f.Category) })
	if pending(CatRBAC) {
		a.res.Permissive = []Grant{}
	}
	if pending(CatNetwork) {
		a.res.Network = []NamespaceNetwork{}
	}
	if pending(CatImages) {
		a.res.Images = []ImageSummary{}
		a.res.TopCVEs = []CVE{}
	}
}
