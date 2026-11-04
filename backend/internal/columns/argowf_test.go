package columns

import (
	"encoding/json"
	"testing"
)

// The Argo Workflows default columns evaluate to the expected cells.
func TestArgoWorkflowsColumns(t *testing.T) {
	row := func(key, obj string) map[string]any {
		t.Helper()
		var m map[string]any
		if err := json.Unmarshal([]byte(obj), &m); err != nil {
			t.Fatal(err)
		}
		e := NewEvaluator(builtin[key])
		cells, errs := e.Row(m)
		out := map[string]any{}
		for i, c := range e.Columns() {
			if errs[i] != nil {
				t.Fatalf("%s %s: %v", key, c.Name, errs[i])
			}
			out[c.Name] = cells[i]
		}
		return out
	}

	wf := row("workflows.argoproj.io", `{"metadata": {"name": "w", "creationTimestamp": "2026-01-01T00:00:00Z"},
	  "spec": {"workflowTemplateRef": {"name": "build"}},
	  "status": {"phase": "Failed", "progress": "3/4", "startedAt": "2026-01-01T00:00:00Z", "finishedAt": "2026-01-01T01:02:03Z", "message": "boom"}}`)
	for k, want := range map[string]any{"Status": "Failed", "Progress": "3/4", "Duration": "1h02m", "From": "wft/build", "Message": "boom"} {
		if wf[k] != want {
			t.Errorf("workflow %s = %v, want %v", k, wf[k], want)
		}
	}
	susp := row("workflows.argoproj.io", `{"metadata": {"name": "w", "labels": {"workflows.argoproj.io/cron-workflow": "nightly"}}, "spec": {},
	  "status": {"phase": "Running", "startedAt": "2026-01-01T00:00:00Z", "finishedAt": "2026-01-01T00:00:45Z",
	    "nodes": {"a": {"type": "Suspend", "phase": "Running"}}}}`)
	if susp["Status"] != "Suspended" || susp["From"] != "cron/nightly" || susp["Duration"] != "45s" {
		t.Errorf("suspended workflow = %v", susp)
	}
	if p := row("workflows.argoproj.io", `{"metadata": {"name": "w"}}`); p["Status"] != "Pending" || p["Duration"] != "" {
		t.Errorf("new workflow = %v", p)
	}

	cron := row("cronworkflows.argoproj.io", `{"metadata": {"name": "c"}, "spec": {"schedules": ["*/5 * * * *", "0 2 * * *"], "timezone": "Europe/London", "suspend": true},
	  "status": {"active": [{"name": "c-1"}], "succeeded": 4, "failed": 1}}`)
	if cron["Schedule"] != "*/5 * * * *, 0 2 * * * (Europe/London)" || cron["Suspended"] != true || cron["Active"] != 1 || cron["Policy"] != "Allow" {
		t.Errorf("cron = %v", cron)
	}
	legacy := row("cronworkflows.argoproj.io", `{"metadata": {"name": "c"}, "spec": {"schedule": "@hourly"}}`)
	if legacy["Schedule"] != "@hourly" || legacy["Suspended"] != false {
		t.Errorf("legacy cron = %v", legacy)
	}

	tmpl := row("workflowtemplates.argoproj.io", `{"metadata": {"name": "t"}, "spec": {"entrypoint": "main", "templates": [{}, {}],
	  "arguments": {"parameters": [{"name": "a"}, {"name": "b"}]}}}`)
	if tmpl["Entrypoint"] != "main" || tmpl["Templates"] != 2 || tmpl["Parameters"] != "a, b" {
		t.Errorf("template = %v", tmpl)
	}
}
