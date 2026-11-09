package upgrade

import (
	"fmt"
	"slices"
	"sort"
	"strings"

	admissionv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/intstr"
)

const (
	skewDocs   = "https://kubernetes.io/releases/version-skew-policy/"
	drainDocs  = "https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/"
	pdbDocs    = "https://kubernetes.io/docs/tasks/run-application/configure-pdb/"
	hookDocs   = "https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#failure-policy"
	crdDocs    = "https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/#upgrade-existing-objects-to-a-new-stored-version"
	helmAPIDoc = "https://helm.sh/docs/topics/kubernetes_apis/"
	nodeDocs   = "https://kubernetes.io/docs/concepts/architecture/nodes/#condition"
)

func guideAnchor(v Version) string {
	return fmt.Sprintf("%s#v%d-%d", MigrationGuide, v.Major, v.Minor)
}

func ref(group, kind, ns, name string) ObjectRef {
	return ObjectRef{Group: group, Kind: kind, Namespace: ns, Name: name}
}

func refKey(r ObjectRef) string {
	if r.Namespace == "" {
		return r.Kind + "/" + r.Name
	}
	return r.Kind + "/" + r.Namespace + "/" + r.Name
}

func moveTo(c APIChange) string {
	if c.Replacement == "" {
		return "Remove it: " + c.Note + "."
	}
	s := "Move to " + c.Replacement
	if c.Note != "" {
		s += " (" + c.Note + ")"
	}
	return s + "."
}

// ---- removed APIs ----------------------------------------------------------

