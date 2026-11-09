// Package upgrade answers "if this cluster goes from its current version to
// version X, what will break or get in the way?": removed APIs still in use,
// kubelet version skew, drain blockers, admission webhooks that can wedge
// the rollout, CRD storage versions, unhealthy nodes, and the add-ons to
// check against the new version. It only analyses: the server package lists
// the objects (read-only) into an Input.
package upgrade

import (
	"fmt"
	"sort"
	"strings"
	"time"

	admissionv1 "k8s.io/api/admissionregistration/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"

	"github.com/matty234/k8sman/backend/internal/security"
)

// Severities.
const (
	Blocker = "blocker" // will fail or break after the upgrade
	Warning = "warning" // risky, or will disrupt the rollout
	Info    = "info"
)

// ObjectRef names an object (the Security page's shape, so its links and
// ignore rules apply).
type ObjectRef = security.ObjectRef

// Finding is one thing in the way of the upgrade.
type Finding struct {
	// ID is stable across refreshes: "<check>/<subject>".
	ID       string `json:"id"`
	Check    string `json:"check"`
	Severity string `json:"severity"`
	Title    string `json:"title"`
	// Detail is the specifics (versions, counts) in one line.
	Detail string `json:"detail,omitempty"`
	// Why it matters for the upgrade, and what to do about it.
	Why    string `json:"why"`
	Action string `json:"action"`
	// Namespace of the finding's objects when they share one.
	Namespace string      `json:"namespace,omitempty"`
	Objects   []ObjectRef `json:"objects"`
	// Docs is a page to read; Kubectl a command line (without "kubectl")
	// worth copying, e.g. ["get", "pdb", "web", "-n", "shop", "-o", "yaml"].
	Docs    string   `json:"docs,omitempty"`
	Kubectl []string `json:"kubectl,omitempty"`
}

// Check ids, in the order the page shows them.
const (
	CheckAPIs     = "apis"
	CheckSkew     = "skew"
	CheckDrain    = "drain"
	CheckWebhooks = "webhooks"
	CheckCRDs     = "crds"
	CheckNodes    = "nodes"
	CheckAddons   = "addons"
)

var checkTitles = map[string]string{
	CheckAPIs:     "Removed APIs",
	CheckSkew:     "Version skew",
	CheckDrain:    "Drain blockers",
	CheckWebhooks: "Admission webhooks",
	CheckCRDs:     "CRD storage versions",
	CheckNodes:    "Node health",
	CheckAddons:   "Add-ons",
}

// checkClear is what a check with no findings says.
var checkClear = map[string]string{
	CheckAPIs:     "No removed APIs in use",
	CheckSkew:     "Kubelets within the supported skew",
	CheckDrain:    "Nodes can drain",
	CheckWebhooks: "No webhooks that can block the rollout",
	CheckCRDs:     "CRD storage versions are served",
	CheckNodes:    "All nodes ready",
	CheckAddons:   "No well-known add-ons found",
}

// CheckOrder is the page's order.
var CheckOrder = []string{CheckAPIs, CheckSkew, CheckDrain, CheckWebhooks, CheckCRDs, CheckNodes, CheckAddons}

// Check states.
const (
	StateClear       = "clear"       // ran, found nothing
	StateFindings    = "findings"    // ran, found something
	StatePending     = "pending"     // a list it needs is still running
	StateUnavailable = "unavailable" // not allowed to read what it needs
	StateError       = "error"       // a list it needs failed
)

// CheckResult is how one check went.
type CheckResult struct {
	ID     string         `json:"id"`
	Title  string         `json:"title"`
	State  string         `json:"state"`
	Counts map[string]int `json:"counts"`
	// Clear is the line shown when it found nothing; Notes say what it
	// couldn't look at ("Couldn't check Helm releases: not allowed").
	Clear string   `json:"clear"`
	Notes []string `json:"notes,omitempty"`
}

