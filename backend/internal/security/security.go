// Package security analyses a snapshot of cluster objects and reports security
// findings: network exposure, permissive or stale RBAC, workload hardening
// against the Pod Security Standards, general best practices, and image
// vulnerabilities from Trivy Operator reports.
//
// Like the health overview, it is pure: the caller lists the objects (one list
// per type) and passes them in, so every check is unit-testable with
// constructed objects. See docs/SECURITY.md for the checks and severities.
package security

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/matty234/k8sman/backend/internal/kube"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// Severity levels, most severe first.
const (
	Critical = "critical"
	High     = "high"
	Medium   = "medium"
	Low      = "low"
	Info     = "info"
)

// Severities in display order.
var Severities = []string{Critical, High, Medium, Low, Info}

var sevRank = map[string]int{Critical: 0, High: 1, Medium: 2, Low: 3, Info: 4}

// Category ids.
const (
	CatNetwork   = "network"
	CatRBAC      = "rbac"
	CatWorkloads = "workloads"
	CatImages    = "images"
	CatPractices = "practices"
)

var categoryTitles = []struct{ id, title string }{
	{CatNetwork, "Network exposure"},
	{CatRBAC, "RBAC"},
	{CatWorkloads, "Workload hardening"},
	{CatImages, "Images"},
	{CatPractices, "Best practices"},
}

// Input is everything the analysis looks at. Any list may be nil (e.g. the
// user cannot list it, or the CRD is not installed).
type Input struct {
	Now time.Time
	// Namespace scopes the analysis; "" means all namespaces, "a,b" a
	// namespace set. Cluster-scoped
	// RBAC is listed cluster-wide but only bindings that touch the namespace
	// are reported when it is set.
	Namespace string
	// IncludeSystem includes kube-system & co. and the default `system:`
	// RBAC objects, which are excluded by default.
	IncludeSystem bool
	// Pending lists the categories whose lists are still loading (see
	// PendingCategories): their findings are dropped, not reported as zero.
	Pending []string

	Namespaces      []corev1.Namespace
	Pods            []corev1.Pod
	Deployments     []appsv1.Deployment
	StatefulSets    []appsv1.StatefulSet
	DaemonSets      []appsv1.DaemonSet
	ReplicaSets     []appsv1.ReplicaSet
	Jobs            []batchv1.Job
	CronJobs        []batchv1.CronJob
	Services        []corev1.Service
	ServiceAccounts []corev1.ServiceAccount
	Ingresses       []networkingv1.Ingress
	NetworkPolicies []networkingv1.NetworkPolicy

	// RBAC lists are cluster-wide.
	Roles               []rbacv1.Role
	ClusterRoles        []rbacv1.ClusterRole
	RoleBindings        []rbacv1.RoleBinding
	ClusterRoleBindings []rbacv1.ClusterRoleBinding

	// Gateway API (nil when the CRDs are absent).
	Gateways   []unstructured.Unstructured
	HTTPRoutes []unstructured.Unstructured

	// Trivy Operator reports (nil when the CRDs are absent).
	TrivyOperator                bool
	VulnerabilityReports         []unstructured.Unstructured
	ConfigAuditReports           []unstructured.Unstructured
	ExposedSecretReports         []unstructured.Unstructured
	RbacAssessmentReports        []unstructured.Unstructured
	ClusterRbacAssessmentReports []unstructured.Unstructured
}

// ObjectRef names an affected object.
type ObjectRef struct {
	Group     string `json:"group"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace,omitempty"`
}

// Finding is one (grouped) security problem.
type Finding struct {
	// ID is stable across refreshes: "<check>/<object key>".
	ID          string      `json:"id"`
	Check       string      `json:"check"`
	Severity    string      `json:"severity"`
	Category    string      `json:"category"`
	Title       string      `json:"title"`
	Detail      string      `json:"detail"`
	Remediation string      `json:"remediation"`
	Namespace   string      `json:"namespace,omitempty"`
	Objects     []ObjectRef `json:"objects"`
	// Checks lists the failing sub-checks (workload hardening).
	Checks []string `json:"checks,omitempty"`
}