func (a *analysis) apis() {
	if !a.ok(SrcDiscovery) {
		return
	}
	// Served now, gone after the upgrade: nothing breaks unless something
	// uses them, which the findings below look for.
	byGV := map[string][]APIChange{}
	for _, c := range RemovalsBetween(a.cur, a.target) {
		if slices.Contains(a.in.Served[c.APIVersion()], c.Resource) {
			byGV[c.APIVersion()] = append(byGV[c.APIVersion()], c)
		}
	}
	for gv, cs := range byGV {
		kinds := make([]string, 0, len(cs))
		for _, c := range cs {
			kinds = append(kinds, c.Kind)
		}
		a.add(Finding{
			ID: "apis/served/" + gv, Check: CheckAPIs, Severity: Info,
			Title:  gv + " is removed in " + cs[0].RemovedIn.String(),
			Detail: "served now for " + strings.Join(kinds, ", "),
			Why:    "Clients, manifests and charts that still use " + gv + " will get 404s after the upgrade. Nothing below shows one doing so, but tools outside the cluster (CI, GitOps repos) aren't visible from here.",
			Action: moveTo(cs[0]) + " Search your manifests and charts for apiVersion: " + gv + ".",
			Docs:   guideAnchor(cs[0].RemovedIn),
		})
	}

	// Live objects whose last write (or last kubectl apply) used an API the
	// target no longer serves.
	type objUse struct {
		ref    ObjectRef
		worst  string
		lines  []string
		change APIChange
	}
	uses := map[string]*objUse{}
	var order []string
	for _, u := range a.in.APIUses {
		c, ok := LookupAPI(u.APIVersion, u.Object.Kind)
		if !ok || c.RemovedIn.IsZero() || !a.cur.Before(c.RemovedIn) {
			continue
		}
		sev := Info
		if c.RemovedIn.AtMost(a.target) {
			sev = Warning
			if u.Source == "last-applied" {
				sev = Blocker
			}
		} else if c.DeprecatedIn.IsZero() || a.target.Before(c.DeprecatedIn) {
			continue
		}
		k := refKey(u.Object)
		o := uses[k]
		if o == nil {
			o = &objUse{ref: u.Object, worst: sev, change: c}
			uses[k] = o
			order = append(order, k)
		}
		if severityRank[sev] < severityRank[o.worst] {
			o.worst, o.change = sev, c
		}
		line := u.APIVersion + " in its last kubectl apply"
		if u.Source == "managedFields" {
			line = u.APIVersion + " by " + u.Manager
		}
		if !slices.Contains(o.lines, line) {
			o.lines = append(o.lines, line)
		}
	}
	for _, k := range order {
		o := uses[k]
		c := o.change
		title := fmt.Sprintf("%s %s was written with %s", o.ref.Kind, o.ref.Name, c.APIVersion())
		why := "That API is removed in " + c.RemovedIn.String() + ": whatever writes this object that way will fail after the upgrade."
		if o.worst == Blocker {
			why = "Its last kubectl apply used " + c.APIVersion() + ", removed in " + c.RemovedIn.String() + ": applying the same manifest again will fail after the upgrade. The object itself survives (it is stored in a current version)."
		} else if o.worst == Info {
			title = fmt.Sprintf("%s %s uses deprecated %s", o.ref.Kind, o.ref.Name, c.APIVersion())
			why = c.APIVersion() + " is deprecated and removed in " + c.RemovedIn.String() + ", after this upgrade."
		}
		a.add(Finding{
			ID: "apis/object/" + k, Check: CheckAPIs, Severity: o.worst,
			Title: title, Detail: strings.Join(o.lines, "; "),
			Why: why, Action: moveTo(c) + " Update the manifest or the controller that writes it.",
			Namespace: o.ref.Namespace, Objects: []ObjectRef{o.ref}, Docs: guideAnchor(c.RemovedIn),
		})
	}

	// Helm releases: the stored manifest is what `helm upgrade` diffs
	// against, so a removed API in it breaks the next upgrade of the
	// release even when the chart has moved on.
	for _, r := range a.in.Helm {
		var hit []string
		var objs []ObjectRef
		worst := ""
		var first APIChange
		for _, o := range r.Objects {
			apiVersion := o.Version
			if o.Group != "" {
				apiVersion = o.Group + "/" + o.Version
			}
			c, ok := LookupAPI(apiVersion, o.Kind)
			if !ok || c.RemovedIn.IsZero() || a.target.Before(c.RemovedIn) {
				continue
			}
			sev := Blocker
			if !a.cur.Before(c.RemovedIn) {
				sev = Warning // already gone: the release is stuck today
			}
			if worst == "" || severityRank[sev] < severityRank[worst] {
				worst, first = sev, c
			}
			hit = append(hit, o.Kind+" "+o.Name+" ("+apiVersion+")")
			if c.Replacement != "" {
				g, _ := splitAPIVersion(c.Replacement)
				objs = append(objs, ref(g, o.Kind, o.Namespace, o.Name))
			}
		}
		if worst == "" {
			continue
		}
		sort.Strings(hit)
		why := "The release's stored manifest uses " + first.APIVersion() + ", removed in " + first.RemovedIn.String() + ". Helm compares against it, so `helm upgrade` of this release fails after the upgrade even with a fixed chart."
		if worst == Warning {
			why = "The release's stored manifest uses " + first.APIVersion() + ", which this cluster already doesn't serve: `helm upgrade` of this release fails today."
		}
		a.add(Finding{
			ID: "apis/helm/" + r.Namespace + "/" + r.Name, Check: CheckAPIs, Severity: worst,
			Title:     "Helm release " + r.Name + " uses removed APIs",
			Detail:    fmt.Sprintf("%s, revision %d: %s", r.Chart, r.Revision, strings.Join(hit, ", ")),
			Why:       why,
			Action:    "Upgrade the release to a chart version without them before upgrading the cluster. If it can no longer upgrade, rewrite the stored manifest with the helm-mapkubeapis plugin.",
			Namespace: r.Namespace, Objects: append([]ObjectRef{ref("", "Secret", r.Namespace, r.Secret)}, objs...),
			Docs:    helmAPIDoc,
			Kubectl: []string{"get", "secret", r.Secret, "-n", r.Namespace, "-o", "jsonpath={.metadata.labels}"},
		})
	}

	// Clients the API server has seen calling deprecated APIs since it
	// started.
	for _, d := range a.in.Deprecated {
		gv := d.Version
		if d.Group != "" {
			gv = d.Group + "/" + d.Version
		}
		what := d.Resource
		if d.Subresource != "" {
			what += "/" + d.Subresource
		}
		removed, _ := ParseVersion(d.RemovedRelease)
		sev := Info
		title := "Clients call deprecated " + gv + " " + what
		why := "The API server has served requests for this deprecated API since it last started."
		if !removed.IsZero() && removed.AtMost(a.target) && a.cur.Before(removed) {
			sev = Blocker
			title = "Clients still call " + gv + " " + what
			why = "The API server has served requests for " + gv + " since it last started, and " + removed.String() + " removes it: those clients will fail after the upgrade."
		} else if !removed.IsZero() && !a.cur.Before(removed) {
			continue
		}
		detail := "removed in " + removed.String()
		if removed.IsZero() {
			detail = "no removal scheduled"
		}
		docs := MigrationGuide
		if !removed.IsZero() {
			docs = guideAnchor(removed)
		}
		a.add(Finding{
			ID: "apis/requested/" + gv + "/" + what, Check: CheckAPIs, Severity: sev,
			Title: title, Detail: detail + " · from apiserver_requested_deprecated_apis",
			Why:    why + " The metric doesn't name the client: the API server's audit log, or the deprecation warnings clients print, do.",
			Action: "Find the client (audit log: annotations k8s.io/deprecated) and move it to a current version.",
			Docs:   docs, Kubectl: []string{"get", "--raw", "/metrics"},
		})
	}
}

