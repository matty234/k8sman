package plugins

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// dataManifest has related objects of every sort, a patch action with
// inputs and alerts.
const dataManifest = `apiVersion: k8sman.dev/v1
id: data
name: Data
version: 1.0.0
permissions:
  read: [example.com/Widget, /Secret, /Pod, example.com/Part]
  patch: [example.com/Widget]
kinds:
  example.com/Widget:
    related:
      secret: {kind: /Secret, name: object.spec.secretName}
      parts: {kind: example.com/Part, owner: true}
      pods:
        kind: /Pod
        selector: '{"app": object.metadata.name}'
      never:
        kind: /Pod
        when: "false"
        name: '"x"'
    panel:
      sections:
        - title: Data
          blocks:
            - type: fields
              items:
                - label: Secret keys
                  value: related.?secret.?data.orValue({}).map(k, k + "=" + related.secret.data[k]).sort().join(",")
                - label: Parts
                  value: related.parts.map(p, p.metadata.name).join(",")
                - label: Pods
                  value: related.pods.map(p, p.metadata.name).join(",")
                - label: Never
                  value: string(has(related.never))
    actions:
      - id: resize
        label: Resize
        when: has(related.secret)
        inputs:
          - {name: size, label: Size, type: int, default: object.spec.size, validate: input.size > 0 && input.size <= 10, validateMessage: From 1 to 10.}
          - {name: mode, type: enum, options: [fast, safe]}
        patch:
          type: merge
          body: '{"spec": {"size": input.size, "mode": input.mode}}'
    alerts:
      - id: too-big
        label: Widgets too big
        severity: critical
        when: object.spec.size > 5
        message: '"size " + string(object.spec.size)'
        since: object.metadata.creationTimestamp
`

func widgetObj(name string, size int64) map[string]any {
	return map[string]any{
		"apiVersion": "example.com/v1", "kind": "Widget",
		"metadata": map[string]any{"name": name, "namespace": "default", "uid": "uid-" + name, "creationTimestamp": "2025-12-01T00:00:00Z"},
		"spec":     map[string]any{"size": size, "secretName": name + "-creds"},
	}
}

// countingLookup records which kinds were looked up.
type countingLookup struct {
	fixtureLookup
	kinds []string
}

func (c *countingLookup) List(ctx context.Context, kindKey, ns, sel, name string) ([]map[string]any, error) {
	c.kinds = append(c.kinds, kindKey)
	return c.fixtureLookup.List(ctx, kindKey, ns, sel, name)
}

func TestRelatedObjects(t *testing.T) {
	h := demoHost(t, dataManifest)
	cluster := []map[string]any{
		{"apiVersion": "v1", "kind": "Secret", "metadata": map[string]any{"name": "w1-creds", "namespace": "default"},
			"data": map[string]any{"password": "c2VjcmV0"}},
		{"apiVersion": "v1", "kind": "Secret", "metadata": map[string]any{"name": "w1-creds", "namespace": "other"}},
		{"apiVersion": "example.com/v1", "kind": "Part", "metadata": map[string]any{"name": "p2", "namespace": "default",
			"ownerReferences": []any{map[string]any{"uid": "uid-w1"}}}},
		{"apiVersion": "example.com/v1", "kind": "Part", "metadata": map[string]any{"name": "p1", "namespace": "default",
			"ownerReferences": []any{map[string]any{"uid": "uid-w1"}}}},
		{"apiVersion": "example.com/v1", "kind": "Part", "metadata": map[string]any{"name": "p3", "namespace": "default",
			"ownerReferences": []any{map[string]any{"uid": "uid-other"}}}},
		{"apiVersion": "v1", "kind": "Pod", "metadata": map[string]any{"name": "w1-a", "namespace": "default", "labels": map[string]any{"app": "w1"}}},
		{"apiVersion": "v1", "kind": "Pod", "metadata": map[string]any{"name": "web", "namespace": "default", "labels": map[string]any{"app": "web"}}},
	}
	lk := &countingLookup{fixtureLookup: fixtureLookup{objs: cluster}}
	env := Env{Context: "demo", Lookup: lk}
	panels := h.Panels(env, widgetType, widgetObj("w1", 3))
	if len(panels) != 1 || len(panels[0].Errors) > 0 || len(panels[0].Notes) > 0 {
		t.Fatalf("panels = %+v", panels)
	}
	got := map[string]any{}
	for _, it := range panels[0].Sections[0].Blocks[0]["items"].([]map[string]any) {
		got[it["label"].(string)] = it["value"]
	}
	// By name in the object's namespace, with the Secret's values blanked;
	// owned parts in name order; pods by label; a skipped lookup absent.
	want := map[string]any{"Secret keys": "password=", "Parts": "p1,p2", "Pods": "w1-a", "Never": "false"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("fields = %v, want %v", got, want)
	}
	if strings.Join(lk.kinds, " ") != "example.com/Part /Pod /Secret" {
		t.Fatalf("lookups = %v, want one per relation used (not the skipped one)", lk.kinds)
	}

	// Without a lookup (or a kind the cluster doesn't serve) relations are
	// empty and the panel says so; the panel still renders.
	panels = h.Panels(Env{Context: "demo"}, widgetType, widgetObj("w1", 3))
	if len(panels[0].Notes) != 1 || panels[0].Sections[0].Blocks[0]["type"] != "fields" {
		t.Fatalf("no lookup: %+v", panels[0])
	}

	// Related data stays out of columns and alerts: a compile error at the
	// expression, also through a variable.
	for _, bad := range []string{
		"    columns:\n      - name: N\n        value: size(related.parts)\n",
		"    variables:\n      n: size(related.parts)\n    columns:\n      - {name: N, value: variables.n}\n",
	} {
		src := strings.Replace(dataManifest, "    panel:\n", bad+"    panel:\n", 1)
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, ManifestFile), []byte(src), 0o644)
		diags := Validate(dir)
		if len(diags) != 1 || !strings.Contains(diags[0].Message, "related isn't available in") {
			t.Fatalf("related in a column or alert: %v", diags)
		}
	}
}

