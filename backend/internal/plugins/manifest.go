// Package plugins loads runtime plugins: a folder with a plugin.yaml that
// adds table columns, inspector panel sections, actions (shell commands
// and patches) and overview alerts for kinds, written in YAML and CEL. CEL is compiled once and evaluated here,
// in the backend, over the shared watch cache; the UI only draws the
// results with its own widgets. See docs/PLUGINS.md.
package plugins

import (
	"fmt"
	"maps"
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
	// Subresources are what subresource actions may call: kind key + "/" +
	// subresource (kubevirt.io/VirtualMachine/restart). Since 0.2.20.
	Subresources []string `yaml:"subresources" json:"subresources,omitempty"`
	// Create are the kinds create actions may create. Since 0.2.20.
	Create []string `yaml:"create" json:"create,omitempty"`
}

// Nav is a section of the sidebar's kinds list for the plugin's kinds
// (owner decision for v1: plugins may add one, see docs/PLUGINS.md §12).
type Nav struct {
	Title string `yaml:"title" json:"title"`
	// After is deprecated and ignored: integration sections follow the core
	// ones, alphabetically (the user can reorder them in Settings). Still
	// accepted so existing plugins load.
	After string `yaml:"after" json:"after,omitempty"`
	// Kinds in display order; default: the plugin's kinds in file order.
	Kinds []string `yaml:"kinds" json:"kinds"`
}

// Kind is what a plugin adds to one kind.
type Kind struct {
	Version string `yaml:"version"`
	// Icon is the kind's sidebar glyph: a name from the icon list, or
	// "icon.png" for the plugin's own icon.
	Icon        string             `yaml:"icon"`
	Variables   map[string]Expr    `yaml:"variables"`
	Related     map[string]Related `yaml:"related"`
	Metrics     map[string]Metric  `yaml:"metrics"`
	Columns     []Column           `yaml:"columns"`
	HideColumns []string           `yaml:"hideColumns"`
	Panel       *Panel             `yaml:"panel"`
	Actions     []Action           `yaml:"actions"`
	Alerts      []Alert            `yaml:"alerts"`
	// Status is the kind's part of the plugin's status line (its row in
	// Settings ▸ Integrations): a count of its objects and of those that
	// match each of Counts.
	Status *Status `yaml:"status"`
	// ExceptKinds and Scope narrow a "*" entry (and only that): it skips
	// the kinds in ExceptKinds (group/Kind keys) and, with Scope
	// namespaced or cluster, the other kind of resource, so the UI doesn't
	// fetch the plugin's panel for objects it can't apply to.
	ExceptKinds []string `yaml:"exceptKinds"`
	Scope       string   `yaml:"scope"`
	// Templates are starting points for the resource editor's create mode
	// (templates.go). They need no permissions.
	Templates []Template `yaml:"templates"`
	pos       Pos
}

// Status counts a kind's objects across the cluster for the plugin's
// status line ("ExternalSecrets: 12 · not synced: 2"), coloured by the
// most severe count that isn't zero.
type Status struct {
	// Label names the objects ("ExternalSecrets").
	Label  string        `yaml:"label"`
	Counts []StatusCount `yaml:"counts"`
}

// StatusCount is the number of objects for which When is true. Like
// alerts, it sees the object only.
type StatusCount struct {
	Label    string `yaml:"label"`
	When     Expr   `yaml:"when"`
	Severity string `yaml:"severity"`
}

// Related is an object (name) or objects (owner, selector, filter) that a
// kind's panels and actions read as related.<name>, from the watch cache.
// Its kind must be in permissions.read.
type Related struct {
	Kind      string `yaml:"kind"`
	Name      Expr   `yaml:"name"`
	Owner     bool   `yaml:"owner"`
	Selector  Expr   `yaml:"selector"`
	Namespace Expr   `yaml:"namespace"`
	When      Expr   `yaml:"when"`
	// Filter keeps the candidates for which it is true (it sees each as
	// `item`), evaluated by the host before the list is capped. Alone (no
	// name, owner or selector) the candidates are every object of the kind
	// in the namespace.
	Filter Expr `yaml:"filter"`
	// Limit is how many objects a list relation keeps (default 200, at
	// most relatedMaxLimit); beyond it the panel says how many it left out.
	Limit int `yaml:"limit"`
}

// ListLimit is Limit with its default.
func (r *Related) ListLimit() int {
	if r.Limit <= 0 {
		return relatedLimit
	}
	return r.Limit
}

// IsList is whether related.<name> is a list (owner, selector and filter
// relations) rather than one object.
func (r *Related) IsList() bool { return !r.Name.IsSet() }

// Metric is an instant PromQL query for panels (metrics.<name>), run
// through the Prometheus module; it needs permissions.prometheus.
type Metric struct {
	Query    Expr   `yaml:"query"`
	Instance string `yaml:"instance"`
}