// ---- version skew ----------------------------------------------------------

// maxKubeletSkew is how many minors a kubelet may trail an API server of
// version v.
func maxKubeletSkew(v Version) int {
	if v.Before(V(28)) {
		return 2
	}
	return 3
}

func (a *analysis) skew() {
	steps := []string{a.cur.String()}
	for v := a.cur.Plus(1); v.AtMost(a.target); v = v.Plus(1) {
		steps = append(steps, v.String())
	}
	if len(steps) > 2 {
		a.add(Finding{
			ID: "skew/steps", Check: CheckSkew, Severity: Warning,
			Title:  "The control plane upgrades one minor at a time",
			Detail: strings.Join(steps, " → "),
			Why:    "Skipping minors isn't supported: each step runs its own storage and API migrations. Every step needs these checks to pass for its own version.",
			Action: "Plan " + plural(len(steps)-1, "upgrade") + ", and check the findings for each target in turn.",
			Docs:   skewDocs,
		})
	}
	if !a.ok(SrcNodes) {
		return
	}
	max := maxKubeletSkew(a.target)
	type bucket struct {
		v     Version
		nodes []ObjectRef
	}
	behind := map[Version]*bucket{}
	ahead := map[Version]*bucket{}
	edge := map[Version]*bucket{}
	put := func(m map[Version]*bucket, v Version, n string) {
		if m[v] == nil {
			m[v] = &bucket{v: v}
		}
		m[v].nodes = append(m[v].nodes, ref("", "Node", "", n))
	}
	cpVersions := map[Version][]ObjectRef{}
	for _, n := range a.in.Nodes {
		kv, ok := ParseVersion(n.Status.NodeInfo.KubeletVersion)
		if !ok {
			continue
		}
		switch d := kv.Behind(a.target); {
		case d < 0:
			put(ahead, kv, n.Name)
		case d > max:
			put(behind, kv, n.Name)
		case d == max:
			put(edge, kv, n.Name)
		}
		if isControlPlane(n.Labels) {
			cpVersions[kv] = append(cpVersions[kv], ref("", "Node", "", n.Name))
		}
	}
	emit := func(m map[Version]*bucket, sev, idPart string, title func(b *bucket) string, why func(b *bucket) string, action string) {
		vs := make([]Version, 0, len(m))
		for v := range m {
			vs = append(vs, v)
		}
		sort.Slice(vs, func(i, j int) bool { return vs[i].Before(vs[j]) })
		for _, v := range vs {
			b := m[v]
			a.add(Finding{
				ID: "skew/" + idPart + "/" + v.String(), Check: CheckSkew, Severity: sev,
				Title: title(b), Detail: nodeList(b.nodes),
				Why: why(b), Action: action, Objects: b.nodes, Docs: skewDocs + "#kubelet",
			})
		}
	}
	t := a.target.String()
	emit(behind, Blocker, "behind", func(b *bucket) string {
		return fmt.Sprintf("%s on kubelet %s, %d minors behind %s", plural(len(b.nodes), "node"), b.v, b.v.Behind(a.target), t)
	}, func(b *bucket) string {
		return fmt.Sprintf("Kubelets may trail the API server by at most %d minors. After the control plane reaches %s these nodes are unsupported, and upgrade tools refuse to go ahead.", max, t)
	}, "Upgrade these nodes (or replace them) first, then the control plane.")
	emit(ahead, Blocker, "ahead", func(b *bucket) string {
		return fmt.Sprintf("%s on kubelet %s, newer than %s", plural(len(b.nodes), "node"), b.v, t)
	}, func(*bucket) string {
		return "A kubelet must never be newer than the API server."
	}, "Upgrade the control plane to at least the kubelets' version.")
	emit(edge, Info, "edge", func(b *bucket) string {
		return fmt.Sprintf("%s on kubelet %s, at the skew limit for %s", plural(len(b.nodes), "node"), b.v, t)
	}, func(*bucket) string {
		return fmt.Sprintf("They are %d minors behind %s, the most allowed: the next control-plane upgrade needs them upgraded first.", max, t)
	}, "Upgrade these nodes soon after the control plane.")

	if len(cpVersions) > 1 {
		var all []ObjectRef
		var vs []string
		for v, ns := range cpVersions {
			all = append(all, ns...)
			vs = append(vs, v.String())
		}
		sort.Strings(vs)
		sort.Slice(all, func(i, j int) bool { return all[i].Name < all[j].Name })
		a.add(Finding{
			ID: "skew/control-plane-nodes", Check: CheckSkew, Severity: Warning,
			Title: "Control-plane nodes run different versions", Detail: "kubelet " + strings.Join(vs, ", "),
			Why:     "A control plane part-way through an upgrade: finish it before starting another.",
			Action:  "Bring every control-plane node to the same version first.",
			Objects: all, Docs: skewDocs + "#kube-apiserver",
		})
	}
	if a.ok(SrcControl) && len(a.in.ControlPlane) > 1 {
		byV := map[string][]ObjectRef{}
		for _, p := range a.in.ControlPlane {
			for _, c := range p.Spec.Containers {
				if c.Name == "kube-apiserver" || strings.Contains(c.Image, "kube-apiserver") {
					tag := imageTag(c.Image)
					byV[tag] = append(byV[tag], ref("", "Pod", p.Namespace, p.Name))
				}
			}
		}
		if len(byV) > 1 {
			var all []ObjectRef
			var vs []string
			for v, ps := range byV {
				all = append(all, ps...)
				vs = append(vs, v)
			}
			sort.Strings(vs)
			a.add(Finding{
				ID: "skew/apiservers", Check: CheckSkew, Severity: Warning,
				Title: "kube-apiserver instances run different versions", Detail: strings.Join(vs, ", "),
				Why:       "API servers within one minor of each other are supported, but mixed versions mean an upgrade is still in progress.",
				Action:    "Finish the current upgrade on every control-plane node first.",
				Namespace: "kube-system", Objects: all, Docs: skewDocs + "#kube-apiserver",
			})
		}
	}
}

