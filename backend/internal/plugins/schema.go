package plugins

import (
	"encoding/json"
	"reflect"
	"slices"
	"strings"
)

// The JSON Schema of plugin.yaml (v1) is generated from the manifest types
// above and the loader's own lists (column and value types, block fields,
// icons, …), so the two can't disagree: schema/plugin.v1.json is this
// output (`k8sman-server plugin schema`), and a test fails when it is stale.
// The schema gives editors completion and hover docs; it can't check CEL,
// permissions or references, which `plugin validate` does.

// SchemaURL is where the schema is published; plugin.yaml files name it
// in their yaml-language-server comment.
const SchemaURL = "https://raw.githubusercontent.com/matty234/k8sman/main/schema/plugin.v1.json"

// SchemaComment is the first line of a plugin.yaml, for editors.
const SchemaComment = "# yaml-language-server: $schema=" + SchemaURL

// schemaRequired are the fields each type must have.
var schemaRequired = map[string][]string{
	"Manifest":    {"apiVersion", "id", "name", "version", "kinds"},
	"Nav":         {"title"},
	"Related":     {"kind"},
	"Metric":      {"query"},
	"Alert":       {"id", "label", "when"},
	"Column":      {"name", "value"},
	"Section":     {"title"},
	"Tab":         {"title", "sections"},
	"Block":       {"type"},
	"FieldItem":   {"label", "value"},
	"BadgeItem":   {"text"},
	"TableColumn": {"name", "value"},
	"Action":      {"id", "label"},
	"Shell":       {"command"},
	"Patch":       {"type", "body"},
	"Input":       {"name"},
	"Status":      {"label"},
	"StatusCount": {"label", "when"},
}

var kindKeyPattern = `^(\*|[a-z0-9.-]*/[A-Z][A-Za-z0-9]*)$`

