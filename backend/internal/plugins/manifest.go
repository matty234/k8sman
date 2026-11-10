// Package plugins loads runtime plugins: a folder with a plugin.yaml that
// adds table columns, inspector panel sections and shell actions for
// kinds, written in YAML and CEL. CEL is compiled once and evaluated here,
// in the backend, over the shared watch cache; the UI only draws the
// results with its own widgets. See docs/PLUGINS.md.
package plugins

import (
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/Masterminds/semver/v3"
	"gopkg.in/yaml.v3"
)

// APIVersion is the manifest version this build reads.
const APIVersion = "k8sman.dev/v1"

// ManifestFile is the plugin's one file in v1.
const ManifestFile = "plugin.yaml"

// Manifest is plugin.yaml.
type Manifest struct {
	APIVersion    string           `yaml:"apiVersion"`
	ID            string           `yaml:"id"`
	Name          string           `yaml:"name"`
	Version       string           `yaml:"version"`
	Description   string           `yaml:"description"`
	Authors       []string         `yaml:"authors"`
	Homepage      string           `yaml:"homepage"`
	MinAppVersion string           `yaml:"minAppVersion"`
	Permissions   Permissions      `yaml:"permissions"`
	Nav           *Nav             `yaml:"nav"`
	Kinds         map[string]*Kind `yaml:"kinds"`

	// KindOrder is the kind keys in file order.
	KindOrder []string `yaml:"-"`
}

// Permissions is what the plugin may use; checked both ways at load.
type Permissions struct {
	Read       []string `yaml:"read" json:"read,omitempty"`
	Patch      []string `yaml:"patch" json:"patch,omitempty"`
	Commands   []string `yaml:"commands" json:"commands,omitempty"`
	Prometheus bool     `yaml:"prometheus" json:"prometheus,omitempty"`
}

// Nav is a section of the sidebar's kinds list for the plugin's kinds
// (owner decision for v1: plugins may add one, see docs/PLUGINS.md §12).
type Nav struct {
	Title string `yaml:"title" json:"title"`
	// After names the section this one follows ("" = at the end).
	After string `yaml:"after" json:"after,omitempty"`
	// Kinds in display order; default: the plugin's kinds in file order.
	Kinds []string `yaml:"kinds" json:"kinds"`
}

// Kind is what a plugin adds to one kind.
type Kind struct {
	Version string `yaml:"version"`
	// Icon is the kind's sidebar glyph: a name from the icon list, or
	// "icon.png" for the plugin's own icon.
	Icon        string          `yaml:"icon"`
	Variables   map[string]Expr `yaml:"variables"`
	Related     unsupported     `yaml:"related"`
	Metrics     unsupported     `yaml:"metrics"`
	Columns     []Column        `yaml:"columns"`
	HideColumns []string        `yaml:"hideColumns"`
	Panel       *Panel          `yaml:"panel"`
	Actions     []Action        `yaml:"actions"`
	Alerts      unsupported     `yaml:"alerts"`
	pos         Pos
}

func (k *Kind) setPos(p Pos) { k.pos = p }

// Column is a table column.
type Column struct {
	Name        string `yaml:"name"`
	Value       Expr   `yaml:"value"`
	Type        string `yaml:"type"`
	Description string `yaml:"description"`
	pos         Pos
}

func (c *Column) setPos(p Pos) { c.pos = p }

// Panel is the kind's inspector sections.
type Panel struct {
	Sections []Section `yaml:"sections"`
}

// Section is one DetailSection.
type Section struct {
	Title     string  `yaml:"title"`
	Icon      string  `yaml:"icon"`
	When      Expr    `yaml:"when"`
	Collapsed bool    `yaml:"collapsed"`
	Blocks    []Block `yaml:"blocks"`
	pos       Pos
}

func (s *Section) setPos(p Pos) { s.pos = p }

// Block is one block of a section; which fields apply depends on Type
// (see blockFields).
type Block struct {
	Type string `yaml:"type"`
	When Expr   `yaml:"when"`
	// Items: a list of FieldItem (fields) or BadgeItem (badges), or a CEL
	// expression (chips, links).
	Items      items         `yaml:"items"`
	From       Expr          `yaml:"from"`
	Empty      string        `yaml:"empty"`
	Rows       Expr          `yaml:"rows"`
	Columns    []TableColumn `yaml:"columns"`
	SortBy     string        `yaml:"sortBy"`
	Descending bool          `yaml:"descending"`
	Limit      int           `yaml:"limit"`
	Label      string        `yaml:"label"`
	Value      Expr          `yaml:"value"`
	Max        Expr          `yaml:"max"`
	Format     string        `yaml:"format"`
	Language   string        `yaml:"language"`
	Text       Expr          `yaml:"text"`
	Severity   string        `yaml:"severity"`

	Fields []FieldItem `yaml:"-"`
	Badges []BadgeItem `yaml:"-"`
	pos    Pos
}