func isControlPlane(l map[string]string) bool {
	_, cp := l["node-role.kubernetes.io/control-plane"]
	_, master := l["node-role.kubernetes.io/master"]
	return cp || master
}

func nodeList(refs []ObjectRef) string {
	names := make([]string, 0, len(refs))
	for _, r := range refs {
		names = append(names, r.Name)
	}
	return shortList(names)
}

// shortList is "a, b, c" or "a, b, c and 4 more".
func shortList(names []string) string {
	sort.Strings(names)
	if len(names) <= 3 {
		return strings.Join(names, ", ")
	}
	return strings.Join(names[:3], ", ") + fmt.Sprintf(" and %d more", len(names)-3)
}

// ---- drain blockers --------------------------------------------------------

func (a *analysis) drain() {
	if a.ok(SrcPDBs) {
		for _, p := range a.in.PDBs {
			st := p.Status
			if st.ExpectedPods == 0 {
				continue
			}
			r := ref("policy", "PodDisruptionBudget", p.Namespace, p.Name)
			f := Finding{
				ID: "drain/pdb/" + p.Namespace + "/" + p.Name, Check: CheckDrain, Namespace: p.Namespace, Objects: []ObjectRef{r},
				Docs: pdbDocs,
			}
			switch {
			case isZero(p.Spec.MaxUnavailable):
				f.Severity, f.Title = Blocker, "PDB "+p.Name+" allows no evictions"
				f.Detail = "maxUnavailable: 0"
			case p.Spec.MinAvailable != nil && covers(p.Spec.MinAvailable, st.ExpectedPods):
				f.Severity, f.Title = Blocker, "PDB "+p.Name+" allows no evictions"
				f.Detail = fmt.Sprintf("minAvailable: %s of %d pods", p.Spec.MinAvailable.String(), st.ExpectedPods)
			case st.DisruptionsAllowed == 0 && st.CurrentHealthy >= st.DesiredHealthy:
				f.Severity, f.Title = Blocker, "PDB "+p.Name+" allows no evictions"
				f.Detail = fmt.Sprintf("%d healthy, %d required", st.CurrentHealthy, st.DesiredHealthy)
			case st.DisruptionsAllowed == 0:
				f.Severity, f.Title = Warning, "PDB "+p.Name+" is unhealthy and allows no evictions"
				f.Detail = fmt.Sprintf("%d of %d healthy, %d required", st.CurrentHealthy, st.ExpectedPods, st.DesiredHealthy)
				f.Why = "Its pods aren't healthy enough to lose one, so draining a node they run on waits until they recover (or the drain times out)."
				f.Action = "Fix the unhealthy pods before the upgrade."
			default:
				continue
			}
			if f.Why == "" {
				f.Why = "Node drains evict through this budget, which never allows one: draining any node running its pods hangs until the upgrade times out."
				f.Action = "Add replicas, or loosen the budget (maxUnavailable: 1) for the upgrade."
			}
			a.add(f)
		}
	}

	type group struct{ refs []ObjectRef }
	perNS := func(m map[string]*group, ns string, r ObjectRef) {
		g := m[ns]
		if g == nil {
			g = &group{}
			m[ns] = g
		}
		for _, x := range g.refs {
			if x == r {
				return
			}
		}
		g.refs = append(g.refs, r)
	}
	emit := func(m map[string]*group, id, sev string, title func(n int) string, why, action, docs string) {
		nss := make([]string, 0, len(m))
		for ns := range m {
			nss = append(nss, ns)
		}
		sort.Strings(nss)
		for _, ns := range nss {
			g := m[ns]
			sort.Slice(g.refs, func(i, j int) bool { return g.refs[i].Name < g.refs[j].Name })
			names := make([]string, 0, len(g.refs))
			for _, r := range g.refs {
				names = append(names, r.Name)
			}
			a.add(Finding{
				ID: "drain/" + id + "/" + ns, Check: CheckDrain, Severity: sev,
				Title: title(len(g.refs)) + " in " + ns, Detail: shortList(names),
				Why: why, Action: action, Namespace: ns, Objects: g.refs, Docs: docs,
			})
		}
	}

	if a.ok(SrcDeployments) && a.ok(SrcStatefuls) {
		single := map[string]*group{}
		for _, d := range a.in.Deployments {
			if replicas(d.Spec.Replicas) == 1 {
				perNS(single, d.Namespace, ref("apps", "Deployment", d.Namespace, d.Name))
			}
		}
		for _, s := range a.in.StatefulSets {
			if replicas(s.Spec.Replicas) == 1 {
				perNS(single, s.Namespace, ref("apps", "StatefulSet", s.Namespace, s.Name))
			}
		}
		emit(single, "single", Warning, func(n int) string {
			if n == 1 {
				return "1 single-replica workload"
			}
			return fmt.Sprintf("%d single-replica workloads", n)
		}, "With one replica, the workload is down from the moment its node drains until the pod is running elsewhere.",
			"Run 2+ replicas (with a PDB) for anything that must stay up, or accept the downtime.", drainDocs)
	}

	if !a.ok(SrcPods) {
		return
	}
	owner := a.ownerResolver()
	bare := map[string]*group{}
	empty := map[string]*group{}
	pinned := map[string]*group{}
	localClaims := a.localClaims()
	for _, p := range a.in.Pods {
		if p.Status.Phase == corev1.PodSucceeded || p.Status.Phase == corev1.PodFailed {
			continue
		}
		if _, mirror := p.Annotations[corev1.MirrorPodAnnotationKey]; mirror {
			continue
		}
		ctl := metav1.GetControllerOf(&p)
		if ctl != nil && ctl.Kind == "DaemonSet" {
			continue
		}
		if ctl == nil {
			perNS(bare, p.Namespace, ref("", "Pod", p.Namespace, p.Name))
			continue
		}
		w := owner(p.Namespace, ctl)
		for _, v := range p.Spec.Volumes {
			if v.EmptyDir != nil {
				perNS(empty, p.Namespace, w)
			}
			if v.PersistentVolumeClaim != nil && localClaims[p.Namespace+"/"+v.PersistentVolumeClaim.ClaimName] {
				perNS(pinned, p.Namespace, w)
			}
		}
	}
	emit(bare, "bare", Warning, func(n int) string {
		if n == 1 {
			return "1 pod without a controller"
		}
		return fmt.Sprintf("%d pods without a controller", n)
	}, "Nothing recreates a bare pod: draining its node deletes it for good, and `kubectl drain` refuses to start without --force.",
		"Run it under a Deployment, StatefulSet or Job, or plan to recreate it by hand.", drainDocs)
	emit(pinned, "local", Warning, func(n int) string {
		if n == 1 {
			return "1 workload on node-local volumes"
		}
		return fmt.Sprintf("%d workloads on node-local volumes", n)
	}, "Their volumes live on one node (local or hostPath PersistentVolumes), so their pods can't move while it drains: they stay Pending until the node is back.",
		"Expect downtime for these while their node upgrades, or move them to network storage.", drainDocs)
	emit(empty, "emptydir", Info, func(n int) string {
		if n == 1 {
			return "1 workload with emptyDir data"
		}
		return fmt.Sprintf("%d workloads with emptyDir data", n)
	}, "emptyDir volumes are deleted with the pod, so a drain loses what's in them (kubectl drain needs --delete-emptydir-data).",
		"Fine for caches and scratch space; move anything that must survive to a PersistentVolume.", drainDocs)
}