// Source names: the lists the server runs. Each check needs some of them.
const (
	SrcDiscovery   = "discovery"
	SrcNodes       = "nodes"
	SrcPods        = "pods"
	SrcControl     = "control-plane"
	SrcDeployments = "deployments"
	SrcStatefuls   = "statefulsets"
	SrcDaemonSets  = "daemonsets"
	SrcPDBs        = "poddisruptionbudgets"
	SrcPVCs        = "persistentvolumeclaims"
	SrcPVs         = "persistentvolumes"
	SrcWebhooks    = "webhooks"
	SrcEndpoints   = "endpoints"
	SrcCRDs        = "customresourcedefinitions"
	SrcObjects     = "objects"
	SrcHelm        = "helm"
	SrcMetrics     = "metrics"
)

// sourceChecks maps each source onto the checks that need it.
var sourceChecks = map[string][]string{
	SrcDiscovery:   {CheckAPIs},
	SrcObjects:     {CheckAPIs},
	SrcHelm:        {CheckAPIs},
	SrcMetrics:     {CheckAPIs},
	SrcNodes:       {CheckSkew, CheckNodes},
	SrcControl:     {CheckSkew},
	SrcPods:        {CheckDrain},
	SrcDeployments: {CheckDrain, CheckAddons},
	SrcStatefuls:   {CheckDrain},
	SrcDaemonSets:  {CheckAddons},
	SrcPDBs:        {CheckDrain},
	SrcPVCs:        {CheckDrain},
	SrcPVs:         {CheckDrain},
	SrcWebhooks:    {CheckWebhooks},
	SrcEndpoints:   {CheckWebhooks},
	SrcCRDs:        {CheckCRDs},
}

// sourceLabels name the sources in "Couldn't check …" notes.
var sourceLabels = map[string]string{
	SrcObjects:   "objects of kinds with removed APIs",
	SrcHelm:      "Helm releases",
	SrcMetrics:   "the API server's deprecated-API metric",
	SrcControl:   "control-plane pods",
	SrcPVs:       "PersistentVolumes",
	SrcPVCs:      "PersistentVolumeClaims",
	SrcPDBs:      "PodDisruptionBudgets",
	SrcWebhooks:  "webhook configurations",
	SrcEndpoints: "webhook service endpoints",
	SrcCRDs:      "CustomResourceDefinitions",
}

func sourceLabel(s string) string {
	if l, ok := sourceLabels[s]; ok {
		return l
	}
	return s
}

// APIUse is an object's record of having been written through apiVersion:
// a managedFields entry (with its manager) or the last-applied annotation.
type APIUse struct {
	Object     ObjectRef
	APIVersion string
	// Source is "managedFields" or "last-applied".
	Source  string
	Manager string
}

// DeprecatedRequest is one series of apiserver_requested_deprecated_apis:
// clients have called this API since the API server started.
type DeprecatedRequest struct {
	Group, Version, Resource, Subresource string
	RemovedRelease                        string
}

// CRDInfo is what the storage check needs of a CRD (CRDs carry schemas,
// so the server keeps only this).
type CRDInfo struct {
	Name           string
	Kind           string
	StoredVersions []string
	Versions       []CRDVersion
}

// CRDVersion is one of a CRD's spec.versions.
type CRDVersion struct {
	Name       string
	Served     bool
	Storage    bool
	Deprecated bool
}

// ServiceKey names a Service: "namespace/name".
type ServiceKey string

// Input is everything the checks read. Sources fill it in as they finish;
// a nil slice with no error means the source hasn't finished.
type Input struct {
	Now time.Time
	// ServerVersion is discovery's gitVersion ("v1.31.4-eks-…").
	ServerVersion string
	// Served is every served apiVersion → its resources (plural names).
	Served map[string][]string

	APIUses    []APIUse
	Helm       []HelmRelease
	Deprecated []DeprecatedRequest

	Nodes        []corev1.Node
	ControlPlane []corev1.Pod // kube-apiserver pods, where visible
	Pods         []corev1.Pod
	Deployments  []appsv1.Deployment
	StatefulSets []appsv1.StatefulSet
	DaemonSets   []appsv1.DaemonSet
	PDBs         []policyv1.PodDisruptionBudget
	PVCs         []corev1.PersistentVolumeClaim
	PVs          []corev1.PersistentVolume

	Validating []admissionv1.ValidatingWebhookConfiguration
	Mutating   []admissionv1.MutatingWebhookConfiguration
	// ReadyEndpoints counts each webhook Service's ready endpoints (a
	// Service missing from the map couldn't be looked up).
	ReadyEndpoints map[ServiceKey]int

	CRDs []CRDInfo

	// Pending are the sources still running; Errors the ones that failed
	// (Forbidden is told apart: the check says it couldn't look).
	Pending   []string
	Errors    map[string]error
	Forbidden func(error) bool
}