// Category summarises the findings of one category for the tiles.
type Category struct {
	ID     string         `json:"id"`
	Title  string         `json:"title"`
	Total  int            `json:"total"`
	Counts map[string]int `json:"counts"`
}

// Result is the GET /api/security payload.
type Result struct {
	GeneratedAt   string     `json:"generatedAt"`
	Namespace     string     `json:"namespace"`
	IncludeSystem bool       `json:"includeSystem"`
	Score         int        `json:"score"`
	Categories    []Category `json:"categories"`
	Findings      []Finding  `json:"findings"`
	// Ignored are the findings hidden by the user's ignore rules (see
	// ApplyIgnores); the score, categories and Findings leave them out.
	Ignored    []IgnoredFinding   `json:"ignored"`
	Permissive []Grant            `json:"permissive"`
	Network    []NamespaceNetwork `json:"network"`
	Images     []ImageSummary     `json:"images"`
	TopCVEs    []CVE              `json:"topCVEs"`
	Sources    Sources            `json:"sources"`
	Errors     map[string]string  `json:"errors,omitempty"`
	// Pending lists the categories still loading: their tiles, findings and
	// sections are unknown (not zero), and the score leaves them out.
	Pending []string `json:"pending,omitempty"`
}

// Sources reports which optional data sources contributed.
type Sources struct {
	TrivyOperator bool `json:"trivyOperator"`
	// Reports counts the Trivy Operator reports read, by resource.
	Reports    map[string]int `json:"reports"`
	GatewayAPI bool           `json:"gatewayAPI"`
}

// systemNamespaces are skipped unless IncludeSystem.
var systemNamespaces = map[string]bool{"kube-system": true, "kube-public": true, "kube-node-lease": true}

// IsSystemNamespace reports whether ns belongs to Kubernetes itself.
func IsSystemNamespace(ns string) bool { return systemNamespaces[ns] }

type analyzer struct {
	in  Input
	now time.Time
	res *Result

	// owners
	rsOwn, jobOwn map[string]*ObjectRef
	// units are workloads (or bare pods), the grouping for workload findings.
	units []*unit
	// network
	net *netIndex
	// rbac
	saUsed   map[string]bool // ns/name of ServiceAccounts referenced by pods or templates
	saExists map[string]bool
	saListed map[string]bool // namespaces whose SAs were listed
	roles    map[string]*roleInfo
}

// Analyze runs every check over in.
func Analyze(in Input) *Result {
	now := in.Now
	if now.IsZero() {
		now = time.Now()
	}
	a := &analyzer{in: in, now: now, res: &Result{
		GeneratedAt:   now.UTC().Format(time.RFC3339),
		Namespace:     in.Namespace,
		IncludeSystem: in.IncludeSystem,
		Findings:      []Finding{},
		Ignored:       []IgnoredFinding{},
		Permissive:    []Grant{},
		Network:       []NamespaceNetwork{},
		Images:        []ImageSummary{},
		TopCVEs:       []CVE{},
		Sources:       Sources{TrivyOperator: in.TrivyOperator, Reports: map[string]int{}, GatewayAPI: in.Gateways != nil || in.HTTPRoutes != nil},
	}}
	a.indexOwners()
	a.buildUnits()
	a.network()
	a.rbac()
	a.workloads()
	a.practices()
	a.images()
	a.dropPending()
	a.finish()
	if len(in.Pending) > 0 {
		a.res.Pending = in.Pending
	}
	return a.res
}

// scope is the parsed Input.Namespace.
func (a *analyzer) scope() kube.Namespaces { return kube.SplitNamespaces(a.in.Namespace) }

