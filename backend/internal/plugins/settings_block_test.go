package plugins

import (
	"reflect"
	"strings"
	"testing"
)

// A settings block flattens a nested object into sorted path → value
// rows, turns reference shapes into links (in the object's namespace
// unless the reference names one; none without a namespace), shortens
// long values, and caps the rows while counting them all.
func TestFlattenSettings(t *testing.T) {
	provider := map[string]any{
		"server": "https://vault.example:8200",
		"auth": map[string]any{
			"tokenSecretRef":    map[string]any{"name": "vault-token", "key": "token"},
			"kubernetes":        map[string]any{"role": "demo", "serviceAccountRef": map[string]any{"name": "demo-sa", "namespace": "other"}},
			"secretRef":         map[string]any{"accessKeyIDSecretRef": map[string]any{"name": "creds"}},
			"caProvider":        map[string]any{"type": "ConfigMap", "configMapRef": map[string]any{"name": "ca"}},
			"notARef":           map[string]any{"name": "plain"},
			"emptySecretRef":    map[string]any{"name": ""},
			"unrelatedSettings": nil,
		},
		"namespaces": []any{"a", "b"},
		"rules":      []any{map[string]any{"x": 1}, map[string]any{"x": 2}},
		"caBundle":   strings.Repeat("x", 81),
		"version":    int64(2),
	}
	rows, total := flattenSettings(provider, "demo", 50)
	link := func(kind, ns, name string) map[string]any {
		return map[string]any{"group": "", "kind": kind, "namespace": ns, "name": name}
	}
	want := []map[string]any{
		{"label": "auth.caProvider.configMapRef", "value": "ConfigMap/ca", "link": link("ConfigMap", "demo", "ca")},
		{"label": "auth.caProvider.type", "value": "ConfigMap"},
		{"label": "auth.kubernetes.role", "value": "demo"},
		{"label": "auth.kubernetes.serviceAccountRef", "value": "ServiceAccount/demo-sa", "link": link("ServiceAccount", "other", "demo-sa")},
		{"label": "auth.notARef.name", "value": "plain"},
		{"label": "auth.secretRef.accessKeyIDSecretRef", "value": "Secret/creds", "link": link("Secret", "demo", "creds")},
		{"label": "auth.tokenSecretRef", "value": "Secret/vault-token · token", "link": link("Secret", "demo", "vault-token")},
		{"label": "caBundle", "value": "(81 characters)"},
		{"label": "namespaces", "value": "a, b"},
		{"label": "rules", "value": "2 entries"},
		{"label": "server", "value": "https://vault.example:8200"},
		{"label": "version", "value": "2"},
	}
	if total != len(want) || !reflect.DeepEqual(rows, want) {
		t.Fatalf("rows (%d of %d):\n%v\nwant (%d):\n%v", len(rows), total, rows, len(want), want)
	}

	// The cap keeps the first rows and still counts them all; without a
	// namespace (a cluster-scoped object) a reference isn't a link.
	rows, total = flattenSettings(provider, "", 3)
	if len(rows) != 3 || total != len(want) {
		t.Fatalf("capped: %d rows of %d", len(rows), total)
	}
	if _, ok := rows[0]["link"]; ok || rows[0]["value"] != "ConfigMap/ca" {
		t.Errorf("a reference without a namespace = %v, want no link", rows[0])
	}
}
