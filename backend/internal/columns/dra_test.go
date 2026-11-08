package columns

import (
	"encoding/json"
	"testing"
)

// The DRA columns read v1 and v1beta1 claims alike.
func TestDRAColumns(t *testing.T) {
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
	v1 := cells("resourceclaims.resource.k8s.io", `{"spec": {"devices": {"requests": [{"name": "g", "exactly": {"deviceClassName": "gpu.example.com"}}]}},
	  "status": {"reservedFor": [{"resource": "pods", "name": "p"}], "allocation": {"devices": {"results": [{"device": "gpu-0"}, {"device": "gpu-1"}]},
	    "nodeSelector": {"nodeSelectorTerms": [{"matchFields": [{"key": "metadata.name", "operator": "In", "values": ["node-a"]}]}]}}}}`)
	for k, want := range map[string]any{"State": "Reserved: 1", "Device Classes": "gpu.example.com", "Node": "node-a", "Devices": 2} {
		if v1[k] != want {
			t.Errorf("v1 %s = %v (%T), want %v", k, v1[k], v1[k], want)
		}
	}
	beta := cells("resourceclaims.resource.k8s.io", `{"spec": {"devices": {"requests": [{"name": "g", "deviceClassName": "old.example.com"}]}}}`)
	if beta["State"] != "Pending" || beta["Device Classes"] != "old.example.com" {
		t.Errorf("v1beta1 claim = %v", beta)
	}
}
