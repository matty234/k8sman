package plugins

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
	"k8s.io/apimachinery/pkg/labels"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// Fixtures (docs/PLUGINS.md §9): each fixtures/*.yaml is multi-document
// YAML, the first document the subject and the rest the cluster that
// related lookups see. fixtures/test.yaml sets now, context, readOnly and
// the answers to metric queries. `plugin test` renders every fixture (the
// plugin's cells, the resolved panel, the actions offered with their argv
// or patch body, the alerts raised) and compares the result with
// fixtures/__snapshots__/<fixture>; --update writes them.

// FixtureDir and SnapshotDir are where fixtures and snapshots live.
const (
	FixtureDir  = "fixtures"
	SnapshotDir = "__snapshots__"
	// FixtureConfigFile is the fixtures' settings, not a fixture.
	FixtureConfigFile = "test.yaml"
)

// defaultFixtureNow is `now` when test.yaml doesn't set it, so snapshots
// never depend on when they run.
var defaultFixtureNow = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// FixtureConfig is fixtures/test.yaml.
type FixtureConfig struct {
	Now      time.Time `yaml:"now"`
	Context  string    `yaml:"context"`
	ReadOnly bool      `yaml:"readOnly"`
	// Metrics answers metric queries, by query string. Without it there is
	// no Prometheus (metrics are empty, with a note).
	Metrics map[string][]Sample `yaml:"metrics"`
}

// FixtureResult is one fixture's outcome.
type FixtureResult struct {
	Fixture string
	// Status is pass, fail, updated or missing (no snapshot yet).
	Status string
	// Diff is the snapshot's difference (fail), as -expected/+actual lines.
	Diff string
	Err  error
}

// RunFixtures renders every fixture of the plugin in dir and compares it
// with its snapshot, or (update) writes the snapshots.
func RunFixtures(dir string, update bool) ([]FixtureResult, error) {
	p, cfg, err := loadForFixtures(dir)
	if err != nil {
		return nil, err
	}
	fdir := filepath.Join(dir, FixtureDir)
	entries, err := os.ReadDir(fdir)
	if err != nil {
		return nil, fmt.Errorf("no fixtures: %w", err)
	}
	var out []FixtureResult
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || name == FixtureConfigFile || !(strings.HasSuffix(name, ".yaml") || strings.HasSuffix(name, ".yml")) {
			continue
		}
		res := FixtureResult{Fixture: name}
		got, err := renderFixture(p, cfg, filepath.Join(fdir, name))
		if err != nil {
			res.Status, res.Err = "fail", err
			out = append(out, res)
			continue
		}
		snap := filepath.Join(fdir, SnapshotDir, name)
		want, err := os.ReadFile(snap)
		switch {
		case update:
			if err == nil && bytes.Equal(want, got) {
				res.Status = "pass"
				break
			}
			if err := os.MkdirAll(filepath.Dir(snap), 0o755); err != nil {
				return nil, err
			}
			if err := os.WriteFile(snap, got, 0o644); err != nil {
				return nil, err
			}
			res.Status = "updated"
		case errors.Is(err, os.ErrNotExist):
			res.Status = "missing"
		case err != nil:
			res.Status, res.Err = "fail", err
		case bytes.Equal(want, got):
			res.Status = "pass"
		default:
			res.Status, res.Diff = "fail", lineDiff(string(want), string(got))
		}
		out = append(out, res)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no fixtures in %s", fdir)
	}
	return out, nil
}

// RenderFixture renders one fixture file (any path) of the plugin in dir,
// as `plugin render` prints it.
func RenderFixture(dir, fixture string) ([]byte, error) {
	p, cfg, err := loadForFixtures(dir)
	if err != nil {
		return nil, err
	}
	return renderFixture(p, cfg, fixture)
}