// Result is GET /api/upgrade.
type Result struct {
	GeneratedAt   string `json:"generatedAt"`
	ServerVersion string `json:"serverVersion"`
	// Current is the server's minor; Target the one checked against;
	// Targets the choices (the next three minors).
	Current Version   `json:"current"`
	Target  Version   `json:"target"`
	Targets []Version `json:"targets"`
	// Steps are the minors the control plane passes through (it upgrades
	// one minor at a time).
	Steps    []Version        `json:"steps"`
	Checks   []CheckResult    `json:"checks"`
	Findings []Finding        `json:"findings"`
	Ignored  []IgnoredFinding `json:"ignored"`
	Counts   map[string]int   `json:"counts"`
	Nodes    int              `json:"nodes"`
	Pending  []string         `json:"pending,omitempty"`
}

// IgnoredFinding is a finding hidden by one of the user's rules.
type IgnoredFinding struct {
	Finding
	Rule security.IgnoreRule `json:"rule"`
}

// Targets are the minors after current that the picker offers.
func Targets(current Version) []Version {
	return []Version{current.Plus(1), current.Plus(2), current.Plus(3)}
}

// Analyze runs every check against target (zero = the next minor).
func Analyze(in Input, target Version) Result {
	cur, _ := ParseVersion(in.ServerVersion)
	if target.IsZero() || cur.IsZero() || !cur.Before(target) {
		target = cur.Plus(1)
	}
	res := Result{
		GeneratedAt:   in.Now.UTC().Format(time.RFC3339),
		ServerVersion: in.ServerVersion,
		Current:       cur,
		Target:        target,
		Targets:       Targets(cur),
		Findings:      []Finding{},
		Ignored:       []IgnoredFinding{},
		Nodes:         len(in.Nodes),
		Pending:       in.Pending,
	}
	if cur.IsZero() {
		res.Targets = []Version{}
	}
	for v := cur.Plus(1); !cur.IsZero() && v.AtMost(target); v = v.Plus(1) {
		res.Steps = append(res.Steps, v)
	}
	a := analysis{in: in, cur: cur, target: target}
	if !cur.IsZero() {
		a.apis()
		a.skew()
	}
	a.drain()
	a.webhooks()
	a.crds()
	a.nodes()
	a.addons()
	res.Findings = a.findings
	sortFindings(res.Findings)
	res.Checks = a.checkResults(res.Findings)
	res.Counts = countSeverities(res.Findings)
	return res
}

// ApplyIgnores moves the findings rules cover to Ignored and recounts.
func ApplyIgnores(res *Result, rules []security.IgnoreRule) {
	if len(rules) == 0 {
		return
	}
	kept := res.Findings[:0:0]
	for _, f := range res.Findings {
		sf := security.Finding{Check: f.Check, Namespace: f.Namespace, Objects: f.Objects}
		if r, ok := security.Ignoring(rules, sf); ok {
			res.Ignored = append(res.Ignored, IgnoredFinding{Finding: f, Rule: r})
		} else {
			kept = append(kept, f)
		}
	}
	res.Findings = kept
	res.Counts = countSeverities(kept)
	for i := range res.Checks {
		c := &res.Checks[i]
		c.Counts = map[string]int{}
		for _, f := range kept {
			if f.Check == c.ID {
				c.Counts[f.Severity]++
			}
		}
		if c.State == StateFindings && len(c.Counts) == 0 {
			c.State = StateClear
		}
	}
}

var severityRank = map[string]int{Blocker: 0, Warning: 1, Info: 2}

