package overview

import (
	"strings"
	"testing"
	"time"
)

func wfObj(name, phase string, finished time.Time, labels map[string]any, tmpl string) map[string]any {
	spec := map[string]any{}
	if tmpl != "" {
		spec["workflowTemplateRef"] = map[string]any{"name": tmpl}
	}
	status := map[string]any{"phase": phase}
	if !finished.IsZero() {
		status["finishedAt"] = finished.UTC().Format(time.RFC3339)
	}
	if phase == "Failed" {
		status["nodes"] = map[string]any{
			name + "-1": map[string]any{"type": "Pod", "phase": "Failed", "displayName": "unit-tests", "message": "exit code 3", "finishedAt": "2026-01-01T00:00:00Z"},
		}
	}
	return map[string]any{
		"metadata": map[string]any{"name": name, "namespace": "demo", "labels": labels},
		"spec":     spec,
		"status":   status,
	}
}

func TestArgoWorkflowsFailed(t *testing.T) {
	now := time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)
	cron := map[string]any{"workflows.argoproj.io/cron-workflow": "nightly"}
	in := Input{Now: now, Workflows: []map[string]any{
		// A one-off failure: critical, message from the failed step.
		wfObj("adhoc-1", "Failed", now.Add(-2*time.Hour), nil, ""),
		// Cron: two failures, latest run failed → one critical issue.
		wfObj("nightly-1", "Failed", now.Add(-20*time.Hour), cron, ""),
		wfObj("nightly-2", "Succeeded", now.Add(-10*time.Hour), cron, ""),
		wfObj("nightly-3", "Error", now.Add(-1*time.Hour), cron, ""),
		// Template: failed, then a later success → warning.
		wfObj("build-1", "Failed", now.Add(-5*time.Hour), nil, "build"),
		wfObj("build-2", "Succeeded", now.Add(-4*time.Hour), nil, "build"),
		// Too old, and still running: ignored.
		wfObj("old-1", "Failed", now.Add(-30*time.Hour), nil, ""),
		wfObj("live-1", "Running", time.Time{}, nil, ""),
	}}
	res := Analyze(in)
	got := map[string]Issue{}
	for _, is := range res.Issues {
		if is.Category == "workflowFailed" {
			got[is.Name] = is
		}
	}
	if len(got) != 3 {
		t.Fatalf("issues = %+v", got)
	}
	if is := got["adhoc-1"]; is.Severity != Critical || is.Message != "unit-tests: exit code 3" || is.Owner != nil {
		t.Errorf("adhoc = %+v", is)
	}
	if is := got["nightly-3"]; is.Severity != Critical || !strings.HasPrefix(is.Message, "2 failed runs in 24h") || is.Owner == nil || is.Owner.Kind != "CronWorkflow" {
		t.Errorf("nightly = %+v", is)
	}
	if is := got["build-1"]; is.Severity != Warning || !strings.Contains(is.Message, "later run succeeded") || is.Owner.Kind != "WorkflowTemplate" {
		t.Errorf("build = %+v", is)
	}
	found := false
	for _, c := range res.Categories {
		if c.ID == "workflowFailed" {
			found = c.Count == 3 && c.Severity == Critical
		}
	}
	if !found {
		t.Errorf("category missing or wrong: %+v", res.Categories)
	}
	// No CRD: nothing.
	if res := Analyze(Input{Now: now}); len(res.Issues) != 0 {
		t.Errorf("issues without workflows: %+v", res.Issues)
	}
}
