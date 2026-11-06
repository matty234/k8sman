// Package overview analyses a snapshot of cluster objects and reports what is
// unhealthy: crashlooping or stuck pods, unavailable workloads, failing jobs,
// unhealthy nodes and volumes, and the most frequent warning events.
//
// It is pure: the caller lists the objects (one list per type) and passes them
// in, so the analysis is unit-testable with constructed objects.
package overview

import (
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/prom"
)

// Thresholds used by the analysis.
const (
	StuckAfter        = 5 * time.Minute // Pending / Terminating / not ready longer than this is "stuck"
	OOMWindow         = time.Hour       // OOMKilled terminations within this window count
	HighRestarts      = 5               // container restarts (summed) at or above this
	LongRunningJob    = time.Hour       // active jobs running longer than this
	EventWindow       = time.Hour       // warning events seen within this window
	TopEventReasons   = 10
	cronOverdueGrace  = 2 * time.Minute
	maxMessageRunes   = 400
	completedReason   = "Completed"
	terminatingStatus = "Terminating"
)

// Severity levels, most severe first.
const (
	Critical = "critical"
	Warning  = "warning"
	Info     = "info"
)

// Input is everything the analysis looks at. Lists may be nil (e.g. when the
// user cannot list nodes).
type Input struct {
	Now          time.Time
	Pods         []corev1.Pod
	Deployments  []appsv1.Deployment
	StatefulSets []appsv1.StatefulSet
	DaemonSets   []appsv1.DaemonSet
	ReplicaSets  []appsv1.ReplicaSet
	Jobs         []batchv1.Job
	CronJobs     []batchv1.CronJob
	Nodes        []corev1.Node
	PVCs         []corev1.PersistentVolumeClaim
	Events       []corev1.Event
	// ArgoApps are Argo CD Applications (unstructured); nil when the CRD
	// isn't served, which leaves Argo out of the result entirely.
	ArgoApps []map[string]any
	// Workflows are Argo Workflows (unstructured); nil when the CRD isn't
	// served.
	Workflows []map[string]any
	// Gateway API objects; nil when the CRDs aren't served (no analysis,
	// no counts). Routes holds every route kind (HTTPRoute, GRPCRoute, ...).
	Gateways []unstructured.Unstructured
	Routes   []unstructured.Unstructured
	// Alerts are firing Alertmanager alerts (nil when none is installed).
	Alerts []prom.Alert
	// Findings are issues a module worked out itself (e.g. Hubble: relay
	// unreachable, dropped flows), added as they are.
	Findings []Finding
}

// Finding is a module's ready-made issue. Its Category gets a summary tile
// labelled Label in Section (the module's id is a good section).
type Finding struct {
	Issue
	Label   string
	Section string
	// Since is when the problem started (zero = unknown).
	Since time.Time
}

// Owner is the top-level controller of an object (Deployment, StatefulSet,
// DaemonSet, CronJob, Job, ...).
type Owner struct {
	Group string `json:"group"`
	Kind  string `json:"kind"`
	Name  string `json:"name"`
}

// Issue is one unhealthy object.
type Issue struct {
	Severity  string `json:"severity"`
	Category  string `json:"category"`
	Kind      string `json:"kind"`
	Group     string `json:"group"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name"`
	Reason    string `json:"reason"`
	Message   string `json:"message"`
	// Since is when the problem (probably) started, RFC3339.
	Since string `json:"since,omitempty"`
	// Count is a restart count for pod issues.
	Count int    `json:"count,omitempty"`
	Owner *Owner `json:"owner,omitempty"`

	since time.Time
}

// Category summarises the issues of one kind, for the summary tiles.
type Category struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	Section  string `json:"section"` // pods | workloads | jobs | nodes | storage | network
	Severity string `json:"severity"`
	Count    int    `json:"count"`
}

// PodCounts tallies pods by health. A pod can be in several buckets (e.g.
// crashLoop and highRestarts).
type PodCounts struct {
	Total                      int `json:"total"`
	Running                    int `json:"running"`
	Ready                      int `json:"ready"`
	Pending                    int `json:"pending"`
	CrashLoop                  int `json:"crashLoop"`
	ImagePull                  int `json:"imagePull"`
	CreateContainerConfigError int `json:"createContainerConfigError"`
	OOMKilled                  int `json:"oomKilled"`
	Failed                     int `json:"failed"`
	Terminating                int `json:"terminating"`
	StuckTerminating           int `json:"stuckTerminating"`
	StuckPending               int `json:"stuckPending"`
	NotReady                   int `json:"notReady"`
	HighRestarts               int `json:"highRestarts"`
	Completed                  int `json:"completed"`
	InitBlocked                int `json:"initBlocked"`
}

// DeploymentCounts tallies deployments.
type DeploymentCounts struct {
	Total                    int `json:"total"`
	Healthy                  int `json:"healthy"`
	Unavailable              int `json:"unavailable"`
	ProgressDeadlineExceeded int `json:"progressDeadlineExceeded"`
	Paused                   int `json:"paused"`
	Rolling                  int `json:"rolling"`
}

// SetCounts tallies StatefulSets or DaemonSets.
type SetCounts struct {
	Total    int `json:"total"`
	Healthy  int `json:"healthy"`
	NotReady int `json:"notReady"`
}

// JobCounts tallies jobs.
type JobCounts struct {
	Total       int `json:"total"`
	Running     int `json:"running"`
	Succeeded   int `json:"succeeded"`
	Failed      int `json:"failed"`
	LongRunning int `json:"longRunning"`
	Suspended   int `json:"suspended"`
}

// CronJobCounts tallies cronjobs.
type CronJobCounts struct {
	Total     int `json:"total"`
	Suspended int `json:"suspended"`
	Failing   int `json:"failing"`
	Overdue   int `json:"overdue"`
}

// NodeCounts tallies nodes.
type NodeCounts struct {
	Total    int `json:"total"`
	Ready    int `json:"ready"`
	NotReady int `json:"notReady"`
	Pressure int `json:"pressure"`
	Cordoned int `json:"cordoned"`
}

// PVCCounts tallies PersistentVolumeClaims.
type PVCCounts struct {
	Total   int `json:"total"`
	Bound   int `json:"bound"`
	Pending int `json:"pending"`
	Lost    int `json:"lost"`
}

