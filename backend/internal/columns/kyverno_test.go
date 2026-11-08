package columns

import (
	"encoding/json"
	"fmt"
	"testing"
)

// Kyverno policy and report columns: action per rule, background default,
// report summary and scope.
func TestKyvernoColumns(t *testing.T) {
	cells := func(key, obj string) map[string]any {
		t.Helper()
		var m map[string]any
		if err := json.Unmarshal([]byte(obj), &m); err != nil {
			t.Fatal(err)
		}
		e := NewEvaluator(builtin[key])
		row, errs := e.Row(m)
		out := map[string]any{}
		for i, c := range e.Columns() {
			if errs[i] != nil {
				t.Fatalf("%s %s: %v", key, c.Name, errs[i])
			}
			out[c.Name] = row[i]
		}
		return out
	}
	p := cells("clusterpolicies.kyverno.io", `{"spec": {"background": false, "rules": [{"validate": {"failureAction": "Enforce"}}, {"mutate": {}}]},
	  "status": {"conditions": [{"type": "Ready", "status": "True"}]}}`)
	for k, want := range map[string]any{"Action": "Enforce", "Background": false, "Ready": "True", "Rules": 2} {
		if p[k] != want {
			t.Errorf("policy %s = %v (%T), want %v", k, p[k], p[k], want)
		}
	}
	r := cells("policyreports.wgpolicyk8s.io", `{"scope": {"kind": "Deployment", "name": "web"}, "summary": {"pass": 3, "fail": 1}}`)
	if fmt.Sprint(r["Fail"], r["Warn"]) != "1 0" || r["Scope"] != "Deployment/web" {
		t.Errorf("report = %v", r)
	}
}