func (b *Block) setPos(p Pos) { b.pos = p }

// FieldItem is one row of a fields block.
type FieldItem struct {
	Label string `yaml:"label"`
	Value Expr   `yaml:"value"`
	Type  string `yaml:"type"`
	Link  Expr   `yaml:"link"`
	Copy  bool   `yaml:"copy"`
	When  Expr   `yaml:"when"`
}

// BadgeItem is one badge of a badges block.
type BadgeItem struct {
	Text     Expr `yaml:"text"`
	Severity Expr `yaml:"severity"`
	When     Expr `yaml:"when"`
}

// TableColumn is a column of a table block; its value sees `row`.
type TableColumn struct {
	Name  string `yaml:"name"`
	Value Expr   `yaml:"value"`
	Type  string `yaml:"type"`
	Link  Expr   `yaml:"link"`
}

// Action is a kind's action. v1 builds shell actions; patch actions are
// read but not offered yet (Milestone 2).
type Action struct {
	ID        string      `yaml:"id"`
	Label     string      `yaml:"label"`
	Icon      string      `yaml:"icon"`
	When      Expr        `yaml:"when"`
	Shortcut  string      `yaml:"shortcut"`
	Dangerous *bool       `yaml:"dangerous"`
	Confirm   *bool       `yaml:"confirm"`
	Message   string      `yaml:"message"`
	Shell     *Shell      `yaml:"shell"`
	Patch     unsupported `yaml:"patch"`
	Inputs    unsupported `yaml:"inputs"`
	pos       Pos
}

func (a *Action) setPos(p Pos) { a.pos = p }

// IsDangerous is dangerous, default true.
func (a *Action) IsDangerous() bool { return a.Dangerous == nil || *a.Dangerous }

// Shell is a k9s-style command.
type Shell struct {
	Command    string            `yaml:"command"`
	Args       []string          `yaml:"args"`
	Env        map[string]string `yaml:"env"`
	Background bool              `yaml:"background"`
}

// items holds a block's `items` until the block's type says what it is.
type items struct {
	node *yaml.Node
}

func (it *items) decodeNode(_ *decoder, n *yaml.Node) { it.node = n }

// unsupported accepts a v1 field that this build doesn't implement yet; the
// loader warns that it is ignored.
type unsupported struct {
	node *yaml.Node
}

func (u *unsupported) decodeNode(_ *decoder, n *yaml.Node) { u.node = n }

var (
	idRe       = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$`)
	actionIDRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$`)
	kindKeyRe  = regexp.MustCompile(`^[a-z0-9.-]*/[A-Z][A-Za-z0-9]*$`)
)

// AppVersion is this build's version, for minAppVersion (set by main;
// "" skips the check).
var AppVersion = ""

var columnTypes = []string{"string", "number", "age", "until", "status", "percent", "bool", "labels", "quantity"}
var valueTypes = []string{"text", "number", "bool", "status", "age", "until", "timestamp", "quantity", "labels", "url", "code"}

// blockFields lists the fields each block type takes (besides type, when).
var blockFields = map[string][]string{
	"fields":     {"items"},
	"badges":     {"items"},
	"chips":      {"items", "empty"},
	"conditions": {"from"},
	"links":      {"items", "empty"},
	"table":      {"rows", "columns", "sortBy", "descending", "limit", "empty"},
	"bar":        {"label", "value", "max", "format"},
	"code":       {"value", "language"},
	"json":       {"value"},
	"message":    {"text", "severity"},
}