// Counts groups the per-type tallies.
type Counts struct {
	Pods         PodCounts        `json:"pods"`
	Deployments  DeploymentCounts `json:"deployments"`
	StatefulSets SetCounts        `json:"statefulSets"`
	DaemonSets   SetCounts        `json:"daemonSets"`
	Jobs         JobCounts        `json:"jobs"`
	CronJobs     CronJobCounts    `json:"cronJobs"`
	Nodes        NodeCounts       `json:"nodes"`
	PVCs         PVCCounts        `json:"pvcs"`
	ArgoApps     *ArgoCounts      `json:"argoApps,omitempty"`
	Gateways     *GatewayCounts   `json:"gateways,omitempty"`
	Routes       *RouteCounts     `json:"routes,omitempty"`
}

// NodeHealth is one node in the nodes strip.
type NodeHealth struct {
	Name     string   `json:"name"`
	Ready    bool     `json:"ready"`
	Cordoned bool     `json:"cordoned"`
	Pressure []string `json:"pressure,omitempty"`
	Roles    []string `json:"roles,omitempty"`
	Version  string   `json:"version,omitempty"`
	Pods     int      `json:"pods"`
}

// ObjectRef names an event's involved object.
type ObjectRef struct {
	Kind      string `json:"kind"`
	Group     string `json:"group"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name"`
}

// EventReason aggregates warning events with the same reason.
type EventReason struct {
	Reason        string    `json:"reason"`
	Count         int       `json:"count"`
	Objects       int       `json:"objects"`
	LatestMessage string    `json:"latestMessage"`
	LastSeen      string    `json:"lastSeen"`
	Example       ObjectRef `json:"example"`
	last          time.Time
}

// Result is the GET /api/overview payload.
type Result struct {
	GeneratedAt string            `json:"generatedAt"`
	Namespace   string            `json:"namespace"`
	Counts      Counts            `json:"counts"`
	Categories  []Category        `json:"categories"`
	Issues      []Issue           `json:"issues"`
	Nodes       []NodeHealth      `json:"nodes"`
	TopWarnings []EventReason     `json:"topWarnings"`
	Errors      map[string]string `json:"errors,omitempty"`
}

type categoryDef struct {
	id, label, section, severity string
}

// categoryDefs is the display order of the summary tiles.
var categoryDefs = []categoryDef{
	{"nodeNotReady", "Nodes not ready", "nodes", Critical},
	{catAlertCritical, "Critical alerts", "alerts", Critical},
	{"crashLoop", "CrashLoopBackOff", "pods", Critical},
	{"imagePull", "Image pull errors", "pods", Critical},
	{"createContainerConfigError", "Container config errors", "pods", Critical},
	{"initBlocked", "Init blocked", "pods", Critical},
	{"oomKilled", "OOMKilled (1h)", "pods", Critical},
	{"podFailed", "Failed pods", "pods", Critical},
	{"progressDeadlineExceeded", "Rollouts stalled", "workloads", Critical},
	{"deploymentUnavailable", "Deployments unavailable", "workloads", Critical},
	{"statefulSetNotReady", "StatefulSets not ready", "workloads", Warning},
	{"daemonSetNotReady", "DaemonSets not ready", "workloads", Warning},
	{"cronJobFailing", "CronJobs failing", "jobs", Critical},
	{"jobFailed", "Failed jobs", "jobs", Critical},
	{"workflowFailed", "Workflows failed (24h)", "jobs", Critical},
	{"pvcLost", "PVCs lost", "storage", Critical},
	{"argoSyncFailed", "Argo CD sync errors", "argocd", Critical},
	{"argoDegraded", "Argo CD apps degraded", "argocd", Critical},
	{"gatewayNotReady", "Gateways not ready", "network", Critical},
	{"routeNotAccepted", "Routes not accepted", "network", Critical},
	{"stuckPending", "Stuck pending", "pods", Warning},
	{"stuckTerminating", "Stuck terminating", "pods", Warning},
	{"notReady", "Pods not ready", "pods", Warning},
	{"highRestarts", "High restarts", "pods", Warning},
	{"jobLongRunning", "Jobs running > 1h", "jobs", Warning},
	{"cronJobOverdue", "CronJobs overdue", "jobs", Warning},
	{"nodePressure", "Node pressure", "nodes", Warning},
	{catAlertWarning, "Warning alerts", "alerts", Warning},
	{"pvcPending", "PVCs pending", "storage", Warning},
	{"argoMissing", "Argo CD apps missing", "argocd", Warning},
	{"argoOutOfSync", "Argo CD apps out of sync", "argocd", Warning},
	{"gatewayListener", "Gateway listener problems", "network", Warning},
	{"routeUnresolvedRefs", "Routes with unresolved refs", "network", Warning},
	{"rolling", "Rolling out", "workloads", Info},
	{"deploymentPaused", "Paused rollouts", "workloads", Info},
	{"jobSuspended", "Suspended jobs", "jobs", Info},
	{"cronJobSuspended", "Suspended CronJobs", "jobs", Info},
	{"nodeCordoned", "Nodes cordoned", "nodes", Info},
	{catAlertInfo, "Info alerts", "alerts", Info},
}

var severityRank = map[string]int{Critical: 0, Warning: 1, Info: 2}

type analyzer struct {
	in     Input
	now    time.Time
	res    *Result
	rsOwn  map[string]*Owner // ns/name of ReplicaSet → its owner
	jobOwn map[string]*Owner // ns/name of Job → its owner
}

// Analyze runs every check over in.
func Analyze(in Input) *Result {
	now := in.Now
	if now.IsZero() {
		now = time.Now()
	}
	a := &analyzer{in: in, now: now, res: &Result{GeneratedAt: now.UTC().Format(time.RFC3339), Issues: []Issue{}, Nodes: []NodeHealth{}, TopWarnings: []EventReason{}, Categories: []Category{}}}
	a.indexOwners()
	a.pods()
	a.deployments()
	a.statefulSets()
	a.daemonSets()
	a.jobs()
	a.cronJobs()
	a.nodes()
	a.pvcs()
	a.gateways()
	a.routes()
	a.events()
	a.argoApps()
	a.argoWorkflows()
	a.alerts()
	for _, f := range in.Findings {
		f.Issue.since = f.Since
		a.add(f.Issue)
	}
	a.finish()
	return a.res
}

// ---- owners -----------------------------------------------------------------