// Alert is a per-object rule evaluated on each overview poll; a hit is an
// issue on the Overview and in the dock's Issues tab.
type Alert struct {
	ID       string `yaml:"id"`
	Label    string `yaml:"label"`
	Severity string `yaml:"severity"`
	Section  string `yaml:"section"`
	When     Expr   `yaml:"when"`
	Message  Expr   `yaml:"message"`
	Since    Expr   `yaml:"since"`
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
	// Generic says what happens to the generic panel's sections (Health,
	// Conditions, Spec, Status, …) for a kind without a compiled-in panel:
	// keep (default: after the plugin's sections), collapse (there, but
	// collapsed) or replace (left out: the plugin's sections are the
	// panel). The shell's Owns and Metadata sections stay either way.
	// Kinds with a compiled-in panel ignore it.
	Generic  string    `yaml:"generic"`
	Sections []Section `yaml:"sections"`
	// Tabs are inspector tabs of the plugin's own, after the kind's (or,
	// with into, sections of a host tab the kind has).
	Tabs []Tab `yaml:"tabs"`
}

// Tab is an inspector tab a plugin adds: its sections, shown while When
// holds (When may read related, so the tab appears once the panel has
// rendered). Into names a host tab (hostTabs): on kinds that have it, the
// sections go into that tab instead of a tab of their own. A policy
// engine's results go into the Security tab of Pods and workloads, and
// are a tab of their own on other kinds.
type Tab struct {
	// ID identifies the tab (remembered selection, API): lower-case
	// letters, digits and dashes, unique among the entry's tabs. Default:
	// a slug of Title.
	ID       string    `yaml:"id"`
	Title    string    `yaml:"title"`
	Icon     string    `yaml:"icon"`
	When     Expr      `yaml:"when"`
	Into     string    `yaml:"into"`
	Sections []Section `yaml:"sections"`
}

// TabID is the tab's id: its own, or a slug of its title.
func (t Tab) TabID() string {
	if t.ID != "" {
		return t.ID
	}
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(t.Title) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			if dash && b.Len() > 0 {
				b.WriteByte('-')
			}
			dash = false
			b.WriteRune(r)
		} else {
			dash = true
		}
	}
	id := b.String()
	if id == "" || id[0] < 'a' || id[0] > 'z' {
		id = "tab-" + id
	}
	return strings.TrimSuffix(id, "-")
}

// GenericMode is Generic with its default.
func (p *Panel) GenericMode() string {
	if p == nil {
		return "keep"
	}
	return orDefault(p.Generic, "keep")
}

// Section is one DetailSection.
type Section struct {
	Title string `yaml:"title"`
	Icon  string `yaml:"icon"`
	When  Expr   `yaml:"when"`
	// Summary is a short text at the right of the section's header (a
	// count, a state); empty shows nothing.
	Summary Expr `yaml:"summary"`
	// Badge is a coloured state in the header, beside the summary.
	Badge     *BadgeItem `yaml:"badge"`
	Collapsed bool       `yaml:"collapsed"`
	Blocks    []Block    `yaml:"blocks"`
	// Placement puts the section at the top or the bottom (default) of a
	// compiled-in panel's sections; After puts it after the core section
	// with that id (coreSections), at the bottom when the panel doesn't
	// show one. Sections of kinds without a compiled-in panel, and of
	// tabs, keep their order.
	Placement string `yaml:"placement"`
	After     string `yaml:"after"`
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
	// Title is a message's heading (CEL): with one, a warning or an error
	// is a callout titled with it, the text under it.
	Title Expr `yaml:"title"`

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
	// Mono draws the value in the monospace font (versions, keys, ids).
	Mono bool `yaml:"mono"`
	// Severity (CEL: a severity name) colours the value.
	Severity Expr `yaml:"severity"`
}

// BadgeItem is one badge of a badges block.
type BadgeItem struct {
	Text     Expr `yaml:"text"`
	Severity Expr `yaml:"severity"`
	When     Expr `yaml:"when"`
}

// TableColumn is a column of a table block; its value and link see `item`.
type TableColumn struct {
	Name  string `yaml:"name"`
	Value Expr   `yaml:"value"`
	Type  string `yaml:"type"`
	Link  Expr   `yaml:"link"`
	Mono  bool   `yaml:"mono"`
	// Detail draws the column on a line of its own under the row's other
	// cells, across the table, in a quieter style (a message, a
	// description). An empty one draws nothing.
	Detail bool `yaml:"detail"`
	// Severity (CEL over item: a severity name) colours the cell.
	Severity Expr `yaml:"severity"`
}

