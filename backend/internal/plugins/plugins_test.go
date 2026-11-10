package plugins

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
)

const demoManifest = `apiVersion: k8sman.dev/v1
id: demo
name: Demo
version: 1.0.0
permissions:
  read: [example.com/Widget]
  commands: [widgetctl]
kinds:
  example.com/Widget:
    variables:
      expires: object.?status.?notAfter
    hideColumns: [Status]
    columns:
      - name: Ready
        type: status
        value: 'conditionTrue(object, "Ready") ? "Ready" : condition(object, "Ready").?reason.orValue("Pending")'
      - name: Size
        type: quantity
        value: quantity(object.spec.size).asApproximateFloat()
      - name: Expires
        type: until
        value: variables.expires
    panel:
      sections:
        - title: Widget
          blocks:
            - type: fields
              items:
                - label: Owner
                  value: object.spec.?owner
                - label: Link
                  value: object.spec.target
                  link: ref("", "Service", object.spec.target)
            - type: message
              severity: warning
              when: variables.expires.hasValue() && until(variables.expires.value()) < duration("336h")
              text: '"Expires in " + humanDuration(until(variables.expires.value()))'
    actions:
      - id: poke
        label: Poke
        shell:
          command: widgetctl
          args: [poke, --context, $CONTEXT, -n, $NAMESPACE, $NAME, "$COL-READY"]
`

func widget(ready bool, notAfter string) map[string]any {
	status := "False"
	if ready {
		status = "True"
	}
	return map[string]any{
		"apiVersion": "example.com/v1", "kind": "Widget",
		"metadata": map[string]any{"name": "w1", "namespace": "default"},
		"spec":     map[string]any{"size": "1500m", "target": "web"},
		"status": map[string]any{"notAfter": notAfter, "conditions": []any{
			map[string]any{"type": "Ready", "status": status, "reason": "Waiting"},
		}},
	}
}

func demoHost(t *testing.T, manifest string) *Host {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ManifestFile), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	h := NewHost(Options{FlagDirs: []string{dir}})
	h.Reload()
	t.Cleanup(h.Close)
	return h
}

var widgetType = cluster.ResourceType{Group: "example.com", Version: "v1", Resource: "widgets", Kind: "Widget", Namespaced: true}