func sortFindings(fs []Finding) {
	order := map[string]int{}
	for i, c := range CheckOrder {
		order[c] = i
	}
	sort.SliceStable(fs, func(i, j int) bool {
		a, b := fs[i], fs[j]
		if order[a.Check] != order[b.Check] {
			return order[a.Check] < order[b.Check]
		}
		if severityRank[a.Severity] != severityRank[b.Severity] {
			return severityRank[a.Severity] < severityRank[b.Severity]
		}
		return a.ID < b.ID
	})
}

func countSeverities(fs []Finding) map[string]int {
	out := map[string]int{Blocker: 0, Warning: 0, Info: 0}
	for _, f := range fs {
		out[f.Severity]++
	}
	return out
}

type analysis struct {
	in       Input
	cur      Version
	target   Version
	findings []Finding
	notes    map[string][]string
}

func (a *analysis) add(f Finding) {
	if f.Objects == nil {
		f.Objects = []ObjectRef{}
	}
	a.findings = append(a.findings, f)
}

func (a *analysis) note(check, format string, args ...any) {
	if a.notes == nil {
		a.notes = map[string][]string{}
	}
	a.notes[check] = append(a.notes[check], fmt.Sprintf(format, args...))
}

func (a *analysis) pending(src string) bool {
	for _, p := range a.in.Pending {
		if p == src {
			return true
		}
	}
	return false
}

// ok reports whether src finished without error.
func (a *analysis) ok(src string) bool { return !a.pending(src) && a.in.Errors[src] == nil }

func (a *analysis) forbidden(src string) bool {
	err := a.in.Errors[src]
	return err != nil && a.in.Forbidden != nil && a.in.Forbidden(err)
}

// optionalSources add evidence to a check that stands without them: when
// they are forbidden (or fail) the check still comes back clear, with a
// note saying what it couldn't look at.
var optionalSources = map[string]bool{
	SrcObjects: true, SrcHelm: true, SrcMetrics: true, SrcControl: true,
	SrcPVs: true, SrcPVCs: true, SrcEndpoints: true,
}

// checkResults sums up each check: pending while any source it needs is
// running; with findings when it has some; else unavailable when one of
// its required sources was forbidden, error when one failed, clear
// otherwise. Every source that couldn't be read becomes a note.
func (a *analysis) checkResults(fs []Finding) []CheckResult {
	srcs := map[string][]string{}
	for s, cs := range sourceChecks {
		for _, c := range cs {
			srcs[c] = append(srcs[c], s)
		}
	}
	out := make([]CheckResult, 0, len(CheckOrder))
	for _, id := range CheckOrder {
		r := CheckResult{ID: id, Title: checkTitles[id], Clear: checkClear[id], Counts: map[string]int{}}
		for _, f := range fs {
			if f.Check == id {
				r.Counts[f.Severity]++
			}
		}
		sort.Strings(srcs[id])
		pending, failed, forbidden := false, false, false
		for _, s := range srcs[id] {
			switch {
			case a.pending(s):
				pending = true
			case a.forbidden(s):
				forbidden = forbidden || !optionalSources[s]
				r.Notes = append(r.Notes, "Couldn't check "+sourceLabel(s)+": not allowed")
			case a.in.Errors[s] != nil:
				failed = failed || !optionalSources[s]
				r.Notes = append(r.Notes, "Couldn't check "+sourceLabel(s)+": "+a.in.Errors[s].Error())
			}
		}
		r.Notes = append(r.Notes, a.notes[id]...)
		switch {
		case pending:
			r.State = StatePending
		case len(r.Counts) > 0:
			r.State = StateFindings
		case forbidden:
			r.State = StateUnavailable
		case failed:
			r.State = StateError
		default:
			r.State = StateClear
		}
		out = append(out, r)
	}
	return out
}

// plural is "1 pod" / "3 pods".
func plural(n int, one string) string {
	if n == 1 {
		return "1 " + one
	}
	if strings.HasSuffix(one, "s") {
		return fmt.Sprintf("%d %ses", n, one)
	}
	return fmt.Sprintf("%d %ss", n, one)
}
