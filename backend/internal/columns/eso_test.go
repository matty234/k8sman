package columns

import (
	"encoding/json"
	"testing"
)

// The ESO columns read the Ready condition reason and the store provider.
func TestExternalSecretsColumns(t *testing.T) {
	cells := func(key, obj string) map[string]any {
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
	es := cells("externalsecrets.external-secrets.io", `{"metadata": {"name": "db"}, "spec": {"secretStoreRef": {"kind": "ClusterSecretStore", "name": "vault"}, "refreshInterval": "15m"},
	  "status": {"conditions": [{"type": "Ready", "status": "False", "reason": "SecretSyncedError"}]}}`)
	for k, want := range map[string]any{"Store": "ClusterSecretStore/vault", "Refresh": "15m", "Status": "SecretSyncedError", "Target": "db"} {
		if es[k] != want {
			t.Errorf("ExternalSecret %s = %v, want %v", k, es[k], want)
		}
	}
	st := cells("secretstores.external-secrets.io", `{"spec": {"provider": {"aws": {"region": "eu-west-1"}}}, "status": {"capabilities": "ReadWrite", "conditions": [{"type": "Ready", "status": "True", "reason": "Valid"}]}}`)
	if st["Provider"] != "aws" || st["Status"] != "Valid" || st["Capabilities"] != "ReadWrite" {
		t.Errorf("SecretStore = %v", st)
	}
}