// inScope reports whether objects in ns are analysed.
func (a *analyzer) inScope(ns string) bool {
	if a.in.Namespace != "" && !a.scope().Contains(ns) {
		return false
	}
	return a.in.IncludeSystem || !IsSystemNamespace(ns)
}

func (a *analyzer) add(f Finding) {
	if f.Objects == nil {
		f.Objects = []ObjectRef{}
	}
	a.res.Findings = append(a.res.Findings, f)
}

// ---- owners -----------------------------------------------------------------

func refFromOwner(ns string, r *metav1.OwnerReference) *ObjectRef {
	return &ObjectRef{Group: kube.Group(r.APIVersion), Kind: r.Kind, Name: r.Name, Namespace: ns}
}

func (a *analyzer) indexOwners() {
	a.rsOwn = map[string]*ObjectRef{}
	for i := range a.in.ReplicaSets {
		rs := &a.in.ReplicaSets[i]
		if c := kube.ControllerOf(rs.OwnerReferences); c != nil {
			a.rsOwn[kube.Key(rs.Namespace, rs.Name)] = refFromOwner(rs.Namespace, c)
		}
	}
	a.jobOwn = map[string]*ObjectRef{}
	for i := range a.in.Jobs {
		j := &a.in.Jobs[i]
		if c := kube.ControllerOf(j.OwnerReferences); c != nil {
			a.jobOwn[kube.Key(j.Namespace, j.Name)] = refFromOwner(j.Namespace, c)
		}
	}
}

// topOwner resolves Pod → ReplicaSet → Deployment and Pod → Job → CronJob.
// Returns nil for a bare pod.
func (a *analyzer) topOwner(ns string, refs []metav1.OwnerReference) *ObjectRef {
	c := kube.ControllerOf(refs)
	if c == nil {
		return nil
	}
	o := refFromOwner(ns, c)
	switch {
	case o.Group == "apps" && o.Kind == "ReplicaSet":
		if up := a.rsOwn[kube.Key(ns, o.Name)]; up != nil {
			return up
		}
	case o.Group == "batch" && o.Kind == "Job":
		if up := a.jobOwn[kube.Key(ns, o.Name)]; up != nil {
			return up
		}
	}
	return o
}

// unit is a workload (or a bare pod / pods of an unknown owner): the object
// workload findings are reported against.
type unit struct {
	ref    ObjectRef
	spec   *corev1.PodSpec
	meta   metav1.ObjectMeta // pod template metadata (labels, annotations)
	pods   []*corev1.Pod
	isJob  bool // Job or CronJob: probes don't apply
	hasPod bool
}

func (u *unit) podCount() int { return len(u.pods) }