func replicas(r *int32) int32 {
	if r == nil {
		return 1
	}
	return *r
}

func isZero(v *intstr.IntOrString) bool {
	if v == nil {
		return false
	}
	if v.Type == intstr.Int {
		return v.IntVal == 0
	}
	return strings.TrimSpace(v.StrVal) == "0%"
}

// covers reports whether minAvailable asks for all expected pods.
func covers(v *intstr.IntOrString, expected int32) bool {
	if v.Type == intstr.Int {
		return v.IntVal >= expected
	}
	return strings.TrimSpace(v.StrVal) == "100%"
}

// ownerResolver maps a pod's controller onto its workload: a ReplicaSet
// named "<deployment>-<hash>" onto that Deployment when it exists.
func (a *analysis) ownerResolver() func(ns string, ctl *metav1.OwnerReference) ObjectRef {
	deps := map[string]bool{}
	for _, d := range a.in.Deployments {
		deps[d.Namespace+"/"+d.Name] = true
	}
	return func(ns string, ctl *metav1.OwnerReference) ObjectRef {
		group, _ := splitAPIVersion(ctl.APIVersion)
		if ctl.Kind == "ReplicaSet" {
			if i := strings.LastIndex(ctl.Name, "-"); i > 0 && deps[ns+"/"+ctl.Name[:i]] {
				return ref("apps", "Deployment", ns, ctl.Name[:i])
			}
		}
		return ref(group, ctl.Kind, ns, ctl.Name)
	}
}

