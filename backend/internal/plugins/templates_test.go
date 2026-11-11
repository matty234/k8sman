package plugins

import (
	"strings"
	"testing"
)

func TestTemplates(t *testing.T) {
	manifest := func(yaml string) string {
		return `apiVersion: k8sman.dev/v1
id: t
name: T
version: 1.0.0
permissions: {read: [cert-manager.io/ClusterIssuer]}
kinds:
  cert-manager.io/ClusterIssuer:
    templates:
      - name: Self-signed
        yaml: |
` + yaml
	}
	indent := func(s string) string { return "          " + strings.ReplaceAll(s, "\n", "\n          ") + "\n" }
	errs := func(src string) []Diag {
		_, diags := parseManifest([]byte(src))
		var out []Diag
		for _, d := range diags {
			if !d.Warning {
				out = append(out, d)
			}
		}
		return out
	}

	t.Run("valid", func(t *testing.T) {
		src := manifest(indent("apiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata:\n  name: ${name:selfsigned}\nspec:\n  selfSigned: {}\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: ${secret}\n  namespace: ${namespace}"))
		if d := errs(src); len(d) > 0 {
			t.Fatalf("want no errors, got %v", d)
		}
		m, _ := parseManifest([]byte(src))
		if got := m.Kinds["cert-manager.io/ClusterIssuer"].Templates; len(got) != 1 || !strings.Contains(got[0].YAML, "kind: Secret") {
			t.Fatalf("templates = %+v", got)
		}
	})

	t.Run("kind mismatch", func(t *testing.T) {
		d := errs(manifest(indent("apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata:\n  name: x")))
		// At the template's kind value, in plugin.yaml.
		if len(d) != 1 || !strings.Contains(d[0].Message, "creates cert-manager.io/Issuer") || d[0].Line != 12 || d[0].Col != 17 {
			t.Fatalf("want a mismatch at 12:17, got %v", d)
		}
	})

	t.Run("size cap", func(t *testing.T) {
		big := "apiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata:\n  name: x\n  annotations:\n    note: " + strings.Repeat("x", templateMaxBytes)
		d := errs(manifest(indent(big)))
		if len(d) != 1 || !strings.Contains(d[0].Message, "at most 16 KiB") {
			t.Fatalf("want a size error, got %v", d)
		}
	})
}