// Action is a kind's action: a shell command run on this computer, or,
// through the app's action path (POST /api/actions/plugin.<id>.<action>),
// a patch of the object, a call of one of its subresources, or the
// creation of an object that refers to it.
type Action struct {
	ID        string `yaml:"id"`
	Label     string `yaml:"label"`
	Icon      string `yaml:"icon"`
	When      Expr   `yaml:"when"`
	Shortcut  string `yaml:"shortcut"`
	Dangerous *bool  `yaml:"dangerous"`
	Confirm   *bool  `yaml:"confirm"`
	Message   string `yaml:"message"`
	Shell     *Shell `yaml:"shell"`
	Patch     *Patch `yaml:"patch"`
	// Subresource and Create are since 0.2.20.
	Subresource *Subresource `yaml:"subresource"`
	Create      *Create      `yaml:"create"`
	Inputs      []Input      `yaml:"inputs"`
	pos         Pos
}

// Subresource is a subresource action's request: Method on
// /apis/{group}/{version}/[namespaces/{ns}/]{resource}/{object}/{name}.
type Subresource struct {
	// Name is the subresource (restart, pause, …).
	Name string `yaml:"name"`
	// Method is PUT (default) or POST.
	Method string `yaml:"method"`
	// Group and Version serve it (default: the object's), e.g.
	// subresources.kubevirt.io for KubeVirt's aggregated API.
	Group   string `yaml:"group"`
	Version string `yaml:"version"`
	// Body is a map sent as JSON (default {}); it sees input.
	Body Expr `yaml:"body"`
}

// Create is a create action's object.
type Create struct {
	// Kind is the kind key of the object created; must be in
	// permissions.create.
	Kind string `yaml:"kind"`
	// Body is the object: a map with apiVersion, kind and metadata.name or
	// metadata.generateName; it sees input.
	Body Expr `yaml:"body"`
}

// Kind is shell, patch, subresource or create.
func (a *Action) Kind() string {
	switch {
	case a.Shell != nil:
		return "shell"
	case a.Patch != nil:
		return "patch"
	case a.Subresource != nil:
		return "subresource"
	case a.Create != nil:
		return "create"
	}
	return ""
}

// Writes is whether the action writes through the action path (patch,
// subresource or create).
func (a *Action) Writes() bool { return a.Patch != nil || a.Subresource != nil || a.Create != nil }

// Patch is a patch action's change to the object.
type Patch struct {
	// Type is merge (a JSON merge patch) or json (a JSON patch).
	Type string `yaml:"type"`
	// Body is a map (merge) or a list of operations (json); it sees input.
	Body Expr `yaml:"body"`
}

// Input is a form field of a patch action, checked by the backend.
type Input struct {
	Name            string   `yaml:"name"`
	Label           string   `yaml:"label"`
	Type            string   `yaml:"type"`
	Options         []string `yaml:"options"`
	Default         Expr     `yaml:"default"`
	Validate        Expr     `yaml:"validate"`
	ValidateMessage string   `yaml:"validateMessage"`
}

// InputType is the input's type (default string).
func (in *Input) InputType() string { return orDefault(in.Type, "string") }

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

var (
	tabIDRe    = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	idRe       = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$`)
	actionIDRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$`)
	kindKeyRe  = regexp.MustCompile(`^[a-z0-9.-]*/[A-Z][A-Za-z0-9]*$`)
)

// AppVersion is this build's version, for minAppVersion (set by main;
// "" skips the check).
var AppVersion = ""

var columnTypes = []string{"string", "number", "age", "until", "status", "percent", "bool", "labels", "quantity", "bytes"}
var valueTypes = []string{"text", "number", "bool", "status", "age", "until", "timestamp", "quantity", "labels", "url", "code"}

// Enumerations of other fields (the JSON Schema is built from the same
// lists, see schema.go).
var (
	// error is a synonym of critical (see normSeverity).
	alertSeverities = []string{"critical", "error", "warning", "info"}
	alertSections   = []string{"pods", "workloads", "jobs", "nodes", "storage", "network", "custom"}
	inputTypes      = []string{"string", "int", "bool", "enum"}
	patchTypes      = []string{"merge", "json"}
	subMethods      = []string{"PUT", "POST"}
	messageSeverity = []string{"info", "warning", "error"}
	// severities are what a severity expression returns (badges, section
	// badges, field and cell values). severityAliases were accepted before
	// v1 was frozen: they still work, and validate warns.
	severities      = []string{"error", "warning", "ok", "info", "neutral"}
	severityAliases = map[string]string{"critical": "error", "warn": "warning", "success": "ok"}
	placements      = []string{"top", "bottom"}
	barFormats      = []string{"number", "quantity", "percent"}
	codeLanguages   = []string{"text", "yaml", "json", "shell"}
	genericModes    = []string{"keep", "collapse", "replace"}
	// hostTabs are the app's own tabs a plugin tab can go into (Tab.Into):
	// security is the Security tab of Pods and workloads.
	hostTabs     = []string{"security"}
	kindScopes   = []string{"any", "namespaced", "cluster"}
	jsonPatchOps = []string{"add", "remove", "replace", "move", "copy", "test"}
)