// A "*" entry adds a tab to any kind, shown where its when holds (here:
// some report owned by the object passes the host-side filter), with a
// section summary; a Secret seen through "*" has its values blanked.
func TestAnyKindTab(t *testing.T) {
	h := demoHost(t, `apiVersion: k8sman.dev/v1
id: reports
name: Reports
version: 1.0.0
permissions:
  read: [example.com/Report]
kinds:
  "*":
    related:
      reports:
        kind: example.com/Report
        owner: true
        filter: item.?status.orValue("") != "stale"
    panel:
      tabs:
        - title: Results
          into: security
          when: size(related.reports) > 0 || has(object.data)
          sections:
            - title: Results
              summary: string(size(related.reports))
              blocks:
                - type: chips
                  items: related.reports.map(r, r.metadata.name) + object.?data.orValue({}).map(k, k + "=" + object.data[k])
`)
	report := func(name, owner, status string) map[string]any {
		return map[string]any{"apiVersion": "example.com/v1", "kind": "Report", "status": status,
			"metadata": map[string]any{"name": name, "namespace": "default", "ownerReferences": []any{map[string]any{"uid": owner}}}}
	}
	env := Env{Context: "demo", Lookup: &fixtureLookup{objs: []map[string]any{
		report("r1", "uid-w1", "ok"), report("r2", "uid-w1", "stale"), report("r3", "uid-other", "ok"),
	}}}
	tabs := func(rt cluster.ResourceType, obj map[string]any) []TabOut {
		panels := h.Panels(env, rt, obj)
		if len(panels) != 1 || len(panels[0].Errors) > 0 {
			t.Fatalf("panels = %+v", panels)
		}
		return panels[0].Tabs
	}
	got := tabs(widgetType, widgetObj("w1", 1))
	if len(got) != 1 || got[0].Into != "security" || got[0].Sections[0].Summary != "1" ||
		!reflect.DeepEqual(got[0].Sections[0].Blocks[0]["items"], []any{"r1"}) {
		t.Fatalf("tabs = %+v, want r1 only (r2 filtered out, r3 not owned)", got)
	}
	if got := tabs(widgetType, widgetObj("w2", 1)); len(got) != 0 {
		t.Fatalf("no reports: tabs = %+v, want none", got)
	}
	secret := map[string]any{"metadata": map[string]any{"name": "s", "namespace": "default", "uid": "uid-s"}, "data": map[string]any{"password": "c2VjcmV0"}}
	secretType := cluster.ResourceType{Version: "v1", Resource: "secrets", Kind: "Secret", Namespaced: true}
	if got := tabs(secretType, secret); len(got) != 1 || !reflect.DeepEqual(got[0].Sections[0].Blocks[0]["items"], []any{"password="}) {
		t.Fatalf("secret through *: tabs = %+v, want its values blanked", got)
	}
}

