package columns

import (
	"encoding/json"
	"testing"
)

// The helpers built-in columns call: status words from the fields a Ready
// ratio can't show, selectors, durations, conditions and byte sizes.
func TestStatusFunctions(t *testing.T) {
	for _, c := range []struct{ fn, obj, want string }{
		{"deploymentstatus", `{"metadata": {"generation": 2}, "spec": {"replicas": 3}, "status": {"observedGeneration": 2, "replicas": 3, "updatedReplicas": 3, "readyReplicas": 3, "availableReplicas": 3}}`, "Available"},
		{"deploymentstatus", `{"metadata": {"generation": 2}, "spec": {"replicas": 3}, "status": {"observedGeneration": 2, "replicas": 3, "updatedReplicas": 3, "readyReplicas": 2, "availableReplicas": 2}}`, "Degraded"},
		{"deploymentstatus", `{"metadata": {"generation": 2}, "spec": {"replicas": 3}, "status": {"observedGeneration": 2, "replicas": 3, "updatedReplicas": 3}}`, "Unavailable"},
		{"deploymentstatus", `{"metadata": {"generation": 3}, "spec": {"replicas": 3}, "status": {"observedGeneration": 3, "replicas": 4, "updatedReplicas": 1, "readyReplicas": 3, "availableReplicas": 3}}`, "Progressing"},
		{"deploymentstatus", `{"spec": {"replicas": 3}, "status": {"conditions": [{"type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded"}]}}`, "Stalled"},
		{"deploymentstatus", `{"spec": {"replicas": 0}, "status": {}}`, "Scaled down"},
		{"deploymentstatus", `{"spec": {"replicas": 2, "paused": true}, "status": {}}`, "Paused"},
		{"statefulsetstatus", `{"spec": {"replicas": 3}, "status": {"replicas": 3, "readyReplicas": 3, "currentRevision": "a", "updateRevision": "b"}}`, "Progressing"},
		{"daemonsetstatus", `{"status": {"desiredNumberScheduled": 3, "numberAvailable": 2, "updatedNumberScheduled": 3}}`, "Degraded"},
		{"jobstatus", `{"status": {"conditions": [{"type": "Failed", "status": "True"}]}}`, "Failed"},
		{"podstatus", `{"status": {"phase": "Pending", "initContainerStatuses": [{"state": {"terminated": {"exitCode": 1}}}]}}`, "Init:Error"},
		{"podstatus", `{"status": {"phase": "Running", "containerStatuses": [{"state": {"running": {}}}, {"state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}}`, "CrashLoopBackOff"},
		{"podstatus", `{"metadata": {"deletionTimestamp": "2026-01-01T00:00:00Z"}, "status": {"phase": "Running"}}`, "Terminating"},
		{"podstatus", `{"status": {"phase": "Running", "containerStatuses": [{"state": {"running": {}}}]}}`, "Running"},
		{".spec.selector | selector", `{"spec": {"selector": {"matchLabels": {"app": "web"}, "matchExpressions": [{"key": "tier", "operator": "In", "values": ["a", "b"]}, {"key": "canary", "operator": "DoesNotExist"}]}}}`, "app=web,tier in (a,b),!canary"},
		{"duration(.status.startTime; .status.completionTime)", `{"status": {"startTime": "2026-01-01T00:00:00Z", "completionTime": "2026-01-01T03:07:00Z"}}`, "3h07m"},
		{"nodestatus", `{"spec": {"unschedulable": true}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}}`, "Ready,SchedulingDisabled"},
		{`condition("Available").reason`, `{"status": {"conditions": [{"type": "Available", "status": "False", "reason": "MissingEndpoints"}]}}`, "MissingEndpoints"},
		{".status.allocatable.memory | tobytes | tostring", `{"status": {"allocatable": {"memory": "1536Mi"}}}`, "1610612736"},
	} {
		code, err := compile(c.fn)
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(c.obj), &m); err != nil {
			t.Fatal(err)
		}
		if got, err := run(code, m); err != nil || got != c.want {
			t.Errorf("%s %s: got %v (%v), want %s", c.fn, c.obj, got, err, c.want)
		}
	}
}
