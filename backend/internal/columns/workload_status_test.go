package columns

import (
	"encoding/json"
	"testing"
)

// Deployment Status words, from the fields a Ready ratio can't show.
func TestDeploymentStatus(t *testing.T) {
	code, err := compile(deploymentStatus)
	if err != nil {
		t.Fatal(err)
	}
	for obj, want := range map[string]string{
		`{"metadata": {"generation": 2}, "spec": {"replicas": 3}, "status": {"observedGeneration": 2, "replicas": 3, "updatedReplicas": 3, "readyReplicas": 3, "availableReplicas": 3}}`: "Available",
		`{"metadata": {"generation": 2}, "spec": {"replicas": 3}, "status": {"observedGeneration": 2, "replicas": 3, "updatedReplicas": 3, "readyReplicas": 2, "availableReplicas": 2}}`: "Degraded",
		`{"metadata": {"generation": 2}, "spec": {"replicas": 3}, "status": {"observedGeneration": 2, "replicas": 3, "updatedReplicas": 3}}`:                                             "Unavailable",
		`{"metadata": {"generation": 3}, "spec": {"replicas": 3}, "status": {"observedGeneration": 3, "replicas": 4, "updatedReplicas": 1, "readyReplicas": 3, "availableReplicas": 3}}`: "Progressing",
		`{"spec": {"replicas": 3}, "status": {"conditions": [{"type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded"}]}}`:                                        "Stalled",
		`{"spec": {"replicas": 0}, "status": {}}`:                 "Scaled down",
		`{"spec": {"replicas": 2, "paused": true}, "status": {}}`: "Paused",
	} {
		var m map[string]any
		if err := json.Unmarshal([]byte(obj), &m); err != nil {
			t.Fatal(err)
		}
		if got, err := run(code, m); err != nil || got != want {
			t.Errorf("%s: got %v (%v), want %s", obj, got, err, want)
		}
	}
	for _, q := range []string{statefulSetStatus, daemonSetStatus} {
		if _, err := compile(q); err != nil {
			t.Error(err)
		}
	}
}
