package overview

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

var now = time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)

func ago(d time.Duration) metav1.Time { return metav1.NewTime(now.Add(-d)) }
func agoP(d time.Duration) *metav1.Time {
	t := ago(d)
	return &t
}
func ptr[T any](v T) *T { return &v }

func meta(ns, name string, age time.Duration, owners ...metav1.OwnerReference) metav1.ObjectMeta {
	return metav1.ObjectMeta{Namespace: ns, Name: name, CreationTimestamp: ago(age), OwnerReferences: owners}
}

func ownedBy(apiVersion, kind, name string) metav1.OwnerReference {
	return metav1.OwnerReference{APIVersion: apiVersion, Kind: kind, Name: name, Controller: ptr(true)}
}

func readyCond(ready bool, since time.Duration) corev1.PodCondition {
	s := corev1.ConditionFalse
	if ready {
		s = corev1.ConditionTrue
	}
	return corev1.PodCondition{Type: corev1.PodReady, Status: s, LastTransitionTime: ago(since)}
}

func runningPod(ns, name string, age time.Duration, owners ...metav1.OwnerReference) corev1.Pod {
	return corev1.Pod{
		ObjectMeta: meta(ns, name, age, owners...),
		Spec: corev1.PodSpec{NodeName: "node-1", Containers: []corev1.Container{{Name: "app", Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("250m"), corev1.ResourceMemory: resource.MustParse("256Mi")},
		}}}},
		Status: corev1.PodStatus{
			Phase:      corev1.PodRunning,
			Conditions: []corev1.PodCondition{readyCond(true, age)},
			ContainerStatuses: []corev1.ContainerStatus{{
				Name: "app", Ready: true, State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{StartedAt: ago(age)}},
			}},
		},
	}
}

func waitingPod(ns, name, reason, msg string, age time.Duration, restarts int32, owners ...metav1.OwnerReference) corev1.Pod {
	p := runningPod(ns, name, age, owners...)
	p.Status.Conditions = []corev1.PodCondition{readyCond(false, age-time.Minute)}
	p.Status.ContainerStatuses[0] = corev1.ContainerStatus{
		Name: "app", Image: "example/app:1", RestartCount: restarts,
		State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: reason, Message: msg}},
		LastTerminationState: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{
			ExitCode: 1, Reason: "Error", StartedAt: ago(3 * time.Minute), FinishedAt: ago(2 * time.Minute),
		}},
	}
	return p
}