func (a *analyzer) buildUnits() {
	byKey := map[string]*unit{}
	addUnit := func(group, kind string, m metav1.ObjectMeta, tpl *corev1.PodTemplateSpec, isJob bool) {
		if !a.inScope(m.Namespace) {
			return
		}
		u := &unit{ref: ObjectRef{Group: group, Kind: kind, Name: m.Name, Namespace: m.Namespace}, spec: &tpl.Spec, meta: tpl.ObjectMeta, isJob: isJob}
		byKey[refKey(u.ref)] = u
		a.units = append(a.units, u)
	}
	for i := range a.in.Deployments {
		d := &a.in.Deployments[i]
		addUnit("apps", "Deployment", d.ObjectMeta, &d.Spec.Template, false)
	}
	for i := range a.in.StatefulSets {
		s := &a.in.StatefulSets[i]
		addUnit("apps", "StatefulSet", s.ObjectMeta, &s.Spec.Template, false)
	}
	for i := range a.in.DaemonSets {
		d := &a.in.DaemonSets[i]
		addUnit("apps", "DaemonSet", d.ObjectMeta, &d.Spec.Template, false)
	}
	for i := range a.in.CronJobs {
		c := &a.in.CronJobs[i]
		addUnit("batch", "CronJob", c.ObjectMeta, &c.Spec.JobTemplate.Spec.Template, true)
	}
	for i := range a.in.Jobs {
		j := &a.in.Jobs[i]
		if kube.ControllerOf(j.OwnerReferences) == nil {
			addUnit("batch", "Job", j.ObjectMeta, &j.Spec.Template, true)
		}
	}
	for i := range a.in.ReplicaSets {
		rs := &a.in.ReplicaSets[i]
		if kube.ControllerOf(rs.OwnerReferences) == nil {
			addUnit("apps", "ReplicaSet", rs.ObjectMeta, &rs.Spec.Template, false)
		}
	}
	for i := range a.in.Pods {
		p := &a.in.Pods[i]
		if !a.inScope(p.Namespace) || p.Status.Phase == corev1.PodSucceeded || p.Status.Phase == corev1.PodFailed {
			continue
		}
		owner := a.topOwner(p.Namespace, p.OwnerReferences)
		ref := ObjectRef{Kind: "Pod", Name: p.Name, Namespace: p.Namespace}
		if owner != nil {
			ref = *owner
		}
		u := byKey[refKey(ref)]
		if u == nil {
			// Bare pod, or owned by something we don't list (a CRD
			// controller, a Node for static pods): use the pod's own spec.
			u = &unit{ref: ref, spec: &p.Spec, meta: p.ObjectMeta}
			byKey[refKey(ref)] = u
			a.units = append(a.units, u)
		}
		u.pods = append(u.pods, p)
		u.hasPod = true
	}
	sort.SliceStable(a.units, func(i, j int) bool { return refKey(a.units[i].ref) < refKey(a.units[j].ref) })
}

func refKey(r ObjectRef) string { return r.Namespace + "/" + r.Group + "/" + r.Kind + "/" + r.Name }

// ---- helpers ----------------------------------------------------------------

func kindLabel(r ObjectRef) string {
	return r.Kind + " " + r.Name
}

func joinLimit(items []string, n int) string {
	if len(items) <= n {
		return strings.Join(items, ", ")
	}
	return strings.Join(items[:n], ", ") + fmt.Sprintf(" and %d more", len(items)-n)
}

func uniqSorted(in []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	sort.Strings(out)
	return out
}

// ---- finish -----------------------------------------------------------------

// Score weights per finding severity. The score is 100·100/(100+Σweights):
// one critical costs ~9 points from a clean 100, and it never reaches 0.
var scoreWeight = map[string]float64{Critical: 10, High: 4, Medium: 1.5, Low: 0.3, Info: 0}

func (a *analyzer) finish() {
	fs := a.res.Findings
	sort.SliceStable(fs, func(i, j int) bool {
		if sevRank[fs[i].Severity] != sevRank[fs[j].Severity] {
			return sevRank[fs[i].Severity] < sevRank[fs[j].Severity]
		}
		if fs[i].Category != fs[j].Category {
			return catIndex(fs[i].Category) < catIndex(fs[j].Category)
		}
		return fs[i].ID < fs[j].ID
	})
	summarise(a.res)
}

// summarise fills the categories and the score from res.Findings.
func summarise(res *Result) {
	fs := res.Findings
	penalty := 0.0
	res.Categories = nil
	cats := map[string]*Category{}
	for _, c := range categoryTitles {
		cat := &Category{ID: c.id, Title: c.title, Counts: map[string]int{}}
		for _, s := range Severities {
			cat.Counts[s] = 0
		}
		cats[c.id] = cat
		res.Categories = append(res.Categories, Category{})
	}
	for _, f := range fs {
		if c := cats[f.Category]; c != nil {
			c.Counts[f.Severity]++
			c.Total++
		}
		penalty += scoreWeight[f.Severity]
	}
	for i, c := range categoryTitles {
		res.Categories[i] = *cats[c.id]
	}
	res.Score = int(math.Round(100 * 100 / (100 + penalty)))
}

func catIndex(id string) int {
	for i, c := range categoryTitles {
		if c.id == id {
			return i
		}
	}
	return len(categoryTitles)
}