// localClaims are the claims ("ns/name") bound to local or hostPath
// volumes.
func (a *analysis) localClaims() map[string]bool {
	out := map[string]bool{}
	if !a.ok(SrcPVs) || !a.ok(SrcPVCs) {
		return out
	}
	local := map[string]bool{}
	for _, pv := range a.in.PVs {
		if pv.Spec.Local != nil || pv.Spec.HostPath != nil {
			local[pv.Name] = true
		}
	}
	for _, c := range a.in.PVCs {
		if c.Spec.VolumeName != "" && local[c.Spec.VolumeName] {
			out[c.Namespace+"/"+c.Name] = true
		}
	}
	return out
}

// ---- admission webhooks ----------------------------------------------------

// kubeSystemLabels are the labels every kube-system namespace has.
var kubeSystemLabels = labels.Set{"kubernetes.io/metadata.name": "kube-system"}

type hook struct {
	config   ObjectRef
	name     string
	policy   *admissionv1.FailurePolicyType
	service  *admissionv1.ServiceReference
	rules    []admissionv1.RuleWithOperations
	nsSel    *metav1.LabelSelector
	objSel   *metav1.LabelSelector
	mutating bool
}

func (a *analysis) webhooks() {
	if !a.ok(SrcWebhooks) {
		return
	}
	var hooks []hook
	for _, c := range a.in.Validating {
		r := ref("admissionregistration.k8s.io", "ValidatingWebhookConfiguration", "", c.Name)
		for _, w := range c.Webhooks {
			hooks = append(hooks, hook{r, w.Name, w.FailurePolicy, w.ClientConfig.Service, w.Rules, w.NamespaceSelector, w.ObjectSelector, false})
		}
	}
	for _, c := range a.in.Mutating {
		r := ref("admissionregistration.k8s.io", "MutatingWebhookConfiguration", "", c.Name)
		for _, w := range c.Webhooks {
			hooks = append(hooks, hook{r, w.Name, w.FailurePolicy, w.ClientConfig.Service, w.Rules, w.NamespaceSelector, w.ObjectSelector, true})
		}
	}
	for _, h := range hooks {
		if h.policy != nil && *h.policy != admissionv1.Fail {
			continue // Ignore: a broken webhook is skipped, not fatal
		}
		objs := []ObjectRef{h.config}
		var svc string
		if h.service != nil {
			objs = append(objs, ref("", "Service", h.service.Namespace, h.service.Name))
			svc = h.service.Namespace + "/" + h.service.Name
		}
		f := Finding{ID: "webhooks/" + h.config.Kind + "/" + h.config.Name + "/" + h.name, Check: CheckWebhooks, Objects: objs, Docs: hookDocs}
		broad, what := broadRules(h.rules)
		ks := matchesKubeSystem(h.nsSel) && emptySelector(h.objSel)
		n, known := a.in.ReadyEndpoints[ServiceKey(svc)]
		switch {
		case svc != "" && a.ok(SrcEndpoints) && known && n == 0:
			f.Severity = Blocker
			f.Title = "Webhook " + h.name + " has no ready endpoints"
			f.Detail = "failurePolicy: Fail · service " + svc + " · matches " + what
			f.Why = "With failurePolicy Fail and nothing behind its Service, every request it matches is rejected right now: pods recreated during the node rollout can't be admitted."
			f.Action = "Fix (or scale up) the webhook's backend, or set failurePolicy: Ignore until it is healthy."
		case broad && ks:
			f.Severity = Warning
			f.Title = "Webhook " + h.name + " can block kube-system"
			f.Detail = "failurePolicy: Fail · matches " + what + " in every namespace"
			f.Why = "If its backend goes down while nodes roll (it runs on those nodes too), nothing it matches can be created, including the system pods the cluster needs to recover."
			f.Action = "Exclude kube-system with a namespaceSelector, and run its backend with 2+ replicas and a PDB."
		default:
			continue
		}
		a.add(f)
	}
}