func TestPatchActionInputs(t *testing.T) {
	h := demoHost(t, dataManifest)
	p := h.Get("data")
	kp := p.kind("example.com/Widget")
	env := Env{Context: "demo", Lookup: &fixtureLookup{objs: []map[string]any{
		{"apiVersion": "v1", "kind": "Secret", "metadata": map[string]any{"name": "w1-creds", "namespace": "default"}},
	}}}
	run := func(inputs map[string]any) (string, error) {
		acts, r, _ := offered(p, kp, widgetObj("w1", 3), env)
		if len(acts) != 1 {
			t.Fatalf("offered = %d actions, want resize (its when reads related)", len(acts))
		}
		out, err := patchBody(acts[0], r, inputs)
		if err != nil {
			return "", err
		}
		return out.Type + " " + string(out.Body), nil
	}
	// Defaults: the object's size, the enum's first option. JSON numbers
	// arrive as float64.
	if got, err := run(nil); err != nil || got != `merge {"spec":{"mode":"fast","size":3}}` {
		t.Fatalf("defaults: %q %v", got, err)
	}
	if got, err := run(map[string]any{"size": float64(7), "mode": "safe"}); err != nil || got != `merge {"spec":{"mode":"safe","size":7}}` {
		t.Fatalf("given: %q %v", got, err)
	}
	for _, tc := range []struct {
		in   map[string]any
		want string
	}{
		{map[string]any{"size": float64(11)}, "From 1 to 10."},
		{map[string]any{"size": 2.5}, "Size must be a whole number"},
		{map[string]any{"size": "two"}, "Size must be a whole number"},
		{map[string]any{"mode": "reckless"}, "mode must be one of fast, safe"},
		{map[string]any{"color": "red"}, `no input "color"`},
	} {
		_, err := run(tc.in)
		var ie *InputError
		if !errors.As(err, &ie) || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%v: err = %v, want an InputError with %q", tc.in, err, tc.want)
		}
	}
	// Without the Secret, `when` is false: not offered, and refused.
	if acts, _, _ := offered(p, kp, widgetObj("w2", 3), env); len(acts) != 0 {
		t.Fatalf("offered without the secret: %d", len(acts))
	}
	// Without consent, the host refuses to build the patch.
	if _, err := h.PatchAction(env, widgetType, widgetObj("w1", 3), "data", "resize", nil); !errors.Is(err, ErrNoConsent) {
		t.Fatalf("PatchAction without consent: %v", err)
	}

	// The loader keeps patches to declared kinds, and never Secrets.
	for patch, want := range map[string]string{
		"": "is not in permissions.patch",
		"  patch: [example.com/Widget, /Secret]\n": "plugins can't change Secrets",
	} {
		src := strings.Replace(dataManifest, "  patch: [example.com/Widget]\n", patch, 1)
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, ManifestFile), []byte(src), 0o644)
		var msgs []string
		for _, d := range Validate(dir) {
			msgs = append(msgs, d.Message)
		}
		if !strings.Contains(strings.Join(msgs, "\n"), want) {
			t.Errorf("want %q, got %v", want, msgs)
		}
	}
}

func TestAlertsEvaluate(t *testing.T) {
	h := demoHost(t, dataManifest)
	listed := 0
	hits, errs := h.Alerts(Env{Context: "demo", Now: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}, func(key, version string) ([]map[string]any, error) {
		listed++
		if key != "example.com/Widget" {
			return nil, ErrNotServed
		}
		bad := widgetObj("w3", 1)
		delete(bad["spec"].(map[string]any), "size") // its when fails: skipped, error returned
		return []map[string]any{widgetObj("w1", 3), widgetObj("w2", 9), bad}, nil
	})
	if listed != 1 || len(hits) != 1 || len(errs) != 1 {
		t.Fatalf("hits = %+v, errs = %v", hits, errs)
	}
	want := AlertHit{Plugin: "data", ID: "too-big", Category: "plugin.data.too-big", Label: "Widgets too big", Severity: "critical",
		Section: "custom", Group: "example.com", Kind: "Widget", Namespace: "default", Name: "w2", Message: "size 9",
		Since: time.Date(2025, 12, 1, 0, 0, 0, 0, time.UTC)}
	if hits[0] != want {
		t.Fatalf("hit = %+v\nwant  %+v", hits[0], want)
	}
	if !strings.HasPrefix(errs[0].Error(), "plugin data: plugin.yaml:") {
		t.Fatalf("error = %v, want it placed in plugin.yaml", errs[0])
	}
}