// parseManifest decodes and checks plugin.yaml. Diags carry file:line:col;
// any non-warning diag means the manifest must not be used.
func parseManifest(src []byte) (*Manifest, []Diag) {
	d := &decoder{file: ManifestFile, lines: strings.Split(string(src), "\n")}
	var root yaml.Node
	if err := yaml.Unmarshal(src, &root); err != nil {
		line := 1
		msg := err.Error()
		if m := regexp.MustCompile(`line (\d+)`).FindStringSubmatch(msg); m != nil {
			fmt.Sscan(m[1], &line)
		}
		return nil, []Diag{d.diagAt(Pos{File: ManifestFile, Line: line, Col: 1}, false, "%s", strings.TrimPrefix(msg, "yaml: "))}
	}
	doc := resolve(&root)
	if doc == nil || doc.Kind != yaml.MappingNode {
		return nil, []Diag{d.diagAt(Pos{File: ManifestFile, Line: 1, Col: 1}, false, "plugin.yaml must be a map")}
	}
	m := &Manifest{}
	// minAppVersion first: a newer manifest says "needs k8sman ≥ x" rather
	// than failing on fields this build doesn't know.
	if n := field(doc, "minAppVersion"); n != nil && AppVersion != "" {
		need, err1 := semver.NewVersion(resolve(n).Value)
		have, err2 := semver.NewVersion(AppVersion)
		if err1 == nil && err2 == nil && have.LessThan(need) {
			return nil, []Diag{d.diagAt(d.pos(resolve(n)), false, "needs k8sman ≥ %s (this is %s)", need, AppVersion)}
		}
	}
	d.decode(doc, m)
	m.KindOrder, _ = mapKeys(field(doc, "kinds"))
	m.validate(d, doc)
	sortDiags(d.diags)
	return m, d.diags
}

// sortDiags orders diags by place in the file.
func sortDiags(ds []Diag) {
	slices.SortStableFunc(ds, func(a, b Diag) int {
		if a.Line != b.Line {
			return a.Line - b.Line
		}
		return a.Col - b.Col
	})
}

func (m *Manifest) validate(d *decoder, doc *yaml.Node) {
	at := func(key string) *yaml.Node {
		if n := field(doc, key); n != nil {
			return resolve(n)
		}
		return doc
	}
	if m.APIVersion != APIVersion {
		d.errAt(at("apiVersion"), "apiVersion must be %s", APIVersion)
	}
	if !idRe.MatchString(m.ID) {
		d.errAt(at("id"), "id must be lower-case letters, digits and dashes (at most 40), e.g. cert-manager")
	}
	if m.Name == "" {
		d.errAt(at("name"), "name is required")
	}
	if _, err := semver.StrictNewVersion(m.Version); err != nil {
		d.errAt(at("version"), "version must be semver, e.g. 1.0.0")
	}
	if len(m.Description) > 200 {
		d.errAt(at("description"), "description is longer than 200 characters")
	}
	if m.MinAppVersion != "" {
		if _, err := semver.NewVersion(m.MinAppVersion); err != nil {
			d.errAt(at("minAppVersion"), "minAppVersion must be semver")
		}
	}
	perm := resolve(field(doc, "permissions"))
	permAt := func(key string) *yaml.Node {
		if n := field(perm, key); n != nil {
			return resolve(n)
		}
		if perm != nil {
			return perm
		}
		return doc
	}
	for _, k := range m.Permissions.Read {
		if !kindKeyRe.MatchString(k) && k != "*" {
			d.errAt(permAt("read"), "permissions.read: %q is not a kind key such as cert-manager.io/Certificate or /Pod", k)
		}
	}
	if len(m.Permissions.Patch) > 0 {
		d.warnAt(permAt("patch"), "permissions.patch: patch actions aren't supported by this version yet")
	}
	if m.Permissions.Prometheus {
		d.warnAt(permAt("prometheus"), "permissions.prometheus: metrics aren't supported by this version yet")
	}
	if len(m.Kinds) == 0 {
		d.errAt(at("kinds"), "kinds is empty: a plugin contributes to at least one kind")
	}
	kindsNode := resolve(field(doc, "kinds"))
	_, keyNodes := mapKeys(kindsNode)
	usedCommands := map[string]bool{}
	for _, key := range m.KindOrder {
		k := m.Kinds[key]
		kn := keyNodes[key]
		if k == nil {
			continue
		}
		if key != "*" && !kindKeyRe.MatchString(key) {
			d.errAt(kn, "%q is not a kind key: write group/Kind, e.g. cert-manager.io/Certificate, or /Pod for the core group", key)
			continue
		}
		if key == "*" {
			if len(k.Columns) > 0 || k.Panel != nil || len(k.HideColumns) > 0 || len(k.Variables) > 0 {
				d.errAt(kn, `the "*" kind may only hold actions`)
			}
		} else if !slices.Contains(m.Permissions.Read, key) {
			d.errAt(kn, "%s is not in permissions.read", key)
		}
		k.validate(d, m, key, resolve(field(kindsNode, key)), usedCommands)
	}
	for _, k := range m.Permissions.Read {
		if _, ok := m.Kinds[k]; !ok {
			d.warnAt(permAt("read"), "permissions.read: %s is declared but no kind uses it (related objects come in a later version)", k)
		}
	}
	for _, c := range m.Permissions.Commands {
		if !usedCommands[c] {
			d.warnAt(permAt("commands"), "permissions.commands: %s is declared but no action runs it", c)
		}
	}
	if m.Nav != nil {
		n := resolve(field(doc, "nav"))
		if m.Nav.Title == "" {
			d.errAt(n, "nav.title is required")
		}
		if len(m.Nav.Kinds) == 0 {
			for _, k := range m.KindOrder {
				if k != "*" {
					m.Nav.Kinds = append(m.Nav.Kinds, k)
				}
			}
		}
		for _, k := range m.Nav.Kinds {
			if !kindKeyRe.MatchString(k) {
				d.errAt(n, "nav.kinds: %q is not a kind key", k)
			}
		}
	}
}