// secretKind is the kind key of Secrets: plugins see their keys, never
// their values, and can't change them.
const secretKind = "/Secret"

// Subresource and create actions never touch these: credentials, RBAC and
// admission are not a plugin's to change, and the core group's pod and
// service subresources are not what the feature is for.
var (
	deniedSubresources  = []string{"exec", "attach", "portforward", "proxy", "log", "eviction", "status", "scale", "binding", "token", "approval", "ephemeralcontainers"}
	deniedSubresourceOn = []string{secretKind, "/ServiceAccount"}
	deniedCreateKinds   = []string{secretKind, "/ServiceAccount"}
	deniedCreateGroups  = []string{"rbac.authorization.k8s.io", "admissionregistration.k8s.io"}
	subresourceNameRe   = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	subresourcePermRe   = regexp.MustCompile(`^[a-z0-9.-]*/[A-Z][A-Za-z0-9]*/[a-z][a-z0-9-]*$`)
	apiGroupRe          = regexp.MustCompile(`^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$`)
	apiVersionRe        = regexp.MustCompile(`^v[0-9]+((alpha|beta)[0-9]+)?$`)
)

// writeActionsVersion is the release that brought subresource and create
// actions.
const writeActionsVersion = "0.2.20"

// subresourceDenied says why subresource sub of kind key can't be called
// ("" = it can).
func subresourceDenied(key, sub string) string {
	switch {
	case slices.Contains(deniedSubresources, sub):
		return "plugins can't call the " + sub + " subresource"
	case slices.Contains(deniedSubresourceOn, key):
		return "plugins can't call subresources of " + key
	}
	return ""
}

// createDenied says why kind key can't be created by a plugin ("" = it
// can).
func createDenied(key string) string {
	group, _, _ := strings.Cut(key, "/")
	if slices.Contains(deniedCreateKinds, key) || slices.Contains(deniedCreateGroups, group) {
		return "plugins can't create " + key
	}
	return ""
}

// relatedLimit caps the objects of a list relation (owner, selector or
// filter) unless it sets limit, which can raise it to relatedMaxLimit.
const (
	relatedLimit    = 200
	relatedMaxLimit = 2000
)