// schemaField is extra schema for one field ("Type.field").
func schemaField() map[string]map[string]any {
	enum := func(l []string) map[string]any { return map[string]any{"enum": l} }
	blockTypes := slices.Sorted(func(yield func(string) bool) {
		for t := range blockFields {
			if !yield(t) {
				return
			}
		}
	})
	return map[string]map[string]any{
		"Manifest.apiVersion":    {"const": APIVersion},
		"Manifest.id":            {"pattern": idRe.String(), "description": "Lower-case letters, digits and dashes; unique in the index."},
		"Manifest.version":       {"description": "Semantic version, e.g. 1.0.0."},
		"Manifest.description":   {"maxLength": 200},
		"Manifest.minAppVersion": {"description": "The oldest k8sman that can load this plugin; older apps say so instead of failing."},
		"Manifest.kinds":         {"propertyNames": map[string]any{"pattern": kindKeyPattern}, "description": `Kind key (group/Kind, e.g. cert-manager.io/Certificate or /Pod; "*" for any kind: variables, related, metrics, panel sections and tabs, actions) → what the plugin adds to it.`},
		"Permissions.read":       {"items": map[string]any{"type": "string", "pattern": kindKeyPattern}, "description": "Kinds the plugin reads: its own and related ones. Secrets: names and keys only."},
		"Permissions.patch":      {"items": map[string]any{"type": "string", "pattern": kindKeyPattern, "not": map[string]any{"const": secretKind}}, "description": "Kinds patch actions may change (never Secrets)."},
		"Permissions.commands":   {"description": "Executables shell actions may run on this computer."},
		"Permissions.prometheus": {"description": "PromQL queries through the Prometheus integration (metrics)."},
		"Nav.kinds":              {"items": map[string]any{"type": "string", "pattern": kindKeyPattern}},
		"Kind.version":           {"description": "Pin the API version the entry applies to (default: any)."},
		"Kind.icon":              {"enum": append(slices.Clone(Icons), "icon.png")},
		"Kind.variables":         {"propertyNames": map[string]any{"pattern": identRe.String()}, "description": "Named CEL values, read as variables.<name>."},
		"Kind.related":           {"propertyNames": map[string]any{"pattern": identRe.String()}, "description": "Related objects for panels and actions, read as related.<name>."},
		"Kind.metrics":           {"propertyNames": map[string]any{"pattern": identRe.String()}, "description": "Instant PromQL queries for panels, read as metrics.<name>."},
		"Kind.hideColumns":       {"description": "Default columns to drop, by name (any case); \"*\" drops every default but Name, Namespace and Age."},
		"Related.kind":           {"pattern": kindKeyPattern, "description": "Kind key; must be in permissions.read."},
		"Related.owner":          {"description": "Objects whose ownerReferences include this object (at most 200)."},
		"Related.filter":         {"description": "bool, sees each candidate as item: keep those for which it is true, before the list is capped at 200. Alone, the candidates are every object of the kind in the namespace."},
		"Related.limit":          {"minimum": 0, "maximum": relatedMaxLimit, "description": "How many objects a list relation keeps (default 200, at most 2000); the panel notes what it left out."},
		"Related.namespace":      {"description": "string: where to look (default: the object's namespace; \"\" = every namespace)."},
		"Section.summary":        {"description": "string: a short text at the right of the section's header (a count, a state)."},
		"Tab.icon":               enum(Icons),
		"Tab.when":               {"description": "bool: whether the tab shows for this object (may read related)."},
		"Tab.into":               map[string]any{"enum": hostTabs, "description": "A tab of the app's own that these sections join on kinds that have it (security: the Security tab of Pods and workloads); elsewhere the tab is a tab of its own."},
		"Panel.tabs":             {"description": "Inspector tabs of the plugin's own, after the kind's tabs."},
		"TableColumn.detail":     {"description": "Draw the column on a line of its own under the row, across the table (a message, a description)."},
		"Alert.id":               {"pattern": actionIDRe.String()},
		"Alert.severity":         enum(alertSeverities),
		"Alert.section":          enum(alertSections),
		"Column.type":            enum(columnTypes),
		"Section.icon":           enum(Icons),
		"Block.type":             enum(blockTypes),
		"Block.format":           enum(barFormats),
		"Block.language":         enum(codeLanguages),
		"Block.severity":         enum(messageSeverity),
		"Block.title":            {"description": "message: a heading; a warning or error with one is a callout titled with it."},
		"Block.limit":            {"description": "table: rows shown before \"Show all\" (default 20); settings: rows (default 14, at most 50)."},
		"Block.value":            {"description": "bar: a number; code: a string, or any value (shown as YAML, or JSON with language json); json: any value; settings: a map, flattened into path → value rows (references become links)."},
		"FieldItem.type":         enum(valueTypes),
		"FieldItem.mono":         {"description": "Draw the value in the monospace font."},
		"TableColumn.type":       enum(valueTypes),
		"TableColumn.mono":       {"description": "Draw the cells in the monospace font."},
		"Panel.generic":          map[string]any{"enum": genericModes, "description": "For a kind without a compiled-in panel: keep the generic panel's sections after the plugin's (default), collapse them, or replace them with the plugin's."},
		"Kind.status":            {"description": "The kind's part of the plugin's status line in Settings ▸ Integrations: its object count and counts of objects matching CEL predicates."},
		"StatusCount.severity":   map[string]any{"enum": alertSeverities, "description": "Colours the status line when the count isn't zero (default warning)."},
		"Action.id":              {"pattern": actionIDRe.String()},
		"Action.icon":            enum(Icons),
		"Action.dangerous":       {"description": "Default true. Dangerous actions are styled as such; every plugin action is hidden on read-only contexts."},
		"Action.confirm":         {"description": "Shell actions are always confirmed in this version."},
		"Action.inputs":          {"description": "Form fields of a patch action, read as input.<name>."},
		"Shell.command":          {"description": "Must be in permissions.commands. Runs without a shell."},
		"Shell.args":             {"description": "Arguments; $NAME, $NAMESPACE, $CONTEXT, $COL-<NAME>, … are expanded per argument."},
		"Shell.background":       {"description": "Run without a dock tab and report the exit status and the last lines of output."},
		"Patch.type":             enum(patchTypes),
		"Input.name":             {"pattern": identRe.String()},
		"Input.type":             enum(inputTypes),
		"Input.options":          {"description": "The choices of an enum input."},
	}
}