// scenario builds a namespace with one of everything that can go wrong.
func scenario() Input {
	dep := func(name string) metav1.OwnerReference { return ownedBy("apps/v1", "Deployment", name) }
	rs := func(name string) metav1.OwnerReference { return ownedBy("apps/v1", "ReplicaSet", name) }

	oom := runningPod("shop", "cart-7d9f-oom", 2*time.Hour, rs("cart-7d9f"))
	oom.Spec.Containers[0].Resources.Limits = corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("128Mi")}
	oom.Status.ContainerStatuses[0].RestartCount = 2
	oom.Status.ContainerStatuses[0].LastTerminationState = corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{
		Reason: "OOMKilled", ExitCode: 137, FinishedAt: ago(10 * time.Minute),
	}}

	oldOOM := runningPod("shop", "cart-7d9f-old-oom", 5*time.Hour, rs("cart-7d9f"))
	oldOOM.Status.ContainerStatuses[0].LastTerminationState = corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{
		Reason: "OOMKilled", FinishedAt: ago(3 * time.Hour),
	}}

	flappy := runningPod("shop", "search-0", 6*time.Hour, ownedBy("apps/v1", "StatefulSet", "search"))
	flappy.Status.ContainerStatuses[0].RestartCount = 9

	stuckTerm := runningPod("shop", "legacy-abc", 3*time.Hour)
	stuckTerm.DeletionTimestamp = agoP(20 * time.Minute)
	stuckTerm.Finalizers = []string{"example.com/cleanup"}

	freshTerm := runningPod("shop", "legacy-new", 3*time.Hour)
	freshTerm.DeletionTimestamp = agoP(time.Minute)

	unsched := corev1.Pod{
		ObjectMeta: meta("shop", "gpu-worker-x1", 30*time.Minute, rs("gpu-worker-55")),
		Status: corev1.PodStatus{Phase: corev1.PodPending, Conditions: []corev1.PodCondition{{
			Type: corev1.PodScheduled, Status: corev1.ConditionFalse, Reason: "Unschedulable",
			Message: "0/3 nodes are available: 3 Insufficient nvidia.com/gpu.", LastTransitionTime: ago(30 * time.Minute),
		}}},
	}
	freshPending := corev1.Pod{ObjectMeta: meta("shop", "gpu-worker-x2", time.Minute, rs("gpu-worker-55")), Status: corev1.PodStatus{Phase: corev1.PodPending}}

	initBlocked := waitingPod("shop", "api-66-init", "PodInitializing", "", 15*time.Minute, 0, rs("api-66"))
	initBlocked.Status.Phase = corev1.PodPending
	initBlocked.Status.InitContainerStatuses = []corev1.ContainerStatus{{Name: "wait-for-db", State: corev1.ContainerState{
		Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff", Message: "back-off 5m0s restarting failed container"},
	}}}

	cfgErr := waitingPod("shop", "api-66-cfg", "CreateContainerConfigError", `secret "api-keys" not found`, 15*time.Minute, 0, rs("api-66"))

	jobPodFailed := runningPod("batch", "nightly-2900-abc", 2*time.Hour, ownedBy("batch/v1", "Job", "nightly-2900"))
	jobPodFailed.Status.Phase = corev1.PodFailed
	jobPodFailed.Status.Conditions = []corev1.PodCondition{readyCond(false, 90*time.Minute)}
	jobPodFailed.Status.ContainerStatuses[0].State = corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: 1, Reason: "Error"}}

	notReady := runningPod("shop", "web-5c-nr", time.Hour, rs("web-5c"))
	notReady.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionFalse, LastTransitionTime: ago(20 * time.Minute), Message: "containers with unready status: [app]"}}
	notReady.Status.ContainerStatuses[0].Ready = false

	// Between crashes the table shows "Error" while the phase stays Running.
	restarting := runningPod("shop", "worker-restarting", 2*time.Hour)
	restarting.Status.Conditions = []corev1.PodCondition{readyCond(false, 90*time.Minute)}
	restarting.Status.ContainerStatuses[0].Ready = false
	restarting.Status.ContainerStatuses[0].RestartCount = 3
	restarting.Status.ContainerStatuses[0].State = corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: 3, Reason: "Error"}}

	pods := []corev1.Pod{
		restarting,
		runningPod("shop", "web-5c-a", time.Hour, rs("web-5c")),
		waitingPod("shop", "web-5c-b", "CrashLoopBackOff", "back-off 5m0s", time.Hour, 12, rs("web-5c")),
		waitingPod("shop", "web-5c-c", "CrashLoopBackOff", "back-off 5m0s", 50*time.Minute, 11, rs("web-5c")),
		waitingPod("shop", "web-5c-d", "CrashLoopBackOff", "back-off 5m0s", 40*time.Minute, 10, rs("web-5c")),
		waitingPod("shop", "img-1", "ErrImagePull", "manifest unknown", 10*time.Minute, 0),
		oom, oldOOM, flappy, stuckTerm, freshTerm, unsched, freshPending, initBlocked, cfgErr, jobPodFailed, notReady,
	}

	deps := []appsv1.Deployment{
		{ObjectMeta: meta("shop", "web", 24*time.Hour), Spec: appsv1.DeploymentSpec{Replicas: ptr[int32](4)},
			Status: appsv1.DeploymentStatus{ObservedGeneration: 0, Replicas: 4, UpdatedReplicas: 4, ReadyReplicas: 1, AvailableReplicas: 1,
				Conditions: []appsv1.DeploymentCondition{{Type: appsv1.DeploymentAvailable, Status: corev1.ConditionFalse, Reason: "MinimumReplicasUnavailable",
					Message: "Deployment does not have minimum availability.", LastTransitionTime: ago(55 * time.Minute)}}}},
		{ObjectMeta: meta("shop", "api", 24*time.Hour), Spec: appsv1.DeploymentSpec{Replicas: ptr[int32](2)},
			Status: appsv1.DeploymentStatus{Replicas: 3, UpdatedReplicas: 1, ReadyReplicas: 2, AvailableReplicas: 2,
				Conditions: []appsv1.DeploymentCondition{{Type: appsv1.DeploymentProgressing, Status: corev1.ConditionFalse, Reason: "ProgressDeadlineExceeded",
					Message: `ReplicaSet "api-66" has timed out progressing.`, LastTransitionTime: ago(5 * time.Minute)}}}},
		{ObjectMeta: meta("shop", "cart", 24*time.Hour), Spec: appsv1.DeploymentSpec{Replicas: ptr[int32](2), Paused: true},
			Status: appsv1.DeploymentStatus{Replicas: 2, UpdatedReplicas: 2, ReadyReplicas: 2, AvailableReplicas: 2}},
		{ObjectMeta: meta("shop", "healthy", 24*time.Hour), Spec: appsv1.DeploymentSpec{Replicas: ptr[int32](1)},
			Status: appsv1.DeploymentStatus{Replicas: 1, UpdatedReplicas: 1, ReadyReplicas: 1, AvailableReplicas: 1}},
	}
	rss := []appsv1.ReplicaSet{
		{ObjectMeta: meta("shop", "web-5c", time.Hour, dep("web"))},
		{ObjectMeta: meta("shop", "api-66", time.Hour, dep("api"))},
		{ObjectMeta: meta("shop", "cart-7d9f", time.Hour, dep("cart"))},
		// gpu-worker-55's deployment is not listed: owner stays the ReplicaSet... unless the RS is listed.
	}
	sts := []appsv1.StatefulSet{{ObjectMeta: meta("shop", "search", 24*time.Hour), Spec: appsv1.StatefulSetSpec{Replicas: ptr[int32](3)},
		Status: appsv1.StatefulSetStatus{ReadyReplicas: 2}}}
	dss := []appsv1.DaemonSet{{ObjectMeta: meta("kube-system", "log-agent", 24*time.Hour),
		Status: appsv1.DaemonSetStatus{DesiredNumberScheduled: 3, NumberReady: 2, NumberUnavailable: 1, UpdatedNumberScheduled: 3}}}

	failedCond := func(age time.Duration) []batchv1.JobCondition {
		return []batchv1.JobCondition{{Type: batchv1.JobFailed, Status: corev1.ConditionTrue, Reason: "BackoffLimitExceeded",
			Message: "Job has reached the specified backoff limit", LastTransitionTime: ago(age)}}
	}
	completeCond := []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue, LastTransitionTime: ago(26 * time.Hour)}}
	cron := func(name string) metav1.OwnerReference { return ownedBy("batch/v1", "CronJob", name) }
	jobs := []batchv1.Job{
		{ObjectMeta: meta("batch", "nightly-2800", 26*time.Hour, cron("nightly")), Status: batchv1.JobStatus{Succeeded: 1, Conditions: completeCond}},
		{ObjectMeta: meta("batch", "nightly-2900", 2*time.Hour, cron("nightly")), Status: batchv1.JobStatus{Failed: 6, Conditions: failedCond(80 * time.Minute)}},
		{ObjectMeta: meta("batch", "backfill", 3*time.Hour), Status: batchv1.JobStatus{Active: 1, StartTime: agoP(3 * time.Hour)}},
		{ObjectMeta: meta("batch", "one-off", 3*time.Hour), Status: batchv1.JobStatus{Failed: 1, Conditions: failedCond(2 * time.Hour)}},
		{ObjectMeta: meta("batch", "paused-job", 3*time.Hour), Spec: batchv1.JobSpec{Suspend: ptr(true)}},
	}
	cronjobs := []batchv1.CronJob{
		{ObjectMeta: meta("batch", "nightly", 30*24*time.Hour), Spec: batchv1.CronJobSpec{Schedule: "0 10 * * *"},
			Status: batchv1.CronJobStatus{LastScheduleTime: agoP(2 * time.Hour)}},
		{ObjectMeta: meta("batch", "reports", 30*24*time.Hour), Spec: batchv1.CronJobSpec{Schedule: "*/15 * * * *", Suspend: ptr(true)},
			Status: batchv1.CronJobStatus{LastScheduleTime: agoP(4 * 24 * time.Hour)}},
		// Every 5 minutes, but last ran an hour ago: overdue (the controller is stuck or the deadline was missed).
		{ObjectMeta: meta("batch", "heartbeat", 30*24*time.Hour), Spec: batchv1.CronJobSpec{Schedule: "*/5 * * * *"},
			Status: batchv1.CronJobStatus{LastScheduleTime: agoP(time.Hour)}},
	}
	nodes := []corev1.Node{
		{ObjectMeta: metav1.ObjectMeta{Name: "node-1", Labels: map[string]string{"node-role.kubernetes.io/control-plane": ""}},
			Status: corev1.NodeStatus{Allocatable: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4"), corev1.ResourceMemory: resource.MustParse("16Gi")}, Conditions: []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue}}}},
		{ObjectMeta: metav1.ObjectMeta{Name: "node-2"},
			Status: corev1.NodeStatus{Allocatable: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4"), corev1.ResourceMemory: resource.MustParse("16Gi")}, Conditions: []corev1.NodeCondition{
				{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
				{Type: corev1.NodeDiskPressure, Status: corev1.ConditionTrue, Reason: "KubeletHasDiskPressure", Message: "kubelet has disk pressure", LastTransitionTime: ago(7 * time.Minute)},
			}}},
		{ObjectMeta: metav1.ObjectMeta{Name: "node-3", CreationTimestamp: ago(48 * time.Hour)}, Spec: corev1.NodeSpec{Unschedulable: true},
			Status: corev1.NodeStatus{Allocatable: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4"), corev1.ResourceMemory: resource.MustParse("16Gi")}, Conditions: []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionUnknown,
				Reason: "NodeStatusUnknown", Message: "Kubelet stopped posting node status.", LastTransitionTime: ago(12 * time.Minute)}}}},
	}
	pvcs := []corev1.PersistentVolumeClaim{
		{ObjectMeta: meta("shop", "data-search-2", time.Hour), Spec: corev1.PersistentVolumeClaimSpec{StorageClassName: ptr("fast-ssd")}, Status: corev1.PersistentVolumeClaimStatus{Phase: corev1.ClaimPending}},
		{ObjectMeta: meta("shop", "old-data", 90*24*time.Hour), Spec: corev1.PersistentVolumeClaimSpec{VolumeName: "pvc-123"}, Status: corev1.PersistentVolumeClaimStatus{Phase: corev1.ClaimLost}},
		{ObjectMeta: meta("shop", "data-search-0", time.Hour), Status: corev1.PersistentVolumeClaimStatus{Phase: corev1.ClaimBound}},
	}
	ev := func(reason, msg string, count int32, last time.Duration, kind, name string) corev1.Event {
		return corev1.Event{ObjectMeta: meta("shop", name+"."+reason, last), Type: corev1.EventTypeWarning, Reason: reason, Message: msg, Count: count,
			LastTimestamp: ago(last), InvolvedObject: corev1.ObjectReference{Kind: kind, Name: name, Namespace: "shop", APIVersion: "v1"}}
	}
	events := []corev1.Event{
		ev("BackOff", "Back-off restarting failed container app", 40, 30*time.Second, "Pod", "web-5c-b"),
		ev("BackOff", "Back-off restarting failed container app", 35, time.Minute, "Pod", "web-5c-c"),
		ev("FailedScheduling", "0/3 nodes are available: 3 Insufficient nvidia.com/gpu.", 12, 2*time.Minute, "Pod", "gpu-worker-x1"),
		ev("Unhealthy", "Readiness probe failed: HTTP probe failed with statuscode: 503", 30, 3*time.Minute, "Pod", "web-5c-nr"),
		ev("FailedMount", "too old", 99, 2*time.Hour, "Pod", "old"),
		{ObjectMeta: meta("shop", "normal", time.Minute), Type: corev1.EventTypeNormal, Reason: "Pulled", Count: 500, LastTimestamp: ago(time.Minute)},
	}
	gwSpec := map[string]any{"gatewayClassName": "eg"}
	gateways := []unstructured.Unstructured{
		gwObj("Gateway", "shop", "edge", time.Hour, gwSpec, map[string]any{"conditions": []any{
			c("Accepted", "True", "Accepted", ""), c("Programmed", "False", "AddressNotAssigned", "No addresses have been assigned to the Gateway"),
		}}),
		gwObj("Gateway", "shop", "public", time.Hour, gwSpec, map[string]any{
			"conditions": []any{c("Accepted", "True", "Accepted", ""), c("Programmed", "True", "Programmed", "")},
			"listeners":  []any{map[string]any{"name": "https", "conditions": []any{c("ResolvedRefs", "False", "InvalidCertificateRef", "Secret shop/tls does not exist.")}}},
		}),
	}
	parent := map[string]any{"parentRefs": []any{map[string]any{"name": "public", "sectionName": "admin"}}}
	routes := []unstructured.Unstructured{
		gwObj("HTTPRoute", "shop", "checkout", time.Hour, parent, map[string]any{"parents": []any{map[string]any{
			"parentRef": map[string]any{"name": "public", "sectionName": "admin"}, "conditions": []any{c("Accepted", "False", "NoMatchingParent", "No listeners match this parent ref")},
		}}}),
		gwObj("HTTPRoute", "shop", "cart-api", time.Hour, parent, map[string]any{"parents": []any{map[string]any{
			"parentRef": map[string]any{"name": "public"}, "conditions": []any{
				c("Accepted", "True", "Accepted", ""), c("ResolvedRefs", "False", "RefNotPermitted", "Backend ref to Service billing/api not permitted by any ReferenceGrant."),
			},
		}}}),
	}
	return Input{Now: now, Pods: pods, Deployments: deps, ReplicaSets: rss, StatefulSets: sts, DaemonSets: dss,
		Jobs: jobs, CronJobs: cronjobs, Nodes: nodes, PVCs: pvcs, Events: events, Gateways: gateways, Routes: routes}
}

