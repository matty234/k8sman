package plugins

import (
	"cmp"
	"errors"
	"io"
	"io/fs"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Templates: a kind's `templates` are starting points for the resource
// editor's create mode, listed next to the app's own. Each is YAML (one or
// more documents) whose first document creates the kind; the others may be
// any kind (a Secret skeleton for an issuer, say). Templates are text the
// user edits and creates themselves, so they need no permissions and don't
// change the permissions hash.
//
// Placeholders: ${name} or ${name:default}, name being a letter or _ and
// then letters, digits, _ and -. The editor replaces ${namespace} with the
// namespace it creates in, and the user fills the others (Tab goes to the
// next one). Anything else, `${1}` or `${ x }` say, is plain text.

// Template is one template of a kind.
type Template struct {
	Name        string `yaml:"name"`
	Description string `yaml:"description"`
	YAML        string `yaml:"yaml"`
}

const (
	templateMaxBytes   = 16 << 10
	templateMaxPerKind = 20
)

// PlaceholderRe matches a template placeholder: ${name} or ${name:default}.
var PlaceholderRe = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_-]*)(?::([^}\n]*))?\}`)

var yamlErrLineRe = regexp.MustCompile(`line (\d+)`)

// validateTemplates checks kind key's templates; n is the kind's node.
func validateTemplates(d *decoder, key string, k *Kind, n *yaml.Node) {
	if len(k.Templates) == 0 {
		return
	}
	tn := resolve(field(n, "templates"))
	if len(k.Templates) > templateMaxPerKind {
		d.errAt(tn, "%s has %d templates; at most %d per kind", key, len(k.Templates), templateMaxPerKind)
	}
	names := map[string]bool{}
	for i := range k.Templates {
		t := &k.Templates[i]
		var en *yaml.Node
		if tn != nil && i < len(tn.Content) {
			en = resolve(tn.Content[i])
		}
		switch {
		case t.Name == "":
			d.errAt(orNode(en, tn), "a template needs a name")
		case names[t.Name]:
			d.errAt(orNode(resolve(field(en, "name")), en), "template %q is listed twice", t.Name)
		}
		names[t.Name] = true
		yn := resolve(field(en, "yaml"))
		switch {
		case strings.TrimSpace(t.YAML) == "":
			d.errAt(orNode(yn, en), "template %q needs yaml", t.Name)
		case len(t.YAML) > templateMaxBytes:
			d.errAt(yn, "template %q is %d bytes; at most 16 KiB", t.Name, len(t.YAML))
		default:
			checkTemplateYAML(d, key, t, yn)
		}
	}
}

// checkTemplateYAML parses template t (placeholders and all): every
// document needs apiVersion and kind, and the first one creates kind key.
func checkTemplateYAML(d *decoder, key string, t *Template, yn *yaml.Node) {
	at := func(line, col int) Pos { return d.templatePos(yn, line, col) }
	fail := func(p Pos, format string, args ...any) {
		d.diags = append(d.diags, d.diagAt(p, false, "template %q: "+format, append([]any{t.Name}, args...)...))
	}
	dec := yaml.NewDecoder(strings.NewReader(t.YAML))
	docs := 0
	for {
		var doc yaml.Node
		err := dec.Decode(&doc)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			line := 1
			if m := yamlErrLineRe.FindStringSubmatch(err.Error()); m != nil {
				line, _ = strconv.Atoi(m[1])
			}
			fail(at(line, 1), "%s", strings.TrimPrefix(err.Error(), "yaml: "))
			return
		}
		if len(doc.Content) == 0 {
			continue // an empty document between ---
		}
		root := resolve(&doc)
		if root.Kind == yaml.ScalarNode && isNull(root) {
			continue
		}
		docs++
		if root.Kind != yaml.MappingNode {
			fail(at(root.Line, root.Column), "document %d is not a map", docs)
			continue
		}
		av, kind := resolve(field(root, "apiVersion")), resolve(field(root, "kind"))
		if av == nil || kind == nil || av.Value == "" || kind.Value == "" {
			fail(at(root.Line, root.Column), "document %d needs apiVersion and kind", docs)
			continue
		}
		if docs == 1 {
			group, _, ok := strings.Cut(av.Value, "/")
			if !ok {
				group = "" // v1: the core group
			}
			if got := group + "/" + kind.Value; got != key {
				fail(at(kind.Line, kind.Column), "the first document creates %s (apiVersion %s, kind %s), not %s", got, av.Value, kind.Value, key)
			}
		}
	}
	if docs == 0 {
		fail(d.pos(yn), "no documents")
		return
	}
	// `${` that isn't a placeholder stays as it is: say so, in case it's a typo.
	ok := map[int]bool{}
	for _, m := range PlaceholderRe.FindAllStringIndex(t.YAML, -1) {
		ok[m[0]] = true
	}
	for i := 0; ; {
		j := strings.Index(t.YAML[i:], "${")
		if j < 0 {
			break
		}
		i += j
		if !ok[i] {
			line := strings.Count(t.YAML[:i], "\n") + 1
			col := i - strings.LastIndex(t.YAML[:i], "\n")
			d.diags = append(d.diags, d.diagAt(at(line, col), true, "template %q: %q isn't a placeholder (${name} or ${name:default}) and stays as written", t.Name, placeholderStart(t.YAML[i:])))
		}
		i += 2
	}
}

func placeholderStart(s string) string {
	if e := strings.IndexAny(s, "}\n"); e >= 0 {
		return strings.TrimSpace(s[:e+1])
	}
	return s
}

// templatePos is where line and col (1-based) of a template's text are in
// plugin.yaml: exact for a block scalar (yaml: |), else the value's start.
func (d *decoder) templatePos(yn *yaml.Node, line, col int) Pos {
	if yn == nil || yn.Style&(yaml.LiteralStyle|yaml.FoldedStyle) == 0 {
		return d.pos(yn)
	}
	fl := yn.Line + line
	if fl-1 < len(d.lines) {
		src := d.lines[fl-1]
		col += len(src) - len(strings.TrimLeft(src, " "))
	}
	return Pos{File: d.file, Line: fl, Col: col}
}

// TemplateOut is a template of an active plugin
// (GET /api/plugins/templates).
type TemplateOut struct {
	Plugin     string `json:"plugin"`
	PluginName string `json:"pluginName"`
	// Icon is the kind's icon name (or the plugin's first kind icon);
	// HasIcon says the plugin has an icon.png.
	Icon        string `json:"icon,omitempty"`
	HasIcon     bool   `json:"hasIcon,omitempty"`
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	YAML        string `json:"yaml"`
}

// Templates lists the active plugins' templates for kind key kind (every
// kind when ""), by plugin name, then in file order.
func (h *Host) Templates(kind string) []TemplateOut {
	out := []TemplateOut{}
	for _, p := range h.active() {
		m := p.m
		_, err := fs.Stat(p.fsys, "icon.png")
		var first string
		for _, key := range m.KindOrder {
			if ic := m.Kinds[key].Icon; ic != "" && first == "" {
				first = ic
			}
		}
		for _, key := range m.KindOrder {
			k := m.Kinds[key]
			if kind != "" && key != kind || k == nil {
				continue
			}
			for _, t := range k.Templates {
				out = append(out, TemplateOut{Plugin: m.ID, PluginName: m.Name, Icon: cmp.Or(k.Icon, first), HasIcon: err == nil,
					Kind: key, Name: t.Name, Description: t.Description, YAML: t.YAML})
			}
		}
	}
	slices.SortStableFunc(out, func(a, b TemplateOut) int { return strings.Compare(a.PluginName, b.PluginName) })
	return out
}