// JSONSchema is plugin.yaml's JSON Schema (draft 2020-12).
func JSONSchema() []byte {
	g := &schemaGen{defs: map[string]any{}, extra: schemaField()}
	root := g.object(reflect.TypeFor[Manifest]())
	root["$schema"] = "https://json-schema.org/draft/2020-12/schema"
	root["$id"] = SchemaURL
	root["title"] = "k8sman plugin (plugin.yaml, " + APIVersion + ")"
	root["description"] = "A k8sman runtime plugin. See docs/PLUGINS.md. CEL fields are strings; `k8sman-server plugin validate` checks them."
	root["$defs"] = g.defs
	b, _ := json.MarshalIndent(root, "", "  ")
	return append(b, '\n')
}

type schemaGen struct {
	defs  map[string]any
	extra map[string]map[string]any
}

var (
	itemsType = reflect.TypeFor[items]()
	celDesc   = "CEL expression."
)

// typeSchema is the schema of a field of type t.
func (g *schemaGen) typeSchema(t reflect.Type) map[string]any {
	switch {
	case t == exprType:
		return map[string]any{"type": "string", "description": celDesc}
	case t == itemsType:
		return map[string]any{
			"description": "fields and badges: a list of items; chips and links: a CEL expression.",
			"oneOf": []any{
				map[string]any{"type": "array", "items": map[string]any{"type": "object"}},
				map[string]any{"type": "string", "description": celDesc},
			},
		}
	}
	switch t.Kind() {
	case reflect.Pointer:
		return g.typeSchema(t.Elem())
	case reflect.String:
		return map[string]any{"type": "string"}
	case reflect.Bool:
		return map[string]any{"type": "boolean"}
	case reflect.Int:
		return map[string]any{"type": "integer"}
	case reflect.Slice:
		return map[string]any{"type": "array", "items": g.typeSchema(t.Elem())}
	case reflect.Map:
		return map[string]any{"type": "object", "additionalProperties": g.typeSchema(t.Elem())}
	case reflect.Struct:
		name := t.Name()
		if _, ok := g.defs[name]; !ok {
			g.defs[name] = nil // placeholder against recursion
			g.defs[name] = g.object(t)
		}
		return map[string]any{"$ref": "#/$defs/" + name}
	}
	return map[string]any{}
}

// object is the schema of struct t: its yaml fields, nothing else.
func (g *schemaGen) object(t reflect.Type) map[string]any {
	props := map[string]any{}
	for i := range t.NumField() {
		f := t.Field(i)
		tag, _, _ := strings.Cut(f.Tag.Get("yaml"), ",")
		if tag == "" || tag == "-" {
			continue
		}
		s := g.typeSchema(f.Type)
		for k, v := range g.extra[t.Name()+"."+tag] {
			if k == "description" && s["description"] == celDesc {
				v = celDesc + " " + v.(string)
			}
			s[k] = v
		}
		if _, isRef := s["$ref"]; isRef && len(s) > 1 {
			s = map[string]any{"allOf": []any{map[string]any{"$ref": s["$ref"]}}, "description": s["description"]}
		}
		props[tag] = s
	}
	out := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
	if req := schemaRequired[t.Name()]; req != nil {
		out["required"] = req
	}
	switch t.Name() {
	case "Action":
		out["oneOf"] = []any{map[string]any{"required": []string{"shell"}}, map[string]any{"required": []string{"patch"}}}
	case "Block":
		var rules []any
		for _, typ := range slices.Sorted(func(yield func(string) bool) {
			for k := range blockFields {
				if !yield(k) {
					return
				}
			}
		}) {
			rules = append(rules, map[string]any{
				"if":   map[string]any{"properties": map[string]any{"type": map[string]any{"const": typ}}, "required": []string{"type"}},
				"then": map[string]any{"propertyNames": map[string]any{"enum": append([]string{"type", "when"}, blockFields[typ]...)}},
			})
		}
		out["allOf"] = rules
	}
	return out
}