// broadRules reports whether rules match every resource in every group, or
// pod creation, and says what they match.
func broadRules(rules []admissionv1.RuleWithOperations) (bool, string) {
	for _, r := range rules {
		creates := slices.Contains(r.Operations, admissionv1.OperationAll) || slices.Contains(r.Operations, admissionv1.Create)
		allRes := slices.Contains(r.Resources, "*") || slices.Contains(r.Resources, "*/*")
		allGroups := slices.Contains(r.APIGroups, "*")
		if allRes && allGroups {
			return true, "all resources"
		}
		if creates && slices.Contains(r.APIGroups, "") && (slices.Contains(r.Resources, "pods") || allRes) {
			return true, "pod creation"
		}
	}
	if len(rules) == 0 {
		return false, "nothing"
	}
	var res []string
	for _, r := range rules {
		res = append(res, r.Resources...)
	}
	return false, strings.Join(res, ", ")
}

func matchesKubeSystem(sel *metav1.LabelSelector) bool {
	if sel == nil {
		return true
	}
	s, err := metav1.LabelSelectorAsSelector(sel)
	return err == nil && s.Matches(kubeSystemLabels)
}

func emptySelector(sel *metav1.LabelSelector) bool {
	return sel == nil || (len(sel.MatchLabels) == 0 && len(sel.MatchExpressions) == 0)
}

// ---- CRD storage versions --------------------------------------------------

func (a *analysis) crds() {
	if !a.ok(SrcCRDs) {
		return
	}
	for _, c := range a.in.CRDs {
		r := ref("apiextensions.k8s.io", "CustomResourceDefinition", "", c.Name)
		for _, sv := range c.StoredVersions {
			i := slices.IndexFunc(c.Versions, func(v CRDVersion) bool { return v.Name == sv })
			f := Finding{
				ID: "crds/" + c.Name + "/" + sv, Check: CheckCRDs, Objects: []ObjectRef{r}, Docs: crdDocs,
				Kubectl: []string{"get", "crd", c.Name, "-o", "jsonpath={.status.storedVersions}"},
				Action:  "Re-write every " + c.Kind + " so it is stored in the current version (a storage migration, e.g. kube-storage-version-migrator), then drop " + sv + " from status.storedVersions.",
			}
			switch {
			case i < 0 || !c.Versions[i].Served:
				f.Severity = Warning
				f.Title = c.Kind + " objects are stored as " + sv + ", which isn't served"
				f.Detail = c.Name + " · stored versions " + strings.Join(c.StoredVersions, ", ")
				f.Why = "Objects still stored in a version the CRD no longer serves block removing that version (and an operator upgrade that drops it) until they are migrated."
			case c.Versions[i].Deprecated:
				f.Severity = Info
				f.Title = c.Kind + " objects are stored as deprecated " + sv
				f.Detail = c.Name + " · stored versions " + strings.Join(c.StoredVersions, ", ")
				f.Why = "The CRD's owner has deprecated " + sv + ": the version that drops it needs the objects migrated first."
			default:
				continue
			}
			a.add(f)
		}
	}
}

// ---- node health -----------------------------------------------------------

func (a *analysis) nodes() {
	if !a.ok(SrcNodes) {
		return
	}
	for _, n := range a.in.Nodes {
		var problems []string
		sev := ""
		ready := false
		for _, c := range n.Status.Conditions {
			switch c.Type {
			case corev1.NodeReady:
				ready = c.Status == corev1.ConditionTrue
			case corev1.NodeDiskPressure, corev1.NodeMemoryPressure, corev1.NodePIDPressure:
				if c.Status == corev1.ConditionTrue {
					problems = append(problems, string(c.Type))
					sev = Warning
				}
			}
		}
		if n.Spec.Unschedulable {
			problems = append([]string{"cordoned"}, problems...)
			sev = Warning
		}
		if !ready {
			problems = append([]string{"NotReady"}, problems...)
			sev = Blocker
		}
		if sev == "" {
			continue
		}
		f := Finding{
			ID: "nodes/" + n.Name, Check: CheckNodes, Severity: sev,
			Title: "Node " + n.Name + " is " + problems[0], Detail: strings.Join(problems, ", "),
			Objects: []ObjectRef{ref("", "Node", "", n.Name)}, Docs: nodeDocs,
		}
		switch {
		case !ready:
			f.Why = "A NotReady node can't be drained cleanly or upgraded in place: its pods are stuck Terminating and the rollout stalls on it."
			f.Action = "Repair or remove the node before upgrading."
		case n.Spec.Unschedulable && len(problems) == 1:
			f.Why = "A cordoned node is probably mid-maintenance, and takes no evicted pods: there is less room for the workloads the rollout moves."
			f.Action = "Finish whatever cordoned it and uncordon it, or remove it."
		default:
			f.Why = "A node under pressure evicts pods by itself; with the rollout moving pods onto the remaining nodes, it is likely to get worse."
			f.Action = "Free up the resource (or add capacity) before upgrading."
		}
		a.add(f)
	}
}