// TestSchemaMatchesLoader checks that schema/plugin.v1.json is what the
// loader's types generate (run `k8sman-server plugin schema >
// schema/plugin.v1.json` after changing them), and that the example
// plugin passes it while a typo doesn't.
func TestSchemaMatchesLoader(t *testing.T) {
	gen := JSONSchema()
	checked, err := os.ReadFile("../../../schema/plugin.v1.json")
	if err != nil || string(checked) != string(gen) {
		t.Fatalf("schema/plugin.v1.json is stale (or missing: %v); regenerate it with k8sman-server plugin schema", err)
	}
	var schema map[string]any
	if err := json.Unmarshal(gen, &schema); err != nil {
		t.Fatal(err)
	}
	src, err := os.ReadFile("../../../examples/plugins/cert-manager/plugin.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var doc any
	if err := yaml.Unmarshal(src, &doc); err != nil {
		t.Fatal(err)
	}
	doc = plain(doc)
	if errs := validateSchema(schema, schema, doc, ""); len(errs) > 0 {
		t.Fatalf("the example doesn't match the schema:\n%s", strings.Join(errs, "\n"))
	}
	m := doc.(map[string]any)
	cert := m["kinds"].(map[string]any)["cert-manager.io/Certificate"].(map[string]any)
	cert["colums"] = []any{}
	cert["columns"].([]any)[0].(map[string]any)["type"] = "colour"
	cert["panel"].(map[string]any)["sections"].([]any)[0].(map[string]any)["blocks"].([]any)[0].(map[string]any)["rows"] = "x"
	errs := validateSchema(schema, schema, doc, "")
	want := []string{"colums: not allowed", "columns/0/type: not one of", "blocks/0: rows: not allowed for this type"}
	for _, w := range want {
		if !strings.Contains(strings.Join(errs, "\n"), w) {
			t.Errorf("want an error with %q, got:\n%s", w, strings.Join(errs, "\n"))
		}
	}
}

// TestSchemaV1Frozen keeps k8sman.dev/v1 compatible: compared with the
// snapshot taken at the freeze (schema/plugin.v1.frozen.json), the schema
// may grow (new optional fields, enum values, definitions) but not drop or
// narrow anything a v1 plugin may use.
func TestSchemaV1Frozen(t *testing.T) {
	var frozen, now map[string]any
	b, err := os.ReadFile("../../../schema/plugin.v1.frozen.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &frozen); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(JSONSchema(), &now); err != nil {
		t.Fatal(err)
	}
	if errs := schemaBreaks(frozen, now, "#"); len(errs) > 0 {
		slices.Sort(errs)
		t.Fatalf("these schema changes would break v1 plugins:\n  %s\n\n"+
			"k8sman.dev/v1 is frozen (docs/PLUGINS.md, Compatibility): make the change additive "+
			"(a new optional field, enum value or block type) or leave it for k8sman.dev/v2. "+
			"Refresh schema/plugin.v1.frozen.json from schema/plugin.v1.json only to record additive changes, never to silence this test.",
			strings.Join(errs, "\n  "))
	}
}

// schemaBreaks lists what schema now drops or narrows from old: removed
// properties and definitions, newly required properties, removed enum
// values, new enums, changed consts and types, and additionalProperties
// closed. It walks the subschemas both have; list entries are matched by
// their `if` (the block type rules) or else by position.
func schemaBreaks(old, now map[string]any, at string) []string {
	var errs []string
	add := func(format string, args ...any) { errs = append(errs, at+": "+fmt.Sprintf(format, args...)) }
	for _, r := range asList(now["required"]) {
		if !containsValue(asList(old["required"]), r) {
			add("%v is newly required", r)
		}
	}
	for _, e := range asList(old["enum"]) {
		if !containsValue(asList(now["enum"]), e) {
			add("enum value %v removed", e)
		}
	}
	if old["enum"] == nil && now["enum"] != nil {
		add("is now an enum")
	}
	if c, ok := old["const"]; ok && !reflect.DeepEqual(c, now["const"]) {
		add("const %v changed to %v", c, now["const"])
	}
	if nt, ok := now["type"]; ok && !reflect.DeepEqual(old["type"], nt) && !containsValue(asList(nt), old["type"]) {
		add("type %v narrowed to %v", old["type"], nt)
	}
	if old["additionalProperties"] != false && now["additionalProperties"] == false {
		add("additionalProperties is now false")
	}
	for k, ov := range old {
		switch ov := ov.(type) {
		case map[string]any:
			nv, _ := now[k].(map[string]any)
			if k != "properties" && k != "$defs" {
				if nv != nil {
					errs = append(errs, schemaBreaks(ov, nv, at+"/"+k)...)
				}
				continue
			}
			for name, s := range ov {
				if ns, ok := nv[name].(map[string]any); ok {
					errs = append(errs, schemaBreaks(s.(map[string]any), ns, at+"/"+k+"/"+name)...)
				} else {
					add("%s %s removed", k, name)
				}
			}
		case []any:
			key := func(i int, x any) string {
				if m, ok := x.(map[string]any); ok && m["if"] != nil {
					b, _ := json.Marshal(m["if"])
					return string(b)
				}
				return itoa(i)
			}
			nl := map[string]map[string]any{}
			for i, x := range asList(now[k]) {
				if m, ok := x.(map[string]any); ok {
					nl[key(i, x)] = m
				}
			}
			for i, x := range ov {
				if m, ok := x.(map[string]any); ok && nl[key(i, x)] != nil {
					errs = append(errs, schemaBreaks(m, nl[key(i, x)], at+"/"+k+"/"+itoa(i))...)
				} else if ok {
					add("%s/%d removed", k, i)
				}
			}
		}
	}
	return errs
}

// validateSchema checks v against the subset of JSON Schema the generated
// schema uses.
func validateSchema(root, s map[string]any, v any, at string) []string {
	var errs []string
	fail := func(format string, args ...any) {
		errs = append(errs, at+": "+fmt.Sprintf(format, args...))
	}
	if ref, ok := s["$ref"].(string); ok {
		def := root["$defs"].(map[string]any)[strings.TrimPrefix(ref, "#/$defs/")].(map[string]any)
		return validateSchema(root, def, v, at)
	}
	for _, sub := range asList(s["allOf"]) {
		sm := sub.(map[string]any)
		if cond, ok := sm["if"].(map[string]any); ok {
			if len(validateSchema(root, cond, v, at)) == 0 {
				errs = append(errs, validateSchema(root, sm["then"].(map[string]any), v, at)...)
			}
			continue
		}
		errs = append(errs, validateSchema(root, sm, v, at)...)
	}
	if one := asList(s["oneOf"]); one != nil {
		n := 0
		for _, sub := range one {
			if len(validateSchema(root, sub.(map[string]any), v, at)) == 0 {
				n++
			}
		}
		if n != 1 {
			fail("matches %d of oneOf", n)
		}
	}
	if c, ok := s["const"]; ok && !reflect.DeepEqual(c, v) {
		fail("must be %v", c)
	}
	if e := asList(s["enum"]); e != nil && !containsValue(e, v) {
		fail("not one of %v", e)
	}
	// Object keywords apply to any map (an `if` or `then` has no type).
	if m, ok := v.(map[string]any); ok {
		for _, r := range asList(s["required"]) {
			if _, ok := m[r.(string)]; !ok {
				fail("%s is required", r)
			}
		}
		props, _ := s["properties"].(map[string]any)
		for k, val := range m {
			if pn, ok := s["propertyNames"].(map[string]any); ok {
				if e := asList(pn["enum"]); e != nil && !containsValue(e, k) {
					fail("%s: not allowed for this type", k)
				}
			}
			if ps, ok := props[k].(map[string]any); ok {
				errs = append(errs, validateSchema(root, ps, val, at+"/"+k)...)
			} else if ap, ok := s["additionalProperties"].(map[string]any); ok {
				errs = append(errs, validateSchema(root, ap, val, at+"/"+k)...)
			} else if s["additionalProperties"] == false {
				errs = append(errs, at+"/"+k+": not allowed")
			}
		}
	}
	switch s["type"] {
	case "object":
		if _, ok := v.(map[string]any); !ok {
			fail("not an object")
		}
	case "array":
		l, ok := v.([]any)
		if !ok {
			fail("not a list")
			return errs
		}
		if is, ok := s["items"].(map[string]any); ok {
			for i, x := range l {
				errs = append(errs, validateSchema(root, is, x, at+"/"+itoa(i))...)
			}
		}
	case "string":
		if _, ok := v.(string); !ok {
			fail("not a string")
		}
	case "boolean":
		if _, ok := v.(bool); !ok {
			fail("not a boolean")
		}
	case "integer":
		if f, ok := v.(float64); !ok || f != float64(int64(f)) {
			fail("not an integer")
		}
	}
	return errs
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

func containsValue(l []any, v any) bool {
	for _, x := range l {
		if reflect.DeepEqual(x, v) {
			return true
		}
	}
	return false
}

// TestPluginTestGolden runs the example's fixtures against their checked-in
// snapshots, then the flow on a new plugin: scaffold (snapshots written),
// pass, change a fixture (fail with a diff), --update, pass.
func TestPluginTestGolden(t *testing.T) {
	// The cert-manager example and every bundled plugin (each must have fixtures).
	dirs := []string{"../../../examples/plugins/cert-manager"}
	bundledDirs, _ := filepath.Glob("bundled/*/" + ManifestFile)
	if len(bundledDirs) == 0 {
		t.Fatal("no bundled plugins found")
	}
	for _, m := range bundledDirs {
		dirs = append(dirs, filepath.Dir(m))
	}
	for _, dir := range dirs {
		if diags := Validate(dir); len(diags) > 0 {
			t.Errorf("%s: %v", dir, diags)
		}
		res, err := RunFixtures(dir, false)
		if err != nil {
			t.Fatalf("%s: %v", dir, err)
		}
		for _, r := range res {
			if r.Status != "pass" {
				t.Errorf("%s %s: %s %v\n%s", dir, r.Fixture, r.Status, r.Err, r.Diff)
			}
		}
	}

	dir, err := Scaffold(t.TempDir(), "demo-widgets")
	if err != nil {
		t.Fatal(err)
	}
	status := func(update bool) (string, string) {
		res, err := RunFixtures(dir, update)
		if err != nil || len(res) != 1 {
			t.Fatalf("run: %v %v", res, err)
		}
		return res[0].Status, res[0].Diff
	}
	if s, _ := status(false); s != "pass" {
		t.Fatalf("new plugin: %s", s)
	}
	fixture := filepath.Join(dir, FixtureDir, "widget.yaml")
	b, _ := os.ReadFile(fixture)
	os.WriteFile(fixture, []byte(strings.Replace(string(b), "size: 3", "size: 4", 1)), 0o644)
	if s, diff := status(false); s != "fail" || !strings.Contains(diff, "-    value: 3\n+    value: 4\n") {
		t.Fatalf("changed fixture: %s\n%s", s, diff)
	}
	if s, _ := status(true); s != "updated" {
		t.Fatalf("--update: %s", s)
	}
	if s, _ := status(false); s != "pass" {
		t.Fatalf("after --update: %s", s)
	}
}

// BenchmarkPluginData measures the bundled cert-manager plugin against the
// budgets of docs/PLUGINS.md §8: its alerts over 1,000 Certificates (one
// overview poll; budget +5 ms p50 for five typical plugins) and its
// Certificate panel with related objects and metrics warm (5 ms p95).
func BenchmarkPluginData(b *testing.B) {
	const dir = "bundled/cert-manager"
	p, cfg, err := loadForFixtures(dir)
	if err != nil {
		b.Fatal(err)
	}
	h := &Host{plugins: []*Plugin{p}, opts: Options{FlagDirs: []string{dir}}}
	objs, err := readFixture(dir + "/fixtures/certificate-ready.yaml")
	if err != nil {
		b.Fatal(err)
	}
	env := Env{Context: "demo", Now: cfg.Now, Lookup: &fixtureLookup{objs: objs, metrics: cfg.Metrics}}
	certs := make([]map[string]any, 1000)
	for i := range certs {
		c := plain(objs[0]).(map[string]any)
		md := c["metadata"].(map[string]any)
		md["name"], md["uid"], md["resourceVersion"] = "cert-"+itoa(i), "uid-"+itoa(i), "1"
		if i%10 == 0 {
			c["status"].(map[string]any)["notAfter"] = "2026-01-05T00:00:00Z" // expiring
		}
		certs[i] = c
	}
	kp := p.kind("cert-manager.io/Certificate")
	for _, cold := range []bool{true, false} {
		name := map[bool]string{true: "alerts-1000/cold", false: "alerts-1000/warm"}[cold]
		b.Run(name, func(b *testing.B) {
			for b.Loop() {
				if cold { // a new object version (or a new 30 s bucket) for every object
					kp.alertMemo.mu.Lock()
					kp.alertMemo.bucket = -1
					kp.alertMemo.mu.Unlock()
				}
				hits, _ := h.Alerts(env, func(key, _ string) ([]map[string]any, error) {
					if key == "cert-manager.io/Certificate" {
						return certs, nil
					}
					return nil, nil
				})
				if len(hits) != 100 {
					b.Fatalf("hits = %d", len(hits))
				}
			}
		})
	}
	rt := fixtureType(objs[0])
	b.Run("panel-related", func(b *testing.B) {
		for b.Loop() {
			if _, ok := p.panel(env, rt, objs[0]); !ok {
				b.Fatal("no panel")
			}
		}
	})

	// What every inspected object costs with the bundled kyverno plugin's
	// "*" entry: its panel (the Policy results tab) over 2,000
	// PolicyReports in the namespace, served as a warm watch cache serves
	// them (the namespace's list, shared), for an object that owns one
	// report and for one that owns none.
	kp2, _, err := loadForFixtures("bundled/kyverno")
	if err != nil {
		b.Fatal(err)
	}
	reports, err := readFixture("bundled/kyverno/fixtures/pod-results.yaml")
	if err != nil {
		b.Fatal(err)
	}
	pod, owned := reports[0], reports[1]
	list := make([]map[string]any, 2000)
	for i := range list {
		r := plain(owned).(map[string]any)
		md := r["metadata"].(map[string]any)
		md["name"] = "uid-" + itoa(i)
		md["ownerReferences"] = []any{map[string]any{"kind": "Pod", "name": "pod-" + itoa(i), "uid": "uid-" + itoa(i)}}
		list[i] = r
	}
	list[1000] = owned
	lookup := sliceLookup{"wgpolicyk8s.io/PolicyReport": list}
	podType := fixtureType(pod)
	cm := map[string]any{"apiVersion": "v1", "kind": "ConfigMap", "metadata": map[string]any{"name": "web-config", "namespace": "demo", "uid": "uid-none"}}
	cmType := cluster.ResourceType{Version: "v1", Kind: "ConfigMap", Resource: "configmaps", Namespaced: true}
	for _, c := range []struct {
		name string
		rt   cluster.ResourceType
		obj  map[string]any
		tabs int
	}{{"any-kind-tab/owns-a-report", podType, pod, 1}, {"any-kind-tab/owns-none", cmType, cm, 0}} {
		b.Run(c.name, func(b *testing.B) {
			env := Env{Context: "demo", Now: cfg.Now, Lookup: lookup}
			for b.Loop() {
				po, ok := kp2.panel(env, c.rt, c.obj)
				if !ok || len(po.Tabs) != c.tabs {
					b.Fatalf("tabs = %+v", po.Tabs)
				}
			}
		})
	}

	// The dra plugin's Node section: a filter relation over 1,000
	// ResourceSlices (cluster-wide), two of them the node's.
	dra, _, err := loadForFixtures("bundled/dra")
	if err != nil {
		b.Fatal(err)
	}
	nodeObjs, err := readFixture("bundled/dra/fixtures/node.yaml")
	if err != nil {
		b.Fatal(err)
	}
	slices := make([]map[string]any, 1000)
	for i := range slices {
		s := plain(nodeObjs[3]).(map[string]any)
		s["metadata"].(map[string]any)["name"] = "slice-" + itoa(i)
		s["spec"].(map[string]any)["nodeName"] = "node-" + itoa(i)
		slices[i] = s
	}
	slices[10], slices[500] = nodeObjs[1], nodeObjs[2]
	b.Run("filter-1000/node-slices", func(b *testing.B) {
		env := Env{Context: "demo", Now: cfg.Now, Lookup: sliceLookup{"resource.k8s.io/ResourceSlice": slices}}
		for b.Loop() {
			po, ok := dra.panel(env, fixtureType(nodeObjs[0]), nodeObjs[0])
			if !ok || len(po.Sections) != 1 {
				b.Fatalf("panel = %+v", po)
			}
		}
	})
}

// sliceLookup serves each kind's objects from a list, unfiltered by
// namespace, as a warm watch cache answers for one namespace.
type sliceLookup map[string][]map[string]any

func (s sliceLookup) List(_ context.Context, kindKey, _, _, _ string) ([]map[string]any, error) {
	if l, ok := s[kindKey]; ok {
		return l, nil
	}
	return nil, ErrNotServed
}

func (s sliceLookup) Query(context.Context, string, string) ([]Sample, error) {
	return nil, ErrNoPrometheus
}

// A "*" entry's scope and exceptKinds decide where it applies, a tab's id
// defaults to a slug of its title, and its lookups stop at the budget.
func TestAnyKindScopeIDAndBudget(t *testing.T) {
	var rel strings.Builder
	reads := []string{}
	for i := range starMaxLookups + 1 {
		fmt.Fprintf(&rel, "      r%d: {kind: /Pod, name: '\"p\"'}\n", i)
		reads = append(reads, fmt.Sprintf("string(has(related.r%d))", i))
	}
	h := demoHost(t, `apiVersion: k8sman.dev/v1
id: star
name: Star
version: 1.0.0
permissions:
  read: [/Pod]
kinds:
  "*":
    scope: namespaced
    exceptKinds: [/Secret]
    related:
`+rel.String()+`    panel:
      tabs:
        - title: Policy Results
          sections:
            - title: S
              blocks:
                - {type: message, text: '`+strings.Join(reads, " + ")+`'}
`)
	lookup := &countingLookup{}
	env := Env{Context: "demo", Lookup: lookup}
	secretType := cluster.ResourceType{Version: "v1", Resource: "secrets", Kind: "Secret", Namespaced: true}
	nodeType := cluster.ResourceType{Version: "v1", Resource: "nodes", Kind: "Node"}
	for _, rt := range []cluster.ResourceType{secretType, nodeType} {
		if got := h.Panels(env, rt, map[string]any{"metadata": map[string]any{"name": "x"}}); len(got) != 0 {
			t.Fatalf("%s: panels = %+v, want none (excepted or out of scope)", rt.Kind, got)
		}
	}
	got := h.Panels(env, widgetType, widgetObj("w1", 1))
	if len(got) != 1 || len(got[0].Tabs) != 1 || got[0].Tabs[0].ID != "policy-results" {
		t.Fatalf("panels = %+v, want a tab with id policy-results", got)
	}
	if len(lookup.kinds) != starMaxLookups || len(got[0].Notes) != 1 || !strings.Contains(got[0].Notes[0], "over budget") {
		t.Fatalf("lookups = %d, notes = %v, want %d lookups and one over-budget note", len(lookup.kinds), got[0].Notes, starMaxLookups)
	}
}

// Severity names are canonical in what a panel renders (aliases mapped),
// validate warns about aliases and unknown names where they are written,
// and about an after that names no core section; a section's header
// badge and after reach the UI.
func TestSeverityAndPlacement(t *testing.T) {
	src := `apiVersion: k8sman.dev/v1
id: sev
name: Sev
version: 1.0.0
permissions:
  read: [/Pod]
kinds:
  /Pod:
    panel:
      sections:
        - title: Claims
          after: volumes
          badge: {text: '"Pending"', severity: '"warn"'}
          blocks:
            - type: table
              rows: object.spec.containers
              columns:
                - name: Name
                  value: item.name
                  severity: 'item.name == "web" ? "ok" : "bad"'
        - title: Late
          after: nope
          blocks:
            - type: fields
              items:
                - {label: Node, value: object.spec.nodeName, severity: '"critical"'}
`
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ManifestFile), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, d := range Validate(dir) {
		if !d.Warning {
			t.Fatalf("error: %s %s", d.Pos, d.Message)
		}
		got = append(got, d.Pos.String()+" "+strings.SplitN(d.Message, " (", 2)[0])
	}
	want := []string{
		`plugin.yaml:13:49 severity "warn" is an old name: write "warning"`,
		`plugin.yaml:20:58 "bad" is not a severity`,
		`plugin.yaml:22:18 after: "nope" is not a section of the /Pod panel`,
		`plugin.yaml:26:73 severity "critical" is an old name: write "error"`,
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("warnings:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	h := demoHost(t, src)
	podType := cluster.ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true}
	pod := map[string]any{"apiVersion": "v1", "kind": "Pod", "metadata": map[string]any{"name": "p", "namespace": "default"},
		"spec": map[string]any{"nodeName": "n1", "containers": []any{map[string]any{"name": "web"}, map[string]any{"name": "side"}}}}
	panels := h.Panels(Env{}, podType, pod)
	if len(panels) != 1 || len(panels[0].Sections) != 2 {
		t.Fatalf("panels = %+v", panels)
	}
	claims, late := panels[0].Sections[0], panels[0].Sections[1]
	rows := claims.Blocks[0]["rows"].([][]map[string]any)
	if claims.After != "volumes" || !reflect.DeepEqual(claims.Badge, map[string]any{"text": "Pending", "severity": "warning"}) ||
		rows[0][0]["severity"] != "ok" || rows[1][0]["severity"] != nil {
		t.Fatalf("claims = %+v", claims)
	}
	if items := late.Blocks[0]["items"].([]map[string]any); items[0]["severity"] != "error" {
		t.Fatalf("late = %+v", late)
	}
}