func (k *Kind) validate(d *decoder, m *Manifest, key string, n *yaml.Node, usedCommands map[string]bool) {
	for _, f := range []struct {
		name string
		u    unsupported
	}{{"related", k.Related}, {"metrics", k.Metrics}, {"alerts", k.Alerts}} {
		if f.u.node != nil {
			d.warnAt(resolve(f.u.node), "%s isn't supported by this version yet and is ignored", f.name)
		}
	}
	if k.Icon != "" && k.Icon != "icon.png" && !IconAllowed(k.Icon) {
		d.errAt(resolve(field(n, "icon")), "unknown icon %q (use a name from the icon list, or icon.png)", k.Icon)
	}
	for name := range k.Variables {
		if !identRe.MatchString(name) {
			d.errAt(resolve(field(field(n, "variables"), name)), "variable name %q must be a CEL identifier", name)
		}
	}
	seen := map[string]bool{}
	colsNode := resolve(field(n, "columns"))
	for i := range k.Columns {
		c := &k.Columns[i]
		cn := colsNode
		if cn != nil && i < len(cn.Content) {
			cn = resolve(cn.Content[i])
		}
		if c.Name == "" {
			d.errAt(cn, "a column needs a name")
		}
		if seen[c.Name] {
			d.errAt(cn, "column %q is listed twice", c.Name)
		}
		seen[c.Name] = true
		if !c.Value.IsSet() {
			d.errAt(cn, "column %q needs a value", c.Name)
		}
		if c.Type != "" && !slices.Contains(columnTypes, c.Type) {
			d.errAt(resolve(field(cn, "type")), "column type %q: use one of %s", c.Type, strings.Join(columnTypes, ", "))
		}
	}
	if k.Panel != nil {
		secs := resolve(field(resolve(field(n, "panel")), "sections"))
		for i := range k.Panel.Sections {
			s := &k.Panel.Sections[i]
			var sn *yaml.Node
			if secs != nil && i < len(secs.Content) {
				sn = resolve(secs.Content[i])
			}
			if s.Title == "" {
				d.errAt(sn, "a section needs a title")
			}
			if s.Icon != "" && !IconAllowed(s.Icon) {
				d.errAt(resolve(field(sn, "icon")), "unknown icon %q", s.Icon)
			}
			blocks := resolve(field(sn, "blocks"))
			for j := range s.Blocks {
				var bn *yaml.Node
				if blocks != nil && j < len(blocks.Content) {
					bn = resolve(blocks.Content[j])
				}
				s.Blocks[j].validate(d, bn)
			}
		}
	}
	ids := map[string]bool{}
	acts := resolve(field(n, "actions"))
	for i := range k.Actions {
		a := &k.Actions[i]
		var an *yaml.Node
		if acts != nil && i < len(acts.Content) {
			an = resolve(acts.Content[i])
		}
		if !actionIDRe.MatchString(a.ID) {
			d.errAt(an, "an action needs an id (lower-case letters, digits and dashes)")
		}
		if ids[a.ID] {
			d.errAt(an, "action %q is listed twice", a.ID)
		}
		ids[a.ID] = true
		if a.Label == "" {
			d.errAt(an, "action %q needs a label", a.ID)
		}
		if a.Icon != "" && !IconAllowed(a.Icon) {
			d.errAt(resolve(field(an, "icon")), "unknown icon %q", a.Icon)
		}
		if a.Patch.node != nil || a.Inputs.node != nil {
			d.warnAt(an, "action %q: patch actions aren't supported by this version yet; it is not offered", a.ID)
			continue
		}
		if a.Shell == nil {
			d.errAt(an, "action %q needs a shell command", a.ID)
			continue
		}
		sn := resolve(field(an, "shell"))
		if a.Shell.Command == "" {
			d.errAt(sn, "shell.command is required")
			continue
		}
		usedCommands[a.Shell.Command] = true
		if !slices.Contains(m.Permissions.Commands, a.Shell.Command) {
			d.errAt(resolve(field(sn, "command")), "%s is not in permissions.commands", a.Shell.Command)
		}
		if a.Shell.Background {
			d.warnAt(resolve(field(sn, "background")), "background isn't supported by this version yet; the command runs in a dock tab")
		}
		for j, arg := range a.Shell.Args {
			if j > 0 && a.Shell.Args[j-1] == "-c" && strings.Contains(arg, "$COL-") {
				d.warnAt(resolve(field(sn, "args")), "the -c script interpolates a $COL-… value directly; pass it through the environment instead (\"$K8SMAN_COL_…\")")
			}
		}
		if a.Confirm != nil && !*a.Confirm {
			d.warnAt(resolve(field(an, "confirm")), "plugin shell actions are always confirmed in this version")
		}
	}
	_ = key
}