func loadForFixtures(dir string) (*Plugin, FixtureConfig, error) {
	cfg := FixtureConfig{}
	p := loadPlugin(dir, SourceDev, true)
	if p.failed || p.m == nil {
		var msgs []string
		for _, d := range p.diags {
			if !d.Warning {
				msgs = append(msgs, d.Error())
			}
		}
		return nil, cfg, fmt.Errorf("the plugin doesn't load:\n  %s", strings.Join(msgs, "\n  "))
	}
	b, err := os.ReadFile(filepath.Join(dir, FixtureDir, FixtureConfigFile))
	if err == nil {
		dec := yaml.NewDecoder(bytes.NewReader(b))
		dec.KnownFields(true)
		if err := dec.Decode(&cfg); err != nil && !errors.Is(err, io.EOF) {
			return nil, cfg, fmt.Errorf("%s/%s: %w", FixtureDir, FixtureConfigFile, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, cfg, err
	}
	if cfg.Now.IsZero() {
		cfg.Now = defaultFixtureNow
	}
	if cfg.Context == "" {
		cfg.Context = "demo"
	}
	return p, cfg, nil
}

// readFixture reads a multi-document YAML file into objects.
func readFixture(path string) ([]map[string]any, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	dec := yaml.NewDecoder(bytes.NewReader(b))
	var objs []map[string]any
	for {
		var doc map[string]any
		err := dec.Decode(&doc)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", filepath.Base(path), err)
		}
		if doc == nil {
			continue
		}
		// Through JSON, so values have the types the API server's JSON
		// gives (int64 and float64 numbers, RFC3339 strings).
		jb, err := json.Marshal(doc)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", filepath.Base(path), err)
		}
		var obj map[string]any
		d := json.NewDecoder(bytes.NewReader(jb))
		d.UseNumber()
		if err := d.Decode(&obj); err != nil {
			return nil, err
		}
		objs = append(objs, normaliseNumbers(obj).(map[string]any))
	}
	if len(objs) == 0 {
		return nil, fmt.Errorf("%s has no objects", filepath.Base(path))
	}
	return objs, nil
}

// normaliseNumbers turns json.Numbers into int64 or float64.
func normaliseNumbers(v any) any {
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			x[k] = normaliseNumbers(e)
		}
	case []any:
		for i, e := range x {
			x[i] = normaliseNumbers(e)
		}
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return i
		}
		f, _ := x.Float64()
		return f
	}
	return v
}

// fixtureType is the resource type of obj, as well as a fixture can tell
// (the resource is the lower-case plural of the kind).
func fixtureType(obj map[string]any) cluster.ResourceType {
	apiVersion, _ := obj["apiVersion"].(string)
	kind, _ := obj["kind"].(string)
	group, version, found := strings.Cut(apiVersion, "/")
	if !found {
		group, version = "", apiVersion
	}
	ns, _ := nestedString(obj, "metadata", "namespace")
	return cluster.ResourceType{Group: group, Version: version, Kind: kind, Resource: strings.ToLower(kindName("/" + kind)), Namespaced: ns != ""}
}

// snapshot is what a fixture renders to.
type snapshot struct {
	Object  string `yaml:"object"`
	Columns []any  `yaml:"columns,omitempty"`
	Panel   any    `yaml:"panel,omitempty"`
	Actions any    `yaml:"actions,omitempty"`
	Alerts  []any  `yaml:"alerts,omitempty"`
}

func renderFixture(p *Plugin, cfg FixtureConfig, path string) ([]byte, error) {
	objs, err := readFixture(path)
	if err != nil {
		return nil, err
	}
	subject := objs[0]
	rt := fixtureType(subject)
	key := KindKey(rt)
	if p.m.Kinds[key] == nil {
		return nil, fmt.Errorf("%s: the plugin has nothing for %s", filepath.Base(path), key)
	}
	env := Env{Context: cfg.Context, Now: cfg.Now, Lookup: &fixtureLookup{objs: objs, metrics: cfg.Metrics}}
	ns, _ := nestedString(subject, "metadata", "namespace")
	name, _ := nestedString(subject, "metadata", "name")
	snap := snapshot{Object: key + " " + strings.TrimPrefix(ns+"/"+name, "/")}

	// Columns: the plugin's own cells.
	vars := ShellVars{"NAME": name, "NAMESPACE": ns, "CONTEXT": cfg.Context, "CLUSTER": "", "USER": "", "KUBECONFIG": "",
		"GROUP": rt.Group, "VERSION": rt.Version, "RESOURCE": rt.Resource, "KIND": rt.Kind}
	if kp := p.kind(key); kp != nil {
		for _, cp := range kp.columns {
			c := &ColumnProgram{plugin: p, kp: kp, prog: cp.prog, context: cfg.Context}
			v, err := c.evalAt(subject, cfg.Now)
			cell := map[string]any{"name": cp.col.Name}
			if err != nil {
				cell["error"] = err.Error()
			} else {
				cell["value"] = v
				if v != nil {
					vars[ColumnVar(cp.col.Name)] = cellString(v)
				}
			}
			snap.Columns = append(snap.Columns, cell)
		}
	}

	if po, ok := p.panel(env, rt, subject); ok {
		v := plain(po)
		if m, ok := v.(map[string]any); ok {
			delete(m, "plugin")
			delete(m, "name")
		}
		snap.Panel = v
	}

	if cfg.ReadOnly {
		snap.Actions = "hidden (read-only context)"
	} else {
		var acts []any
		for _, kp := range p.entriesFor(rt) {
			offeredActs, r, errs := offered(p, kp, subject, env)
			for _, err := range errs {
				acts = append(acts, map[string]any{"error": err.Error()})
			}
			for _, ap := range offeredActs {
				a := plain(actionOut(p, ap, r, func() ShellVars { return vars }, true)).(map[string]any)
				for _, k := range []string{"plugin", "consented"} {
					delete(a, k)
				}
				if ap.a.Patch != nil {
					if body, err := patchBody(ap, r, nil); err != nil {
						a["error"] = err.Error()
					} else {
						var b any
						_ = json.Unmarshal(body.Body, &b)
						a["body"] = b
					}
				}
				acts = append(acts, a)
			}
		}
		if acts != nil {
			snap.Actions = acts
		}
	}

	if kp := p.kind(key); kp != nil && len(kp.alerts) > 0 {
		hits, errs := kp.evalAlerts(context.Background(), p.ID(), []map[string]any{subject}, env)
		for _, h := range hits {
			a := map[string]any{"id": h.ID, "severity": h.Severity, "section": h.Section, "message": h.Message}
			if !h.Since.IsZero() {
				a["since"] = h.Since.UTC().Format(time.RFC3339)
			}
			snap.Alerts = append(snap.Alerts, a)
		}
		for _, err := range errs {
			snap.Alerts = append(snap.Alerts, map[string]any{"error": err.Error()})
		}
	}

	var buf bytes.Buffer
	buf.WriteString("# Written by `k8sman-server plugin test --update`: review changes before committing.\n")
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(snap); err != nil {
		return nil, err
	}
	_ = enc.Close()
	return buf.Bytes(), nil
}

