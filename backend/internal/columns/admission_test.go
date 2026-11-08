package columns

import (
	"encoding/json"
	"testing"
)

// The admission columns evaluate on policies, bindings and webhook configs.
func TestAdmissionColumns(t *testing.T) {
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
	vap := cells("validatingadmissionpolicies.admissionregistration.k8s.io", `{"spec": {"validations": [{}, {}], "paramKind": {"kind": "Limits"},
	  "matchConstraints": {"resourceRules": [{"resources": ["deployments", "pods"]}]}}}`)
	if vap["Failure Policy"] != "Fail" || vap["Validations"] != 2 || vap["Matches"] != "deployments,pods" || vap["Param Kind"] != "Limits" {
		t.Errorf("vap = %v", vap)
	}
	b := cells("validatingadmissionpolicybindings.admissionregistration.k8s.io", `{"spec": {"policyName": "p", "validationActions": ["Deny", "Audit"],
	  "paramRef": {"selector": {}}, "matchResources": {"namespaceSelector": {"matchLabels": {"env": "prod"}}}}}`)
	if b["Policy"] != "p" || b["Actions"] != "Deny,Audit" || b["Param"] != "(selector)" || b["Namespaces"] != "env=prod" {
		t.Errorf("binding = %v", b)
	}
	w := cells("validatingwebhookconfigurations.admissionregistration.k8s.io", `{"webhooks": [{"clientConfig": {"service": {"namespace": "ns", "name": "svc"}}}, {}]}`)
	if w["Webhooks"] != 2 || w["First Target"] != "ns/svc" {
		t.Errorf("webhook = %v", w)
	}
	m := cells("mutatingadmissionpolicies.admissionregistration.k8s.io", `{"spec": {}}`)
	if m["Mutations"] != 0 || m["Reinvocation"] != "Never" {
		t.Errorf("map = %v", m)
	}
}