// usage is what the kinds use of the permissions (checked both ways).
type usage struct {
	read, patch          map[string]bool
	subresources, create map[string]bool
	commands             map[string]bool
	prometheus           bool
}

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
	"message":    {"text", "severity", "title"},
	"settings":   {"value", "limit", "empty"},
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
	for _, k := range m.Permissions.Patch {
		switch {
		case !kindKeyRe.MatchString(k):
			d.errAt(permAt("patch"), "permissions.patch: %q is not a kind key such as karpenter.sh/NodePool", k)
		case k == secretKind:
			d.errAt(permAt("patch"), "permissions.patch: plugins can't change Secrets")
		}
	}
	for _, k := range m.Permissions.Subresources {
		if !subresourcePermRe.MatchString(k) {
			d.errAt(permAt("subresources"), "permissions.subresources: %q is not a kind key and a subresource such as kubevirt.io/VirtualMachine/restart", k)
			continue
		}
		i := strings.LastIndex(k, "/")
		if why := subresourceDenied(k[:i], k[i+1:]); why != "" {
			d.errAt(permAt("subresources"), "permissions.subresources: %s", why)
		}
	}
	for _, k := range m.Permissions.Create {
		switch {
		case !kindKeyRe.MatchString(k):
			d.errAt(permAt("create"), "permissions.create: %q is not a kind key such as kubevirt.io/VirtualMachineInstanceMigration", k)
		case createDenied(k) != "":
			d.errAt(permAt("create"), "permissions.create: %s", createDenied(k))
		}
	}
	if len(m.Kinds) == 0 {
		d.errAt(at("kinds"), "kinds is empty: a plugin contributes to at least one kind")
	}
	kindsNode := resolve(field(doc, "kinds"))
	_, keyNodes := mapKeys(kindsNode)
	used := &usage{read: map[string]bool{}, patch: map[string]bool{}, subresources: map[string]bool{}, create: map[string]bool{}, commands: map[string]bool{}}
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
			// Any kind: what an inspected object shows and offers. Tables,
			// overview polls and the status line stay per kind, so they
			// never evaluate a plugin for every object of every kind.
			if len(k.Columns) > 0 || len(k.HideColumns) > 0 || len(k.Alerts) > 0 || k.Status != nil || k.Icon != "" || k.Version != "" ||
				(k.Panel != nil && k.Panel.Generic != "") || len(k.Templates) > 0 {
				d.errAt(kn, `the "*" kind may hold variables, related, metrics, panel sections and tabs, and actions (not columns, hideColumns, alerts, status, icon, version, panel.generic or templates)`)
			}
			if !slices.Contains(m.Permissions.Read, "*") {
				d.errAt(kn, `the "*" kind reads every object the user inspects: add "*" to permissions.read (permissions: {read: ["*"]})`)
			}
		} else {
			if len(k.ExceptKinds) > 0 || k.Scope != "" {
				d.errAt(kn, `exceptKinds and scope belong to the "*" kind`)
			}
			if !slices.Contains(m.Permissions.Read, key) {
				d.errAt(kn, "%s is not in permissions.read", key)
			}
		}
		if k.Scope != "" && !slices.Contains(kindScopes, k.Scope) {
			d.errAt(resolve(field(kn, "scope")), "scope must be one of %s", strings.Join(kindScopes, ", "))
		}
		for _, x := range k.ExceptKinds {
			if !kindKeyRe.MatchString(x) {
				d.errAt(resolve(field(kn, "exceptKinds")), "exceptKinds: %q is not a kind key such as apps/Deployment or /Pod", x)
			}
		}
		used.read[key] = true
		k.validate(d, m, key, resolve(field(kindsNode, key)), used)
		if key != "*" {
			validateTemplates(d, key, k, resolve(field(kindsNode, key)))
		}
	}
	for _, k := range m.Permissions.Read {
		if !used.read[k] {
			d.warnAt(permAt("read"), "permissions.read: %s is declared but neither a kind nor a related object uses it", k)
		}
	}
	for _, k := range m.Permissions.Patch {
		if !used.patch[k] {
			d.warnAt(permAt("patch"), "permissions.patch: %s is declared but no patch action changes it", k)
		}
	}
	for _, k := range m.Permissions.Subresources {
		if !used.subresources[k] {
			d.warnAt(permAt("subresources"), "permissions.subresources: %s is declared but no subresource action calls it", k)
		}
	}
	for _, k := range m.Permissions.Create {
		if !used.create[k] {
			d.warnAt(permAt("create"), "permissions.create: %s is declared but no create action creates it", k)
		}
	}
	if len(m.Permissions.Subresources)+len(m.Permissions.Create) > 0 && !versionAtLeast(m.MinAppVersion, writeActionsVersion) {
		d.warnAt(permAt("subresources"), "subresource and create actions need k8sman ≥ %s: set minAppVersion: %q so older apps say so instead of failing to load", writeActionsVersion, writeActionsVersion)
	}
	for _, c := range m.Permissions.Commands {
		if !used.commands[c] {
			d.warnAt(permAt("commands"), "permissions.commands: %s is declared but no action runs it", c)
		}
	}
	if m.Permissions.Prometheus && !used.prometheus {
		d.warnAt(permAt("prometheus"), "permissions.prometheus is declared but no kind has metrics")
	}
	if m.Nav != nil {
		n := resolve(field(doc, "nav"))
		if m.Nav.Title == "" {
			d.errAt(n, "nav.title is required")
		}
		if m.Nav.After != "" {
			d.warnAt(resolve(field(n, "after")), "nav.after is deprecated and ignored: plugin sections follow the core ones (users reorder them in Settings ▸ Sidebar)")
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

func (k *Kind) validate(d *decoder, m *Manifest, key string, n *yaml.Node, used *usage) {
	relNode := resolve(field(n, "related"))
	for _, name := range slices.Sorted(maps.Keys(k.Related)) {
		r := k.Related[name]
		rn := orNode(resolve(field(relNode, name)), relNode)
		if !identRe.MatchString(name) {
			d.errAt(rn, "related name %q must be a CEL identifier", name)
		}
		switch {
		case !kindKeyRe.MatchString(r.Kind):
			d.errAt(orNode(resolve(field(rn, "kind")), rn), "related.%s: kind must be a kind key such as /Secret or cert-manager.io/CertificateRequest", name)
		case !slices.Contains(m.Permissions.Read, r.Kind):
			d.errAt(orNode(resolve(field(rn, "kind")), rn), "related.%s: %s is not in permissions.read", name, r.Kind)
		default:
			used.read[r.Kind] = true
		}
		ways := 0
		for _, set := range []bool{r.Name.IsSet(), r.Owner, r.Selector.IsSet()} {
			if set {
				ways++
			}
		}
		switch {
		case ways > 1:
			d.errAt(rn, "related.%s takes one of name, owner and selector", name)
		case ways == 0 && !r.Filter.IsSet():
			d.errAt(rn, "related.%s needs one of name, owner, selector and filter", name)
		}
		if r.Limit < 0 || r.Limit > relatedMaxLimit || (r.Limit != 0 && !r.IsList()) {
			d.errAt(orNode(resolve(field(rn, "limit")), rn), "related.%s: limit is for lists (owner, selector, filter), from 1 to %d", name, relatedMaxLimit)
		}
	}
	metNode := resolve(field(n, "metrics"))
	for _, name := range slices.Sorted(maps.Keys(k.Metrics)) {
		mn := orNode(resolve(field(metNode, name)), metNode)
		if !identRe.MatchString(name) {
			d.errAt(mn, "metric name %q must be a CEL identifier", name)
		}
		if !k.Metrics[name].Query.IsSet() {
			d.errAt(mn, "metrics.%s needs a query", name)
		}
		if !m.Permissions.Prometheus {
			d.errAt(mn, "metrics.%s: metrics need permissions.prometheus: true", name)
		}
		used.prometheus = true
	}
	alertsNode := resolve(field(n, "alerts"))
	alertIDs := map[string]bool{}
	for i := range k.Alerts {
		a := &k.Alerts[i]
		var an *yaml.Node
		if alertsNode != nil && i < len(alertsNode.Content) {
			an = resolve(alertsNode.Content[i])
		}
		if !actionIDRe.MatchString(a.ID) {
			d.errAt(an, "an alert needs an id (lower-case letters, digits and dashes)")
		}
		if alertIDs[a.ID] {
			d.errAt(an, "alert %q is listed twice", a.ID)
		}
		alertIDs[a.ID] = true
		if a.Label == "" {
			d.errAt(an, "alert %q needs a label", a.ID)
		}
		if !a.When.IsSet() {
			d.errAt(an, "alert %q needs when", a.ID)
		}
		if a.Severity != "" && !slices.Contains(alertSeverities, a.Severity) {
			d.errAt(resolve(field(an, "severity")), "severity must be one of %s", strings.Join(alertSeverities, ", "))
		}
		if a.Section != "" && !slices.Contains(alertSections, a.Section) {
			d.errAt(resolve(field(an, "section")), "section must be one of %s", strings.Join(alertSections, ", "))
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
	if k.Status != nil {
		sn := resolve(field(n, "status"))
		if k.Status.Label == "" {
			d.errAt(sn, "status needs a label (what its objects are called, e.g. Certificates)")
		}
		cn := resolve(field(sn, "counts"))
		for i, c := range k.Status.Counts {
			var in *yaml.Node
			if cn != nil && i < len(cn.Content) {
				in = resolve(cn.Content[i])
			}
			if c.Label == "" || !c.When.IsSet() {
				d.errAt(orNode(in, sn), "a status count needs a label and when")
			}
			if c.Severity != "" && !slices.Contains(alertSeverities, c.Severity) {
				d.errAt(resolve(field(in, "severity")), "severity must be one of %s", strings.Join(alertSeverities, ", "))
			}
		}
	}
	if k.Panel != nil {
		pn := resolve(field(n, "panel"))
		if k.Panel.Generic != "" && !slices.Contains(genericModes, k.Panel.Generic) {
			d.errAt(resolve(field(pn, "generic")), "panel.generic must be one of %s", strings.Join(genericModes, ", "))
		}
		validateSections(d, k.Panel.Sections, resolve(field(pn, "sections")), key, false)
		tabsNode := resolve(field(pn, "tabs"))
		titles := map[string]bool{}
		tabIDs := map[string]bool{}
		for i := range k.Panel.Tabs {
			t := &k.Panel.Tabs[i]
			var tn *yaml.Node
			if tabsNode != nil && i < len(tabsNode.Content) {
				tn = resolve(tabsNode.Content[i])
			}
			switch {
			case t.Title == "":
				d.errAt(orNode(tn, pn), "a tab needs a title")
			case titles[t.Title]:
				d.errAt(orNode(tn, pn), "tab %q is listed twice", t.Title)
			case slices.Contains([]string{"Overview", "YAML", "Events"}, t.Title):
				d.errAt(orNode(tn, pn), "tab %q has the name of one of the inspector's own tabs", t.Title)
			}
			titles[t.Title] = true
			if t.ID != "" && !tabIDRe.MatchString(t.ID) {
				d.errAt(resolve(field(tn, "id")), "tab id %q: lower-case letters, digits and dashes, starting with a letter", t.ID)
			} else if tabIDs[t.TabID()] {
				d.errAt(orNode(tn, pn), "tab id %q is used twice (give the tabs an id)", t.TabID())
			}
			tabIDs[t.TabID()] = true
			if t.Icon != "" && !IconAllowed(t.Icon) {
				d.errAt(resolve(field(tn, "icon")), "unknown icon %q", t.Icon)
			}
			if t.Into != "" && !slices.Contains(hostTabs, t.Into) {
				d.errAt(resolve(field(tn, "into")), "into must be one of %s", strings.Join(hostTabs, ", "))
			}
			if len(t.Sections) == 0 {
				d.errAt(orNode(tn, pn), "tab %q needs sections", t.Title)
			}
			validateSections(d, t.Sections, resolve(field(tn, "sections")), key, true)
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
		if msg := shortcutProblem(a.Shortcut); msg != "" {
			d.warnAt(resolve(field(an, "shortcut")), "shortcut %q %s; it is ignored", a.Shortcut, msg)
		}
		kinds := 0
		for _, set := range []bool{a.Shell != nil, a.Patch != nil, a.Subresource != nil, a.Create != nil} {
			if set {
				kinds++
			}
		}
		if kinds != 1 {
			d.errAt(an, "action %q needs exactly one of shell, patch, subresource and create", a.ID)
			continue
		}
		if a.Writes() {
			a.validateWrite(d, m, key, an, used)
			continue
		}
		if len(a.Inputs) > 0 {
			d.errAt(resolve(field(an, "inputs")), "action %q: inputs are for patch, subresource and create actions only", a.ID)
		}
		sn := resolve(field(an, "shell"))
		if a.Shell.Command == "" {
			d.errAt(sn, "shell.command is required")
			continue
		}
		used.commands[a.Shell.Command] = true
		if !slices.Contains(m.Permissions.Commands, a.Shell.Command) {
			d.errAt(resolve(field(sn, "command")), "%s is not in permissions.commands", a.Shell.Command)
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
}

// validateSections checks sections (of kind key's panel, or of a tab);
// secs is their YAML list.
func validateSections(d *decoder, sections []Section, secs *yaml.Node, key string, inTab bool) {
	for i := range sections {
		s := &sections[i]
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
		validatePlacement(d, s, sn, key, inTab)
		if s.Badge != nil {
			bn := resolve(field(sn, "badge"))
			if !s.Badge.Text.IsSet() {
				d.errAt(bn, "a badge needs text")
			}
			checkSeverity(d, s.Badge.Severity)
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

// builtinKeys are the table's single-key bindings (k9s style), which win
// over a plugin action's shortcut.
var builtinKeys = []string{"J", "K", "G", "/", "D", "Y", "E", "L", "S", "shift+G", "shift+/", "shift+F"}

// shortcutProblem says why shortcut s can't be bound ("" = it can): the
// table binds one letter or digit, with or without Shift, on the selected
// row.
func shortcutProblem(s string) string {
	if s == "" {
		return ""
	}
	parts := strings.Split(s, "+")
	key := parts[len(parts)-1]
	mods := parts[:len(parts)-1]
	if len(key) != 1 || !isWordChar(key[0]) || key[0] == '_' {
		return "must be one letter or digit, optionally with shift+ (e.g. shift+R)"
	}
	for _, m := range mods {
		if !strings.EqualFold(m, "shift") {
			return "uses " + m + ": only plain and shift+ shortcuts are bound in this version"
		}
	}
	norm := strings.ToUpper(key)
	if len(mods) > 0 {
		norm = "shift+" + norm
	}
	if slices.Contains(builtinKeys, norm) {
		return "is a built-in key of the table"
	}
	return ""
}

// versionAtLeast is whether semver v is at least min (false when v isn't
// a version).
func versionAtLeast(v, min string) bool {
	have, err := semver.NewVersion(v)
	return err == nil && !have.LessThan(semver.MustParse(min))
}

// validateWrite checks a patch, subresource or create action of kind key,
// and its inputs.
func (a *Action) validateWrite(d *decoder, m *Manifest, key string, an *yaml.Node, used *usage) {
	kind := a.Kind()
	pn := resolve(field(an, kind))
	if key == "*" {
		d.errAt(pn, `action %q: %s actions belong to a kind, not "*"`, a.ID, kind)
	}
	switch {
	case a.Patch != nil:
		switch {
		case key == "*":
		case key == secretKind:
			d.errAt(pn, "action %q: plugins can't change Secrets", a.ID)
		case !slices.Contains(m.Permissions.Patch, key):
			d.errAt(pn, "action %q: %s is not in permissions.patch", a.ID, key)
		default:
			used.patch[key] = true
		}
		if !slices.Contains(patchTypes, a.Patch.Type) {
			d.errAt(orNode(resolve(field(pn, "type")), pn), "patch.type must be merge or json")
		}
		if !a.Patch.Body.IsSet() {
			d.errAt(pn, "patch.body is required")
		}
	case a.Subresource != nil:
		sr := a.Subresource
		perm := key + "/" + sr.Name
		switch {
		case !subresourceNameRe.MatchString(sr.Name):
			d.errAt(orNode(resolve(field(pn, "name")), pn), "subresource.name is required: lower-case letters, digits and dashes, e.g. restart")
		case key == "*":
		case subresourceDenied(key, sr.Name) != "":
			d.errAt(pn, "action %q: %s", a.ID, subresourceDenied(key, sr.Name))
		case !slices.Contains(m.Permissions.Subresources, perm):
			d.errAt(pn, "action %q: %s is not in permissions.subresources", a.ID, perm)
		default:
			used.subresources[perm] = true
		}
		if sr.Method != "" && !slices.Contains(subMethods, sr.Method) {
			d.errAt(resolve(field(pn, "method")), "subresource.method must be PUT or POST")
		}
		if sr.Group != "" && !apiGroupRe.MatchString(sr.Group) {
			d.errAt(resolve(field(pn, "group")), "subresource.group must be an API group such as subresources.kubevirt.io")
		}
		if sr.Version != "" && !apiVersionRe.MatchString(sr.Version) {
			d.errAt(resolve(field(pn, "version")), "subresource.version must be an API version such as v1")
		}
	case a.Create != nil:
		c := a.Create
		switch {
		case !kindKeyRe.MatchString(c.Kind):
			d.errAt(orNode(resolve(field(pn, "kind")), pn), "create.kind is required: the kind key of the object created, e.g. kubevirt.io/VirtualMachineInstanceMigration")
		case createDenied(c.Kind) != "":
			d.errAt(resolve(field(pn, "kind")), "action %q: %s", a.ID, createDenied(c.Kind))
		case !slices.Contains(m.Permissions.Create, c.Kind):
			d.errAt(resolve(field(pn, "kind")), "action %q: %s is not in permissions.create", a.ID, c.Kind)
		default:
			used.create[c.Kind] = true
		}
		if !c.Body.IsSet() {
			d.errAt(pn, "create.body is required")
		}
	}
	if a.Confirm != nil && !*a.Confirm {
		d.warnAt(resolve(field(an, "confirm")), "%s actions are always confirmed; confirm is ignored", kind)
	}
	insNode := resolve(field(an, "inputs"))
	names := map[string]bool{}
	for i := range a.Inputs {
		in := &a.Inputs[i]
		var inn *yaml.Node
		if insNode != nil && i < len(insNode.Content) {
			inn = resolve(insNode.Content[i])
		}
		if !identRe.MatchString(in.Name) {
			d.errAt(inn, "an input needs a name that is a CEL identifier")
		}
		if names[in.Name] {
			d.errAt(inn, "input %q is listed twice", in.Name)
		}
		names[in.Name] = true
		if !slices.Contains(inputTypes, in.InputType()) {
			d.errAt(resolve(field(inn, "type")), "input type must be one of %s", strings.Join(inputTypes, ", "))
		}
		if (in.InputType() == "enum") != (len(in.Options) > 0) {
			d.errAt(inn, "input %q: options are required for an enum, and only for an enum", in.Name)
		}
	}
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
				checkSeverity(d, f.Severity)
			}
		} else {
			d.decode(in, &b.Badges)
			for i, x := range b.Badges {
				if !x.Text.IsSet() {
					d.errAt(resolve(in.Content[i]), "a badge needs text")
				}
				checkSeverity(d, x.Severity)
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
			checkSeverity(d, c.Severity)
		}
		if b.SortBy != "" && !slices.ContainsFunc(b.Columns, func(c TableColumn) bool { return c.Name == b.SortBy }) {
			d.errAt(resolve(field(n, "sortBy")), "sortBy %q names no column", b.SortBy)
		}
	case "bar":
		need(b.Value.IsSet() && b.Max.IsSet(), "value and max")
		if b.Format != "" && !slices.Contains(barFormats, b.Format) {
			d.errAt(resolve(field(n, "format")), "format must be number, quantity or percent")
		}
	case "code":
		need(b.Value.IsSet(), "value")
		if b.Language != "" && !slices.Contains(codeLanguages, b.Language) {
			d.errAt(resolve(field(n, "language")), "language must be text, yaml, json or shell")
		}
	case "json":
		need(b.Value.IsSet(), "value")
	case "settings":
		need(b.Value.IsSet(), "value")
		if b.Limit < 0 || b.Limit > settingsRowLimit {
			d.errAt(resolve(field(n, "limit")), "limit must be between 1 and %d", settingsRowLimit)
		}
	case "message":
		need(b.Text.IsSet(), "text")
		if b.Severity != "" && !slices.Contains(messageSeverity, b.Severity) {
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

// normSeverity maps the alert and status-count synonym error to critical,
// the name the app consumes.
func normSeverity(s string) string {
	if s == "error" {
		return "critical"
	}
	return s
}