func ownerFromRef(r *metav1.OwnerReference) *Owner {
	return &Owner{Group: kube.Group(r.APIVersion), Kind: r.Kind, Name: r.Name}
}

func (a *analyzer) indexOwners() {
	a.rsOwn = map[string]*Owner{}
	for i := range a.in.ReplicaSets {
		rs := &a.in.ReplicaSets[i]
		if c := kube.ControllerOf(rs.OwnerReferences); c != nil {
			a.rsOwn[kube.Key(rs.Namespace, rs.Name)] = ownerFromRef(c)
		}
	}
	a.jobOwn = map[string]*Owner{}
	for i := range a.in.Jobs {
		j := &a.in.Jobs[i]
		if c := kube.ControllerOf(j.OwnerReferences); c != nil {
			a.jobOwn[kube.Key(j.Namespace, j.Name)] = ownerFromRef(c)
		}
	}
}

// topOwner resolves Pod → ReplicaSet → Deployment and Pod → Job → CronJob.
func (a *analyzer) topOwner(ns string, refs []metav1.OwnerReference) *Owner {
	c := kube.ControllerOf(refs)
	if c == nil {
		return nil
	}
	o := ownerFromRef(c)
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

// ---- helpers ----------------------------------------------------------------

func (a *analyzer) add(is Issue) {
	if !is.since.IsZero() {
		is.Since = is.since.UTC().Format(time.RFC3339)
	}
	is.Message = truncate(strings.TrimSpace(is.Message))
	a.res.Issues = append(a.res.Issues, is)
}

func truncate(s string) string {
	r := []rune(s)
	if len(r) <= maxMessageRunes {
		return s
	}
	return string(r[:maxMessageRunes-1]) + "…"
}

func (a *analyzer) older(t metav1.Time, d time.Duration) bool {
	return !t.IsZero() && a.now.Sub(t.Time) > d
}

func firstNonZero(ts ...time.Time) time.Time {
	for _, t := range ts {
		if !t.IsZero() {
			return t
		}
	}
	return time.Time{}
}

func shortDur(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh%dm", int(d.Hours()), int(d.Minutes())%60)
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

// ---- pods -------------------------------------------------------------------

// PodStatus reproduces the pod table's Status column (columns/builtin.go):
// Terminating, else the first failing/waiting init container as
// "Init:<reason>", else the first container waiting/terminated reason, else
// the phase.
func PodStatus(p *corev1.Pod) string {
	if p.DeletionTimestamp != nil {
		return terminatingStatus
	}
	for _, cs := range p.Status.InitContainerStatuses {
		t, w := cs.State.Terminated, cs.State.Waiting
		if (t != nil && t.ExitCode != 0) || w != nil {
			reason := ""
			if w != nil {
				reason = w.Reason
			}
			if reason == "" && t != nil {
				reason = t.Reason
			}
			if reason == "" {
				reason = "Error"
			}
			return "Init:" + reason
		}
	}
	for _, cs := range p.Status.ContainerStatuses {
		if w := cs.State.Waiting; w != nil && w.Reason != "" {
			return w.Reason
		}
		if t := cs.State.Terminated; t != nil && t.Reason != "" {
			return t.Reason
		}
	}
	return string(p.Status.Phase)
}

var imagePullReasons = map[string]bool{"ImagePullBackOff": true, "ErrImagePull": true, "InvalidImageName": true, "ErrImageNeverPull": true}
var configErrorReasons = map[string]bool{"CreateContainerConfigError": true, "CreateContainerError": true, "RunContainerError": true}

// initErrorReasons are Init:<reason> values that mean init is failing rather
// than just in progress.
func initFailing(reason string) bool {
	switch reason {
	case "PodInitializing", "ContainerCreating", "":
		return false
	}
	return true
}

func podCondition(p *corev1.Pod, t corev1.PodConditionType) *corev1.PodCondition {
	for i := range p.Status.Conditions {
		if p.Status.Conditions[i].Type == t {
			return &p.Status.Conditions[i]
		}
	}
	return nil
}

func restarts(p *corev1.Pod) int {
	n := 0
	for _, cs := range p.Status.ContainerStatuses {
		n += int(cs.RestartCount)
	}
	return n
}

// notReadySince is when the pod last became not ready (or was created).
func notReadySince(p *corev1.Pod) time.Time {
	if c := podCondition(p, corev1.PodReady); c != nil && c.Status != corev1.ConditionTrue && !c.LastTransitionTime.IsZero() {
		return c.LastTransitionTime.Time
	}
	return p.CreationTimestamp.Time
}

// containerWith returns the first container status whose waiting or
// terminated reason is reason (init containers first).
func containerWith(p *corev1.Pod, reason string) *corev1.ContainerStatus {
	all := append(append([]corev1.ContainerStatus{}, p.Status.InitContainerStatuses...), p.Status.ContainerStatuses...)
	for i := range all {
		cs := &all[i]
		if (cs.State.Waiting != nil && cs.State.Waiting.Reason == reason) || (cs.State.Terminated != nil && cs.State.Terminated.Reason == reason) {
			return cs
		}
	}
	return nil
}

func describeLastTermination(cs *corev1.ContainerStatus) string {
	t := cs.LastTerminationState.Terminated
	if t == nil {
		return ""
	}
	parts := []string{fmt.Sprintf("exit %d", t.ExitCode)}
	if t.Reason != "" {
		parts = append(parts, t.Reason)
	}
	return "last terminated: " + strings.Join(parts, ", ")
}

// oomWithin reports the container that was OOMKilled within the window.
func (a *analyzer) oomWithin(p *corev1.Pod) (*corev1.ContainerStatus, time.Time) {
	all := append(append([]corev1.ContainerStatus{}, p.Status.InitContainerStatuses...), p.Status.ContainerStatuses...)
	for i := range all {
		cs := &all[i]
		for _, t := range []*corev1.ContainerStateTerminated{cs.State.Terminated, cs.LastTerminationState.Terminated} {
			if t != nil && t.Reason == "OOMKilled" {
				at := firstNonZero(t.FinishedAt.Time, t.StartedAt.Time)
				if !at.IsZero() && a.now.Sub(at) <= OOMWindow {
					return cs, at
				}
			}
		}
	}
	return nil, time.Time{}
}

func (a *analyzer) recentOOM(p *corev1.Pod) bool {
	cs, _ := a.oomWithin(p)
	return cs != nil
}

func (a *analyzer) pods() {
	pc := &a.res.Counts.Pods
	for i := range a.in.Pods {
		p := &a.in.Pods[i]
		pc.Total++
		status := PodStatus(p)
		owner := a.topOwner(p.Namespace, p.OwnerReferences)
		base := Issue{Kind: "Pod", Group: "", Namespace: p.Namespace, Name: p.Name, Reason: status, Owner: owner, Count: restarts(p)}
		issue := func(sev, cat, msg string, since time.Time) {
			is := base
			is.Severity, is.Category, is.Message, is.since = sev, cat, msg, since
			a.add(is)
		}
		ready := false
		if c := podCondition(p, corev1.PodReady); c != nil && c.Status == corev1.ConditionTrue {
			ready = true
		}
		primaryBad := true
		switch {
		case status == terminatingStatus:
			pc.Terminating++
			if a.older(*p.DeletionTimestamp, StuckAfter) {
				pc.StuckTerminating++
				msg := fmt.Sprintf("Terminating for %s", shortDur(a.now.Sub(p.DeletionTimestamp.Time)))
				if len(p.Finalizers) > 0 {
					msg += "; finalizers: " + strings.Join(p.Finalizers, ", ")
				}
				if p.Spec.NodeName != "" {
					msg += "; node " + p.Spec.NodeName
				}
				issue(Warning, "stuckTerminating", msg, p.DeletionTimestamp.Time)
			}
		case strings.HasPrefix(status, "Init:"):
			reason := strings.TrimPrefix(status, "Init:")
			pc.Pending++
			if initFailing(reason) || a.older(p.CreationTimestamp, StuckAfter) {
				pc.InitBlocked++
				sev := Critical
				if !initFailing(reason) {
					sev = Warning
				}
				msg := "init container"
				if cs := initContainerBlocking(p); cs != nil {
					msg += " " + cs.Name
					if w := cs.State.Waiting; w != nil && w.Message != "" {
						msg += ": " + w.Message
					} else if t := cs.State.Terminated; t != nil {
						msg += fmt.Sprintf(": exit %d", t.ExitCode)
						if t.Message != "" {
							msg += ", " + t.Message
						}
					} else if d := describeLastTermination(cs); d != "" {
						msg += ": " + d
					}
				}
				if !initFailing(reason) {
					msg += fmt.Sprintf(" still %s after %s", reason, shortDur(a.now.Sub(p.CreationTimestamp.Time)))
				}
				issue(sev, "initBlocked", msg, notReadySince(p))
			}
		case status == "CrashLoopBackOff":
			pc.CrashLoop++
			msg := ""
			if cs := containerWith(p, status); cs != nil {
				msg = "container " + cs.Name
				if d := describeLastTermination(cs); d != "" {
					msg += " " + d
				}
				msg += fmt.Sprintf("; %s", kube.Plural(int(cs.RestartCount), "restart", "restarts"))
			}
			issue(Critical, "crashLoop", msg, notReadySince(p))
		case p.Status.Phase == corev1.PodRunning && p.Spec.RestartPolicy != corev1.RestartPolicyNever && status != "OOMKilled" && terminatedWithError(p) != nil:
			// A container just exited (the table shows e.g. "Error") and is
			// about to be restarted: this is the other half of a crashloop.
			pc.CrashLoop++
			cs := terminatedWithError(p)
			t := cs.State.Terminated
			msg := fmt.Sprintf("container %s exited %d", cs.Name, t.ExitCode)
			if t.Message != "" {
				msg += ": " + t.Message
			}
			msg += fmt.Sprintf(" and is restarting; %s", kube.Plural(int(cs.RestartCount), "restart", "restarts"))
			issue(Critical, "crashLoop", msg, notReadySince(p))
		case imagePullReasons[status]:
			pc.ImagePull++
			msg := ""
			if cs := containerWith(p, status); cs != nil {
				msg = fmt.Sprintf("container %s, image %s", cs.Name, cs.Image)
				if w := cs.State.Waiting; w != nil && w.Message != "" {
					msg += ": " + w.Message
				}
			}
			issue(Critical, "imagePull", msg, notReadySince(p))
		case configErrorReasons[status]:
			pc.CreateContainerConfigError++
			msg := ""
			if cs := containerWith(p, status); cs != nil {
				msg = "container " + cs.Name
				if w := cs.State.Waiting; w != nil && w.Message != "" {
					msg += ": " + w.Message
				}
			}
			issue(Critical, "createContainerConfigError", msg, notReadySince(p))
		case status == completedReason || p.Status.Phase == corev1.PodSucceeded:
			pc.Completed++
			primaryBad = false
		case status == "OOMKilled" && a.recentOOM(p):
			// Reported by the OOM check below.
			pc.Failed += boolInt(p.Status.Phase == corev1.PodFailed)
		case p.Status.Phase == corev1.PodFailed || status == "Error" || status == "ContainerCannotRun" || status == "DeadlineExceeded" || status == "Evicted" || status == "OOMKilled":
			pc.Failed++
			msg := p.Status.Message
			if msg == "" {
				for _, cs := range p.Status.ContainerStatuses {
					if t := cs.State.Terminated; t != nil && t.ExitCode != 0 {
						msg = fmt.Sprintf("container %s exited %d", cs.Name, t.ExitCode)
						if t.Message != "" {
							msg += ": " + t.Message
						}
						break
					}
				}
			}
			if p.Status.Reason != "" && p.Status.Reason != status {
				base.Reason = status + " (" + p.Status.Reason + ")"
			}
			sev := Critical
			if owner != nil && owner.Group == "batch" {
				sev = Warning // the Job/CronJob check reports the failure itself
			}
			since := p.CreationTimestamp.Time
			if c := podCondition(p, corev1.PodReady); c != nil && !c.LastTransitionTime.IsZero() {
				since = c.LastTransitionTime.Time
			}
			issue(sev, "podFailed", msg, since)
		case p.Status.Phase == corev1.PodPending:
			pc.Pending++
			if a.older(p.CreationTimestamp, StuckAfter) {
				pc.StuckPending++
				reason, msg := status, ""
				if c := podCondition(p, corev1.PodScheduled); c != nil && c.Status != corev1.ConditionTrue {
					if c.Reason != "" {
						reason = c.Reason
					}
					msg = c.Message
				} else {
					for _, cs := range p.Status.ContainerStatuses {
						if w := cs.State.Waiting; w != nil {
							msg = fmt.Sprintf("container %s %s", cs.Name, w.Reason)
							if w.Message != "" {
								msg += ": " + w.Message
							}
							break
						}
					}
				}
				if msg == "" {
					msg = fmt.Sprintf("Pending for %s", shortDur(a.now.Sub(p.CreationTimestamp.Time)))
				} else {
					msg = fmt.Sprintf("Pending for %s: %s", shortDur(a.now.Sub(p.CreationTimestamp.Time)), msg)
				}
				base.Reason = reason
				issue(Warning, "stuckPending", msg, p.CreationTimestamp.Time)
			}
		case p.Status.Phase == corev1.PodRunning:
			pc.Running++
			primaryBad = false
			if ready {
				pc.Ready++
			} else if since := notReadySince(p); a.now.Sub(since) > StuckAfter {
				pc.NotReady++
				var names []string
				for _, cs := range p.Status.ContainerStatuses {
					if !cs.Ready {
						names = append(names, cs.Name)
					}
				}
				msg := "Running but not ready"
				if c := podCondition(p, corev1.PodReady); c != nil && c.Message != "" {
					msg += ": " + c.Message
				} else if len(names) > 0 {
					msg += ": containers " + strings.Join(names, ", ")
				}
				base.Reason = "NotReady"
				issue(Warning, "notReady", msg, since)
				base.Reason = status
				primaryBad = true
			}
		default:
			// Unknown phase or an unrecognised waiting reason.
			pc.Pending += boolInt(p.Status.Phase == corev1.PodPending)
			primaryBad = false
		}

		if status == terminatingStatus {
			continue
		}
		if cs, at := a.oomWithin(p); cs != nil {
			pc.OOMKilled++
			is := base
			is.Reason = "OOMKilled"
			msg := fmt.Sprintf("container %s was OOMKilled %s ago", cs.Name, shortDur(a.now.Sub(at)))
			for _, c := range p.Spec.Containers {
				if c.Name == cs.Name {
					if lim, ok := c.Resources.Limits[corev1.ResourceMemory]; ok {
						msg += "; memory limit " + lim.String()
					}
				}
			}
			is.Severity, is.Category, is.Message, is.since = Critical, "oomKilled", msg, at
			a.add(is)
		}
		if n := restarts(p); n >= HighRestarts {
			pc.HighRestarts++
			// Crashlooping pods already say so; only flag otherwise-healthy-looking pods.
			if !primaryBad {
				is := base
				is.Reason = "HighRestarts"
				last := time.Time{}
				for _, cs := range p.Status.ContainerStatuses {
					if t := cs.LastTerminationState.Terminated; t != nil && t.FinishedAt.After(last) {
						last = t.FinishedAt.Time
					}
				}
				msg := kube.Plural(n, "restart", "restarts")
				if !last.IsZero() {
					msg += fmt.Sprintf(", last %s ago", shortDur(a.now.Sub(last)))
				}
				is.Severity, is.Category, is.Message, is.since = Warning, "highRestarts", msg, firstNonZero(last, p.CreationTimestamp.Time)
				a.add(is)
			}
		}
	}
}

func initContainerBlocking(p *corev1.Pod) *corev1.ContainerStatus {
	for i := range p.Status.InitContainerStatuses {
		cs := &p.Status.InitContainerStatuses[i]
		if (cs.State.Terminated != nil && cs.State.Terminated.ExitCode != 0) || cs.State.Waiting != nil {
			return cs
		}
	}
	return nil
}

// terminatedWithError returns the first regular container whose current
// state is terminated with a non-zero exit code.
func terminatedWithError(p *corev1.Pod) *corev1.ContainerStatus {
	for i := range p.Status.ContainerStatuses {
		cs := &p.Status.ContainerStatuses[i]
		if t := cs.State.Terminated; t != nil && t.ExitCode != 0 {
			return cs
		}
	}
	return nil
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// ---- workloads --------------------------------------------------------------

func replicasOf(p *int32) int32 {
	if p == nil {
		return 1
	}
	return *p
}

func depCondition(d *appsv1.Deployment, t appsv1.DeploymentConditionType) *appsv1.DeploymentCondition {
	for i := range d.Status.Conditions {
		if d.Status.Conditions[i].Type == t {
			return &d.Status.Conditions[i]
		}
	}
	return nil
}

func (a *analyzer) deployments() {
	dc := &a.res.Counts.Deployments
	for i := range a.in.Deployments {
		d := &a.in.Deployments[i]
		dc.Total++
		want := replicasOf(d.Spec.Replicas)
		st := d.Status
		base := Issue{Kind: "Deployment", Group: "apps", Namespace: d.Namespace, Name: d.Name}
		add := func(sev, cat, reason, msg string, since time.Time) {
			is := base
			is.Severity, is.Category, is.Reason, is.Message, is.since = sev, cat, reason, msg, since
			a.add(is)
		}
		healthy := true
		progressing := depCondition(d, appsv1.DeploymentProgressing)
		stalled := progressing != nil && progressing.Status == corev1.ConditionFalse && progressing.Reason == "ProgressDeadlineExceeded"
		if stalled {
			dc.ProgressDeadlineExceeded++
			healthy = false
			add(Critical, "progressDeadlineExceeded", "ProgressDeadlineExceeded",
				fmt.Sprintf("%s; %d/%d updated, %d available", strings.TrimSuffix(progressing.Message, "."), st.UpdatedReplicas, want, st.AvailableReplicas),
				progressing.LastTransitionTime.Time)
		}
		rolling := !d.Spec.Paused && (d.Generation > st.ObservedGeneration || st.UpdatedReplicas < want || st.Replicas > st.UpdatedReplicas)
		avail := depCondition(d, appsv1.DeploymentAvailable)
		unavailable := want > 0 && ((avail != nil && avail.Status == corev1.ConditionFalse) || (!rolling && st.AvailableReplicas < want))
		if unavailable {
			dc.Unavailable++
			healthy = false
			sev := Warning
			if st.AvailableReplicas == 0 || (avail != nil && avail.Status == corev1.ConditionFalse) {
				sev = Critical
			}
			since := d.CreationTimestamp.Time
			if avail != nil && !avail.LastTransitionTime.IsZero() {
				since = avail.LastTransitionTime.Time
			}
			msg := fmt.Sprintf("%d/%d available, %d ready", st.AvailableReplicas, want, st.ReadyReplicas)
			if avail != nil && avail.Status == corev1.ConditionFalse && avail.Message != "" {
				msg += "; " + strings.TrimSuffix(avail.Message, ".")
			}
			add(sev, "deploymentUnavailable", "Unavailable", msg, since)
		}
		if d.Spec.Paused {
			dc.Paused++
			add(Info, "deploymentPaused", "Paused", "Rollout is paused; template changes will not roll out", d.CreationTimestamp.Time)
		}
		if rolling && !stalled {
			dc.Rolling++
			healthy = false
			since := d.CreationTimestamp.Time
			if progressing != nil && !progressing.LastUpdateTime.IsZero() {
				since = progressing.LastUpdateTime.Time
			}
			add(Info, "rolling", "RollingUpdate", fmt.Sprintf("%d/%d updated, %d available, %d total pods", st.UpdatedReplicas, want, st.AvailableReplicas, st.Replicas), since)
		}
		if healthy {
			dc.Healthy++
		}
	}
}

func (a *analyzer) statefulSets() {
	c := &a.res.Counts.StatefulSets
	for i := range a.in.StatefulSets {
		s := &a.in.StatefulSets[i]
		c.Total++
		want := replicasOf(s.Spec.Replicas)
		if s.Status.ReadyReplicas >= want {
			c.Healthy++
			continue
		}
		c.NotReady++
		sev := Warning
		if s.Status.ReadyReplicas == 0 {
			sev = Critical
		}
		msg := fmt.Sprintf("%d/%d ready", s.Status.ReadyReplicas, want)
		if s.Status.UpdateRevision != "" && s.Status.CurrentRevision != s.Status.UpdateRevision {
			msg += fmt.Sprintf(", rolling out (%d updated)", s.Status.UpdatedReplicas)
		}
		a.add(Issue{Severity: sev, Category: "statefulSetNotReady", Kind: "StatefulSet", Group: "apps", Namespace: s.Namespace, Name: s.Name,
			Reason: "NotReady", Message: msg, since: s.CreationTimestamp.Time})
	}
}

func (a *analyzer) daemonSets() {
	c := &a.res.Counts.DaemonSets
	for i := range a.in.DaemonSets {
		d := &a.in.DaemonSets[i]
		c.Total++
		st := d.Status
		if st.NumberReady >= st.DesiredNumberScheduled && st.NumberMisscheduled == 0 {
			c.Healthy++
			continue
		}
		c.NotReady++
		sev := Warning
		if st.NumberReady == 0 && st.DesiredNumberScheduled > 0 {
			sev = Critical
		}
		msg := fmt.Sprintf("%d/%d ready", st.NumberReady, st.DesiredNumberScheduled)
		if st.NumberUnavailable > 0 {
			msg += fmt.Sprintf(", %d unavailable", st.NumberUnavailable)
		}
		if st.NumberMisscheduled > 0 {
			msg += fmt.Sprintf(", %d misscheduled", st.NumberMisscheduled)
		}
		if st.UpdatedNumberScheduled < st.DesiredNumberScheduled {
			msg += fmt.Sprintf(", %d/%d updated", st.UpdatedNumberScheduled, st.DesiredNumberScheduled)
		}
		a.add(Issue{Severity: sev, Category: "daemonSetNotReady", Kind: "DaemonSet", Group: "apps", Namespace: d.Namespace, Name: d.Name,
			Reason: "NotReady", Message: msg, since: d.CreationTimestamp.Time})
	}
}

// ---- jobs -------------------------------------------------------------------

func jobCondition(j *batchv1.Job, t batchv1.JobConditionType) *batchv1.JobCondition {
	for i := range j.Status.Conditions {
		c := &j.Status.Conditions[i]
		if c.Type == t && c.Status == corev1.ConditionTrue {
			return c
		}
	}
	return nil
}

func jobFailed(j *batchv1.Job) *batchv1.JobCondition {
	if c := jobCondition(j, batchv1.JobFailed); c != nil {
		return c
	}
	return nil
}

func (a *analyzer) jobs() {
	c := &a.res.Counts.Jobs
	for i := range a.in.Jobs {
		j := &a.in.Jobs[i]
		c.Total++
		owner := a.jobOwn[kube.Key(j.Namespace, j.Name)]
		base := Issue{Kind: "Job", Group: "batch", Namespace: j.Namespace, Name: j.Name, Owner: owner}
		switch {
		case jobCondition(j, batchv1.JobComplete) != nil:
			c.Succeeded++
		case jobFailed(j) != nil:
			f := jobFailed(j)
			c.Failed++
			is := base
			sev := Critical
			if owner != nil && owner.Kind == "CronJob" {
				sev = Warning // the CronJob check escalates when its latest run failed
			}
			msg := f.Message
			if msg == "" {
				msg = fmt.Sprintf("%d failed, %d succeeded", j.Status.Failed, j.Status.Succeeded)
			}
			is.Severity, is.Category, is.Reason, is.Message, is.since = sev, "jobFailed", nonEmpty(f.Reason, "Failed"), msg, f.LastTransitionTime.Time
			a.add(is)
		default:
			if j.Status.Active > 0 {
				c.Running++
			}
		}
		if j.Spec.Suspend != nil && *j.Spec.Suspend {
			c.Suspended++
			is := base
			is.Severity, is.Category, is.Reason, is.Message, is.since = Info, "jobSuspended", "Suspended", "Job is suspended; no pods will be started", j.CreationTimestamp.Time
			a.add(is)
		}
		if j.Status.Active > 0 && j.Status.CompletionTime == nil && j.Status.StartTime != nil && a.older(*j.Status.StartTime, LongRunningJob) {
			c.LongRunning++
			is := base
			is.Severity, is.Category, is.Reason, is.since = Warning, "jobLongRunning", "LongRunning", j.Status.StartTime.Time
			is.Message = fmt.Sprintf("Running for %s; %d active, %d succeeded, %d failed", shortDur(a.now.Sub(j.Status.StartTime.Time)), j.Status.Active, j.Status.Succeeded, j.Status.Failed)
			a.add(is)
		}
	}
}

func nonEmpty(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func (a *analyzer) cronJobs() {
	c := &a.res.Counts.CronJobs
	// Latest job per cronjob.
	latest := map[string]*batchv1.Job{}
	for i := range a.in.Jobs {
		j := &a.in.Jobs[i]
		o := a.jobOwn[kube.Key(j.Namespace, j.Name)]
		if o == nil || o.Kind != "CronJob" {
			continue
		}
		k := kube.Key(j.Namespace, o.Name)
		if cur := latest[k]; cur == nil || j.CreationTimestamp.After(cur.CreationTimestamp.Time) {
			latest[k] = j
		}
	}
	for i := range a.in.CronJobs {
		cj := &a.in.CronJobs[i]
		c.Total++
		base := Issue{Kind: "CronJob", Group: "batch", Namespace: cj.Namespace, Name: cj.Name}
		suspended := cj.Spec.Suspend != nil && *cj.Spec.Suspend
		if suspended {
			c.Suspended++
			is := base
			is.Severity, is.Category, is.Reason, is.since = Info, "cronJobSuspended", "Suspended", cj.CreationTimestamp.Time
			is.Message = fmt.Sprintf("Suspended; schedule %q will not run", cj.Spec.Schedule)
			if cj.Status.LastScheduleTime != nil {
				is.Message += fmt.Sprintf(" (last ran %s ago)", shortDur(a.now.Sub(cj.Status.LastScheduleTime.Time)))
			}
			a.add(is)
		}
		if j := latest[kube.Key(cj.Namespace, cj.Name)]; j != nil {
			if f := jobFailed(j); f != nil {
				c.Failing++
				is := base
				is.Severity, is.Category, is.Reason, is.since = Critical, "cronJobFailing", nonEmpty(f.Reason, "Failed"), f.LastTransitionTime.Time
				is.Message = fmt.Sprintf("Latest job %s failed", j.Name)
				if f.Message != "" {
					is.Message += ": " + f.Message
				}
				a.add(is)
			}
		}
		if !suspended {
			if overdue, next := a.cronOverdue(cj); overdue {
				c.Overdue++
				is := base
				is.Severity, is.Category, is.Reason, is.since = Warning, "cronJobOverdue", "Overdue", next
				is.Message = fmt.Sprintf("Should have run %s ago (schedule %q)", shortDur(a.now.Sub(next)), cj.Spec.Schedule)
				if cj.Status.LastScheduleTime != nil {
					is.Message += fmt.Sprintf("; last scheduled %s ago", shortDur(a.now.Sub(cj.Status.LastScheduleTime.Time)))
				} else {
					is.Message += "; never scheduled"
				}
				a.add(is)
			}
		}
	}
}

// cronOverdue reports whether the next run after the last schedule time (or
// creation) is in the past by more than the grace (or startingDeadlineSeconds).
func (a *analyzer) cronOverdue(cj *batchv1.CronJob) (bool, time.Time) {
	tz := ""
	if cj.Spec.TimeZone != nil {
		tz = *cj.Spec.TimeZone
	}
	s, err := parseCron(cj.Spec.Schedule, tz)
	if err != nil {
		return false, time.Time{}
	}
	from := cj.CreationTimestamp.Time
	if cj.Status.LastScheduleTime != nil {
		from = cj.Status.LastScheduleTime.Time
	}
	if from.IsZero() {
		return false, time.Time{}
	}
	next := s.next(from)
	if next.IsZero() {
		return false, time.Time{}
	}
	grace := cronOverdueGrace
	if d := cj.Spec.StartingDeadlineSeconds; d != nil && time.Duration(*d)*time.Second > grace {
		grace = time.Duration(*d) * time.Second
	}
	return a.now.Sub(next) > grace, next
}

// ---- nodes & storage --------------------------------------------------------

var pressureConds = []corev1.NodeConditionType{corev1.NodeMemoryPressure, corev1.NodeDiskPressure, corev1.NodePIDPressure, corev1.NodeNetworkUnavailable}

func (a *analyzer) nodes() {
	c := &a.res.Counts.Nodes
	podsOn := map[string]int{}
	for i := range a.in.Pods {
		p := &a.in.Pods[i]
		if p.Spec.NodeName != "" && p.Status.Phase != corev1.PodSucceeded && p.Status.Phase != corev1.PodFailed {
			podsOn[p.Spec.NodeName]++
		}
	}
	for i := range a.in.Nodes {
		n := &a.in.Nodes[i]
		c.Total++
		h := NodeHealth{Name: n.Name, Cordoned: n.Spec.Unschedulable, Version: n.Status.NodeInfo.KubeletVersion, Pods: podsOn[n.Name]}
		for l := range n.Labels {
			if r, ok := strings.CutPrefix(l, "node-role.kubernetes.io/"); ok && r != "" {
				h.Roles = append(h.Roles, r)
			}
		}
		sort.Strings(h.Roles)
		base := Issue{Kind: "Node", Group: "", Name: n.Name}
		var readyCond *corev1.NodeCondition
		var pressured []corev1.NodeCondition
		for _, cond := range n.Status.Conditions {
			if cond.Type == corev1.NodeReady {
				cc := cond
				readyCond = &cc
			}
			for _, pt := range pressureConds {
				if cond.Type == pt && cond.Status == corev1.ConditionTrue {
					pressured = append(pressured, cond)
					h.Pressure = append(h.Pressure, string(cond.Type))
				}
			}
		}
		h.Ready = readyCond != nil && readyCond.Status == corev1.ConditionTrue
		if h.Ready {
			c.Ready++
		} else {
			c.NotReady++
			is := base
			is.Severity, is.Category, is.Reason = Critical, "nodeNotReady", "NotReady"
			if readyCond != nil {
				is.Message = nonEmpty(readyCond.Message, readyCond.Reason)
				is.since = readyCond.LastTransitionTime.Time
				if readyCond.Status == corev1.ConditionUnknown {
					is.Reason = "NodeStatusUnknown"
				}
			} else {
				is.Message = "No Ready condition reported"
				is.since = n.CreationTimestamp.Time
			}
			a.add(is)
		}
		if len(pressured) > 0 {
			c.Pressure++
			for _, pcnd := range pressured {
				is := base
				is.Severity, is.Category, is.Reason, is.Message, is.since = Warning, "nodePressure", string(pcnd.Type), nonEmpty(pcnd.Message, pcnd.Reason), pcnd.LastTransitionTime.Time
				a.add(is)
			}
		}
		if n.Spec.Unschedulable {
			c.Cordoned++
			is := base
			is.Severity, is.Category, is.Reason, is.Message, is.since = Info, "nodeCordoned", "SchedulingDisabled",
				fmt.Sprintf("Cordoned; %s still running", kube.Plural(podsOn[n.Name], "pod", "pods")), n.CreationTimestamp.Time
			for _, t := range n.Spec.Taints {
				if t.Key == corev1.TaintNodeUnschedulable && t.TimeAdded != nil {
					is.since = t.TimeAdded.Time
				}
			}
			a.add(is)
		}
		a.res.Nodes = append(a.res.Nodes, h)
	}
	sort.Slice(a.res.Nodes, func(i, j int) bool { return a.res.Nodes[i].Name < a.res.Nodes[j].Name })
}

func (a *analyzer) pvcs() {
	c := &a.res.Counts.PVCs
	for i := range a.in.PVCs {
		p := &a.in.PVCs[i]
		c.Total++
		base := Issue{Kind: "PersistentVolumeClaim", Group: "", Namespace: p.Namespace, Name: p.Name, Reason: string(p.Status.Phase)}
		switch p.Status.Phase {
		case corev1.ClaimBound:
			c.Bound++
		case corev1.ClaimLost:
			c.Lost++
			is := base
			is.Severity, is.Category, is.since = Critical, "pvcLost", p.CreationTimestamp.Time
			is.Message = fmt.Sprintf("Bound volume %s no longer exists", nonEmpty(p.Spec.VolumeName, "(unknown)"))
			a.add(is)
		case corev1.ClaimPending:
			c.Pending++
			if a.older(p.CreationTimestamp, StuckAfter) {
				is := base
				is.Severity, is.Category, is.since = Warning, "pvcPending", p.CreationTimestamp.Time
				sc := "default"
				if p.Spec.StorageClassName != nil {
					sc = *p.Spec.StorageClassName
				}
				is.Message = fmt.Sprintf("Pending for %s (storage class %s)", shortDur(a.now.Sub(p.CreationTimestamp.Time)), sc)
				a.add(is)
			}
		}
	}
}

// ---- events -----------------------------------------------------------------

func eventLast(e *corev1.Event) time.Time {
	if e.Series != nil && !e.Series.LastObservedTime.IsZero() {
		return e.Series.LastObservedTime.Time
	}
	return firstNonZero(e.LastTimestamp.Time, e.EventTime.Time, e.CreationTimestamp.Time)
}

func eventCount(e *corev1.Event) int {
	if e.Series != nil && e.Series.Count > 0 {
		return int(e.Series.Count)
	}
	if e.Count > 0 {
		return int(e.Count)
	}
	return 1
}

func (a *analyzer) events() {
	by := map[string]*EventReason{}
	objs := map[string]map[string]bool{}
	for i := range a.in.Events {
		e := &a.in.Events[i]
		if e.Type != corev1.EventTypeWarning {
			continue
		}
		last := eventLast(e)
		if a.now.Sub(last) > EventWindow {
			continue
		}
		r := by[e.Reason]
		if r == nil {
			r = &EventReason{Reason: e.Reason}
			by[e.Reason] = r
			objs[e.Reason] = map[string]bool{}
		}
		r.Count += eventCount(e)
		io := e.InvolvedObject
		objs[e.Reason][io.Kind+"/"+io.Namespace+"/"+io.Name] = true
		if last.After(r.last) || r.last.IsZero() {
			r.last = last
			r.LatestMessage = truncate(strings.TrimSpace(e.Message))
			ns := io.Namespace
			if ns == "" && io.Kind != "Node" && io.Kind != "Namespace" && io.Kind != "PersistentVolume" {
				ns = e.Namespace // some controllers omit it for namespaced objects
			}
			r.Example = ObjectRef{Kind: io.Kind, Group: kube.Group(io.APIVersion), Namespace: ns, Name: io.Name}
		}
	}
	for reason, r := range by {
		r.Objects = len(objs[reason])
		r.LastSeen = r.last.UTC().Format(time.RFC3339)
		a.res.TopWarnings = append(a.res.TopWarnings, *r)
	}
	sort.Slice(a.res.TopWarnings, func(i, j int) bool {
		x, y := a.res.TopWarnings[i], a.res.TopWarnings[j]
		if x.Count != y.Count {
			return x.Count > y.Count
		}
		if !x.last.Equal(y.last) {
			return x.last.After(y.last)
		}
		return x.Reason < y.Reason
	})
	if len(a.res.TopWarnings) > TopEventReasons {
		a.res.TopWarnings = a.res.TopWarnings[:TopEventReasons]
	}
}

// ---- summary ----------------------------------------------------------------

func (a *analyzer) finish() {
	issues := a.res.Issues
	sort.SliceStable(issues, func(i, j int) bool {
		x, y := issues[i], issues[j]
		if severityRank[x.Severity] != severityRank[y.Severity] {
			return severityRank[x.Severity] < severityRank[y.Severity]
		}
		if !x.since.Equal(y.since) {
			return x.since.After(y.since)
		}
		if x.Namespace != y.Namespace {
			return x.Namespace < y.Namespace
		}
		if x.Kind != y.Kind {
			return x.Kind < y.Kind
		}
		return x.Name < y.Name
	})
	count := map[string]int{}
	worst := map[string]string{}
	for _, is := range issues {
		count[is.Category]++
		if w, ok := worst[is.Category]; !ok || severityRank[is.Severity] < severityRank[w] {
			worst[is.Category] = is.Severity
		}
	}
	defs := categoryDefs
	for _, f := range a.in.Findings {
		if !slices.ContainsFunc(defs, func(d categoryDef) bool { return d.id == f.Category }) {
			defs = append(slices.Clip(defs), categoryDef{f.Category, f.Label, f.Section, f.Severity})
		}
	}
	for _, d := range defs {
		if n := count[d.id]; n > 0 {
			a.res.Categories = append(a.res.Categories, Category{ID: d.id, Label: d.label, Section: d.section, Severity: worst[d.id], Count: n})
		}
	}
	sort.SliceStable(a.res.Categories, func(i, j int) bool {
		return severityRank[a.res.Categories[i].Severity] < severityRank[a.res.Categories[j].Severity]
	})
}