// plain is v through JSON: maps, lists and scalars, as the UI sees them.
func plain(v any) any {
	b, err := json.Marshal(v)
	if err != nil {
		return err.Error()
	}
	var out any
	_ = json.Unmarshal(b, &out)
	return out
}

// cellString is a cell as $COL-<NAME> sees it.
func cellString(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case []any:
		parts := make([]string, len(x))
		for i, p := range x {
			parts[i] = fmt.Sprint(p)
		}
		return strings.Join(parts, ",")
	}
	return fmt.Sprint(v)
}

// fixtureLookup serves related objects and metrics from a fixture.
type fixtureLookup struct {
	objs    []map[string]any
	metrics map[string][]Sample
}

func (f *fixtureLookup) List(_ context.Context, kindKey, ns, labelSelector, name string) ([]map[string]any, error) {
	group, kind, _ := strings.Cut(kindKey, "/")
	sel := labels.Everything()
	if labelSelector != "" {
		s, err := labels.Parse(labelSelector)
		if err != nil {
			return nil, err
		}
		sel = s
	}
	var out []map[string]any
	for _, o := range f.objs {
		rt := fixtureType(o)
		if rt.Group != group || rt.Kind != kind {
			continue
		}
		ons, _ := nestedString(o, "metadata", "namespace")
		oname, _ := nestedString(o, "metadata", "name")
		if (ns != "" && ons != "" && ons != ns) || (name != "" && oname != name) {
			continue
		}
		set := labels.Set{}
		if md, ok := o["metadata"].(map[string]any); ok {
			if ls, ok := md["labels"].(map[string]any); ok {
				for k, v := range ls {
					set[k] = fmt.Sprint(v)
				}
			}
		}
		if sel.Matches(set) {
			out = append(out, o)
		}
	}
	return out, nil
}

func (f *fixtureLookup) Query(_ context.Context, _, query string) ([]Sample, error) {
	if f.metrics == nil {
		return nil, ErrNoPrometheus
	}
	return f.metrics[query], nil
}

// lineDiff is a small LCS line diff of a and b: "-" lines only in a, "+"
// lines only in b, with up to two lines of context.
func lineDiff(a, b string) string {
	x, y := strings.Split(a, "\n"), strings.Split(b, "\n")
	n, m := len(x), len(y)
	lcs := make([][]int, n+1)
	for i := range lcs {
		lcs[i] = make([]int, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if x[i] == y[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else {
				lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
			}
		}
	}
	type line struct {
		op   byte
		text string
	}
	var lines []line
	i, j := 0, 0
	for i < n || j < m {
		switch {
		case i < n && j < m && x[i] == y[j]:
			lines = append(lines, line{' ', x[i]})
			i++
			j++
		case i < n && (j == m || lcs[i+1][j] >= lcs[i][j+1]):
			lines = append(lines, line{'-', x[i]})
			i++
		default:
			lines = append(lines, line{'+', y[j]})
			j++
		}
	}
	var sb strings.Builder
	for k, l := range lines {
		near := slices.ContainsFunc(lines[max(0, k-2):min(len(lines), k+3)], func(o line) bool { return o.op != ' ' })
		if l.op != ' ' || near {
			sb.WriteByte(l.op)
			sb.WriteString(l.text)
			sb.WriteByte('\n')
		}
	}
	return sb.String()
}