func TestManifestErrorsCarryPositions(t *testing.T) {
	src := `apiVersion: k8sman.dev/v1
id: Bad_ID
name: Bad
version: 1.0
permissions:
  read: [example.com/Widget]
kinds:
  example.com/Widget:
    colums: []
    columns:
      - name: A
        value: objet.spec.a
      - name: B
        value: >-
          object.spec.b +
            nope(1)
    actions:
      - id: run
        label: Run
        shell:
          command: rm
`
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ManifestFile), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	diags := Validate(dir)
	var got []string
	for _, d := range diags {
		if !d.Warning {
			got = append(got, d.Pos.String()+" "+strings.SplitN(d.Message, " (", 2)[0])
		}
	}
	want := []string{
		`plugin.yaml:2:5 id must be lower-case letters, digits and dashes`,
		`plugin.yaml:4:10 version must be semver, e.g. 1.0.0`,
		`plugin.yaml:9:5 unknown field "colums"`,
		`plugin.yaml:21:20 rm is not in permissions.commands`,
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("manifest errors:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	// With the structure fixed, CEL errors point into the YAML, block
	// scalars included.
	src = strings.NewReplacer("Bad_ID", "bad", "version: 1.0\n", "version: 1.0.0\n", "    colums: []\n", "", "command: rm", "command: widgetctl").Replace(src)
	src = strings.Replace(src, "  read: [example.com/Widget]\n", "  read: [example.com/Widget]\n  commands: [widgetctl]\n", 1)
	if err := os.WriteFile(filepath.Join(dir, ManifestFile), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	got = nil
	for _, d := range Validate(dir) {
		got = append(got, d.Pos.String()+" "+d.Message)
	}
	want = []string{
		`plugin.yaml:12:16 undeclared reference to 'objet' (in container '')`,
		`plugin.yaml:16:17 undeclared reference to 'nope' (in container '')`,
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("CEL errors:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestPluginColumnsEvaluate(t *testing.T) {
	h := demoHost(t, demoManifest)
	defaults := []columns.Column{{Name: "Name", Query: ".metadata.name"}, {Name: "Status", Query: ".status.phase"}, {Name: "Age", Query: ".metadata.creationTimestamp", Type: "age"}}
	cols := h.Columns("demo-context", widgetType, defaults)
	var names []string
	for _, c := range cols {
		names = append(names, c.Name)
	}
	if want := []string{"Name", "Ready", "Size", "Expires", "Age"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("columns = %v, want %v (Status hidden, plugin columns before Age)", names, want)
	}
	ev := columns.NewEvaluator(cols)
	cells, errs := ev.Row(widget(false, "2030-01-02T03:04:05Z"))
	for i, err := range errs {
		if err != nil {
			t.Fatalf("column %s: %v", cols[i].Name, err)
		}
	}
	if want := []any{"w1", "Waiting", 1.5, "2030-01-02T03:04:05Z"}; !reflect.DeepEqual(cells[:4], want) {
		t.Fatalf("cells = %#v, want %#v", cells[:4], want)
	}
	cells, _ = ev.Row(widget(true, ""))
	if cells[1] != "Ready" {
		t.Fatalf("Ready = %v", cells[1])
	}
	// A missing field is an error in its cell, not the row.
	obj := widget(true, "")
	delete(obj["spec"].(map[string]any), "size")
	_, errs = ev.Row(obj)
	if errs[2] == nil || !strings.HasPrefix(errs[2].Error(), "plugin.yaml:") || errs[1] != nil {
		t.Fatalf("errs = %v", errs)
	}

	// The panel resolves to plain blocks; the message shows only near expiry.
	p := h.Panels("demo-context", widgetType, widget(true, "2030-01-02T03:04:05Z"))
	if len(p) != 1 || len(p[0].Sections) != 1 || len(p[0].Sections[0].Blocks) != 1 {
		t.Fatalf("panel = %+v", p)
	}
	items := p[0].Sections[0].Blocks[0]["items"].([]map[string]any)
	if len(items) != 1 || items[0]["label"] != "Link" || items[0]["link"].(map[string]any)["namespace"] != "default" {
		t.Fatalf("fields = %+v (empty Owner hidden; ref takes the object's namespace)", items)
	}
}

func TestShellActionExpandsVariables(t *testing.T) {
	h := demoHost(t, demoManifest)
	vars := ShellVars{"NAME": "w1", "NAMESPACE": "default", "CONTEXT": "demo-context", ColumnVar("Ready"): "Ready", ColumnVar("Not After"): "soon"}
	acts := h.Actions("demo-context", widgetType, widget(true, ""), vars)
	if len(acts) != 1 {
		t.Fatalf("actions = %+v", acts)
	}
	want := []string{"widgetctl", "poke", "--context", "demo-context", "-n", "default", "w1", "Ready"}
	if !reflect.DeepEqual(acts[0].Argv, want) || acts[0].Consented || !acts[0].Dangerous {
		t.Fatalf("action = %+v, want argv %v, not consented, dangerous", acts[0], want)
	}
	for in, out := range map[string]string{
		"$NAME-x":             "w1-x",
		"${NAMESPACE}/$NAME":  "default/w1",
		"$COL-NOT_AFTER-y":    "soon-y",
		`"$K8SMAN_NAME" $$`:   `"$K8SMAN_NAME" $`,
		"$UNKNOWN and $":      "$UNKNOWN and $",
		"pre$CONTEXT.post":    "predemo-context.post",
		"${COL-READY}${NAME}": "Readyw1",
	} {
		if got := vars.Expand(in); got != out {
			t.Errorf("Expand(%q) = %q, want %q", in, got, out)
		}
	}
	if _, err := h.ShellAction("demo-context", widgetType, widget(true, ""), "demo", "poke"); err != ErrNoConsent {
		t.Fatalf("ShellAction without consent: %v", err)
	}
}