func issuesBy(res *Result, cat string) []Issue {
	var out []Issue
	for _, is := range res.Issues {
		if is.Category == cat {
			out = append(out, is)
		}
	}
	return out
}

func names(is []Issue) []string {
	var out []string
	for _, i := range is {
		out = append(out, i.Name)
	}
	return out
}

func TestAnalyzeScenario(t *testing.T) {
	res := Analyze(scenario())

	if out := os.Getenv("OVERVIEW_FIXTURE_OUT"); out != "" {
		b, _ := json.MarshalIndent(res, "", "  ")
		if err := os.WriteFile(out, b, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	expect := map[string][]string{
		"crashLoop":                  {"web-5c-d", "web-5c-c", "web-5c-b", "worker-restarting"}, // newest problem first
		"imagePull":                  {"img-1"},
		"createContainerConfigError": {"api-66-cfg"},
		"initBlocked":                {"api-66-init"},
		"oomKilled":                  {"cart-7d9f-oom"},
		"podFailed":                  {"nightly-2900-abc"},
		"stuckTerminating":           {"legacy-abc"},
		"stuckPending":               {"gpu-worker-x1"},
		"notReady":                   {"web-5c-nr"},
		"highRestarts":               {"search-0"},
		"deploymentUnavailable":      {"web"},
		"progressDeadlineExceeded":   {"api"},
		"deploymentPaused":           {"cart"},
		"statefulSetNotReady":        {"search"},
		"daemonSetNotReady":          {"log-agent"},
		"jobFailed":                  {"one-off", "nightly-2900"}, // standalone failure is critical
		"jobLongRunning":             {"backfill"},
		"jobSuspended":               {"paused-job"},
		"cronJobFailing":             {"nightly"},
		"cronJobSuspended":           {"reports"},
		"cronJobOverdue":             {"heartbeat"},
		"nodeNotReady":               {"node-3"},
		"nodePressure":               {"node-2"},
		"nodeCordoned":               {"node-3"},
		"pvcPending":                 {"data-search-2"},
		"pvcLost":                    {"old-data"},
		"gatewayNotReady":            {"edge"},
		"gatewayListener":            {"public"},
		"routeNotAccepted":           {"checkout"},
		"routeUnresolvedRefs":        {"cart-api"},
	}
	for cat, want := range expect {
		got := names(issuesBy(res, cat))
		if len(got) != len(want) {
			t.Errorf("%s: got %v, want %v", cat, got, want)
			continue
		}
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("%s: got %v, want %v", cat, got, want)
				break
			}
		}
	}
	if got := issuesBy(res, "rolling"); len(got) != 0 {
		t.Errorf("rolling: stalled rollouts should not also be reported as rolling, got %v", names(got))
	}
	for _, d := range categoryDefs {
		// Argo CD categories: argocd_test.go; alerts: alerts_test.go; Argo
		// Workflows: argowf_test.go.
		if _, ok := expect[d.id]; !ok && d.id != "rolling" && d.id != "workflowFailed" && d.section != "argocd" && d.section != "alerts" {
			t.Errorf("category %s is not covered by the scenario", d.id)
		}
	}

	// Owner resolution: Pod → ReplicaSet → Deployment, Pod → Job → CronJob.
	crash := issuesBy(res, "crashLoop")[0]
	if crash.Owner == nil || *crash.Owner != (Owner{Group: "apps", Kind: "Deployment", Name: "web"}) {
		t.Errorf("crashloop owner = %+v", crash.Owner)
	}
	if crash.Count != 10 || crash.Message != "container app last terminated: exit 1, Error; 10 restarts" {
		t.Errorf("crashloop count/message = %d %q", crash.Count, crash.Message)
	}
	if is := issuesBy(res, "crashLoop")[3]; is.Reason != "Error" || is.Message != "container app exited 3 and is restarting; 3 restarts" {
		t.Errorf("restarting pod = %q %q", is.Reason, is.Message)
	}
	if o := issuesBy(res, "podFailed")[0].Owner; o == nil || *o != (Owner{Group: "batch", Kind: "CronJob", Name: "nightly"}) {
		t.Errorf("job pod owner = %+v", o)
	}
	if o := issuesBy(res, "stuckPending")[0].Owner; o == nil || o.Kind != "ReplicaSet" || o.Name != "gpu-worker-55" {
		t.Errorf("unresolvable RS should remain the owner, got %+v", o)
	}
	if o := issuesBy(res, "highRestarts")[0].Owner; o == nil || o.Kind != "StatefulSet" {
		t.Errorf("statefulset pod owner = %+v", o)
	}
	if o := issuesBy(res, "stuckTerminating")[0].Owner; o != nil {
		t.Errorf("bare pod should have no owner, got %+v", o)
	}

	if is := issuesBy(res, "stuckPending")[0]; is.Reason != "Unschedulable" || is.Message != "Pending for 30m: 0/3 nodes are available: 3 Insufficient nvidia.com/gpu." {
		t.Errorf("stuck pending = %q %q", is.Reason, is.Message)
	}
	if is := issuesBy(res, "initBlocked")[0]; is.Reason != "Init:CrashLoopBackOff" || is.Severity != Critical {
		t.Errorf("init blocked = %+v", is)
	}
	if is := issuesBy(res, "oomKilled")[0]; is.Message != "container app was OOMKilled 10m ago; memory limit 128Mi" {
		t.Errorf("oom message = %q", is.Message)
	}
	if is := issuesBy(res, "nodeNotReady")[0]; is.Reason != "NodeStatusUnknown" || is.Since != "2026-11-03T11:48:00Z" {
		t.Errorf("node not ready = %+v", is)
	}
	sev := map[string]string{}
	for _, is := range issuesBy(res, "jobFailed") {
		sev[is.Name] = is.Severity
	}
	if sev["nightly-2900"] != Warning || sev["one-off"] != Critical {
		t.Errorf("job failure severities = %v", sev)
	}

	// Sorted by severity, then most recent first.
	for i := 1; i < len(res.Issues); i++ {
		a, b := res.Issues[i-1], res.Issues[i]
		if severityRank[a.Severity] > severityRank[b.Severity] {
			t.Fatalf("issue %d (%s %s) sorted after less severe %s %s", i, b.Severity, b.Name, a.Severity, a.Name)
		}
		if a.Severity == b.Severity && a.since.Before(b.since) {
			t.Fatalf("issue %s (%s) sorted before newer %s (%s)", a.Name, a.Since, b.Name, b.Since)
		}
	}

	pc := res.Counts.Pods
	if pc.Total != 17 || pc.CrashLoop != 4 || pc.ImagePull != 1 || pc.StuckTerminating != 1 || pc.Terminating != 2 ||
		pc.StuckPending != 1 || pc.Pending != 3 || pc.HighRestarts != 4 || pc.OOMKilled != 1 || pc.Failed != 1 || pc.InitBlocked != 1 {
		t.Errorf("pod counts = %+v", pc)
	}
	if c := res.Counts.Deployments; c.Total != 4 || c.Unavailable != 1 || c.ProgressDeadlineExceeded != 1 || c.Paused != 1 || c.Healthy != 2 {
		t.Errorf("deployment counts = %+v", c)
	}
	if c := res.Counts.Nodes; c.Total != 3 || c.Ready != 2 || c.NotReady != 1 || c.Pressure != 1 || c.Cordoned != 1 {
		t.Errorf("node counts = %+v", c)
	}
	if c := res.Counts.CronJobs; c.Failing != 1 || c.Suspended != 1 || c.Overdue != 1 {
		t.Errorf("cronjob counts = %+v", c)
	}

	// Categories: one per category with issues, most severe first.
	if res.Categories[0].Severity != Critical || res.Categories[len(res.Categories)-1].Severity != Info {
		t.Errorf("categories not ordered by severity: %+v", res.Categories)
	}
	for _, c := range res.Categories {
		if c.Count != len(issuesBy(res, c.ID)) {
			t.Errorf("category %s count %d != %d issues", c.ID, c.Count, len(issuesBy(res, c.ID)))
		}
	}

	// Nodes strip.
	if len(res.Nodes) != 3 || !res.Nodes[0].Ready || res.Nodes[0].Roles[0] != "control-plane" || res.Nodes[1].Pressure[0] != "DiskPressure" || !res.Nodes[2].Cordoned || res.Nodes[2].Ready {
		t.Errorf("nodes = %+v", res.Nodes)
	}

	// Warning events: last hour only, grouped by reason, by count.
	tw := res.TopWarnings
	if len(tw) != 3 || tw[0].Reason != "BackOff" || tw[0].Count != 75 || tw[0].Objects != 2 || tw[0].Example.Name != "web-5c-b" {
		t.Errorf("top warnings = %+v", tw)
	}
	if res.GeneratedAt != "2026-11-03T12:00:00Z" {
		t.Errorf("generatedAt = %s", res.GeneratedAt)
	}
}