func (b *Block) validate(d *decoder, n *yaml.Node) {
	allowed, ok := blockFields[b.Type]
	if !ok {
		types := make([]string, 0, len(blockFields))
		for t := range blockFields {
			types = append(types, t)
		}
		slices.Sort(types)
		d.errAt(orNode(resolve(field(n, "type")), n), "block type %q: use one of %s", b.Type, strings.Join(types, ", "))
		return
	}
	keys, keyNodes := mapKeys(n)
	for _, k := range keys {
		if k != "type" && k != "when" && !slices.Contains(allowed, k) {
			d.errAt(keyNodes[k], "a %s block has no field %q (it takes %s)", b.Type, k, strings.Join(allowed, ", "))
		}
	}
	need := func(set bool, f string) {
		if !set {
			d.errAt(n, "a %s block needs %s", b.Type, f)
		}
	}
	switch b.Type {
	case "fields", "badges":
		in := resolve(b.Items.node)
		if in == nil || in.Kind != yaml.SequenceNode {
			d.errAt(orNode(in, n), "a %s block's items is a list", b.Type)
			return
		}
		if b.Type == "fields" {
			d.decode(in, &b.Fields)
			for i, f := range b.Fields {
				if f.Label == "" || !f.Value.IsSet() {
					d.errAt(resolve(in.Content[i]), "a field needs a label and a value")
				}
				if f.Type != "" && !slices.Contains(valueTypes, f.Type) {
					d.errAt(resolve(in.Content[i]), "value type %q: use one of %s", f.Type, strings.Join(valueTypes, ", "))
				}
			}
		} else {
			d.decode(in, &b.Badges)
			for i, x := range b.Badges {
				if !x.Text.IsSet() {
					d.errAt(resolve(in.Content[i]), "a badge needs text")
				}
			}
		}
	case "chips", "links":
		in := resolve(b.Items.node)
		if in == nil || in.Kind != yaml.ScalarNode {
			d.errAt(orNode(in, n), "a %s block's items is a CEL expression", b.Type)
		}
	case "table":
		need(b.Rows.IsSet(), "rows")
		need(len(b.Columns) > 0, "columns")
		for _, c := range b.Columns {
			if c.Name == "" || !c.Value.IsSet() {
				d.errAt(n, "a table column needs a name and a value")
			}
			if c.Type != "" && !slices.Contains(valueTypes, c.Type) {
				d.errAt(n, "value type %q: use one of %s", c.Type, strings.Join(valueTypes, ", "))
			}
		}
		if b.SortBy != "" && !slices.ContainsFunc(b.Columns, func(c TableColumn) bool { return c.Name == b.SortBy }) {
			d.errAt(resolve(field(n, "sortBy")), "sortBy %q names no column", b.SortBy)
		}
	case "bar":
		need(b.Value.IsSet() && b.Max.IsSet(), "value and max")
		if b.Format != "" && !slices.Contains([]string{"number", "quantity", "percent"}, b.Format) {
			d.errAt(resolve(field(n, "format")), "format must be number, quantity or percent")
		}
	case "code":
		need(b.Value.IsSet(), "value")
		if b.Language != "" && !slices.Contains([]string{"text", "yaml", "json", "shell"}, b.Language) {
			d.errAt(resolve(field(n, "language")), "language must be text, yaml, json or shell")
		}
	case "json":
		need(b.Value.IsSet(), "value")
	case "message":
		need(b.Text.IsSet(), "text")
		if b.Severity != "" && !slices.Contains([]string{"info", "warning", "error"}, b.Severity) {
			d.errAt(resolve(field(n, "severity")), "severity must be info, warning or error")
		}
	}
}

func orNode(a, b *yaml.Node) *yaml.Node {
	if a != nil {
		return a
	}
	return b
}

var identRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