// ---- add-ons ---------------------------------------------------------------

type addon struct {
	name   string
	match  func(image string) bool
	docs   string
	advice string
}

func imageHas(parts ...string) func(string) bool {
	return func(img string) bool {
		repo := imageRepo(img)
		for _, p := range parts {
			if strings.HasSuffix(repo, p) {
				return true
			}
		}
		return false
	}
}

var addons = []addon{
	{"ingress-nginx", imageHas("ingress-nginx/controller", "ingress-nginx/controller-chroot"), "https://github.com/kubernetes/ingress-nginx#supported-versions-table", ""},
	{"cert-manager", imageHas("cert-manager-controller"), "https://cert-manager.io/docs/releases/", ""},
	{"CoreDNS", imageHas("/coredns", "coredns/coredns"), "https://github.com/coredns/deployment/blob/master/kubernetes/CoreDNS-k8s_version.md", ""},
	{"Cilium", imageHas("cilium/cilium"), "https://docs.cilium.io/en/stable/network/kubernetes/compatibility/", ""},
	{"Calico", imageHas("calico/node"), "https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements", ""},
	{"metrics-server", imageHas("metrics-server/metrics-server", "/metrics-server"), "https://github.com/kubernetes-sigs/metrics-server#compatibility-matrix", ""},
	{"kube-proxy", imageHas("/kube-proxy", "kube-proxy"), skewDocs + "#kube-proxy", "kube-proxy follows the kubelet's skew rules: upgrade it with the nodes."},
}

func (a *analysis) addons() {
	type found struct {
		addon   addon
		version string
		obj     ObjectRef
	}
	var out []found
	seen := map[string]bool{}
	look := func(kind, ns, name string, l map[string]string, containers []corev1.Container) {
		for _, ad := range addons {
			for _, c := range containers {
				if !ad.match(c.Image) {
					continue
				}
				v := imageTag(c.Image)
				if v == "" {
					v = l["app.kubernetes.io/version"]
				}
				k := ad.name + "|" + ns + "/" + name
				if !seen[k] {
					seen[k] = true
					out = append(out, found{ad, v, ref("apps", kind, ns, name)})
				}
			}
		}
	}
	if a.ok(SrcDeployments) {
		for _, d := range a.in.Deployments {
			look("Deployment", d.Namespace, d.Name, d.Labels, d.Spec.Template.Spec.Containers)
		}
	}
	if a.ok(SrcDaemonSets) {
		for _, d := range a.in.DaemonSets {
			look("DaemonSet", d.Namespace, d.Name, d.Labels, d.Spec.Template.Spec.Containers)
		}
	}
	t := "v" + a.target.String()
	for _, f := range out {
		title := f.addon.name
		if f.version != "" {
			title += " " + f.version
		}
		action := "Check its compatibility with " + t + " and upgrade it first if needed."
		if f.addon.advice != "" {
			action = f.addon.advice
		}
		a.add(Finding{
			ID: "addons/" + f.addon.name + "/" + f.obj.Namespace + "/" + f.obj.Name, Check: CheckAddons, Severity: Info,
			Title: title, Detail: f.obj.Kind + " " + f.obj.Namespace + "/" + f.obj.Name,
			Why:    "Add-ons support a range of Kubernetes versions: an old one can break on, or block, " + t + ".",
			Action: action, Namespace: f.obj.Namespace, Objects: []ObjectRef{f.obj}, Docs: f.addon.docs,
		})
	}
}

// imageRepo is the image without its tag or digest.
func imageRepo(img string) string {
	if i := strings.Index(img, "@"); i >= 0 {
		img = img[:i]
	}
	if i := strings.LastIndex(img, ":"); i > strings.LastIndex(img, "/") {
		img = img[:i]
	}
	return img
}

// imageTag is the image's tag ("" when it has none).
func imageTag(img string) string {
	if i := strings.Index(img, "@"); i >= 0 {
		img = img[:i]
	}
	if i := strings.LastIndex(img, ":"); i > strings.LastIndex(img, "/") {
		return img[i+1:]
	}
	return ""
}
