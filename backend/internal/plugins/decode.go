package plugins

import (
	"fmt"
	"reflect"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Pos is a place in a plugin file, 1-based.
type Pos struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Col  int    `json:"col"`
}

func (p Pos) String() string { return fmt.Sprintf("%s:%d:%d", p.File, p.Line, p.Col) }

// Diag is a load, compile or evaluation problem with its place in the
// plugin's files. Snippet is the source line and Caret the column to mark.
type Diag struct {
	Pos
	Message string `json:"message"`
	Warning bool   `json:"warning,omitempty"`
	Snippet string `json:"snippet,omitempty"`
}

func (d Diag) Error() string { return d.Pos.String() + ": " + d.Message }

// Expr is a CEL expression from plugin.yaml, with where it starts so
// compile errors can point into the file.
type Expr struct {
	Src  string
	node *yaml.Node
	pos  Pos
}

// IsSet reports whether the field was given.
func (e Expr) IsSet() bool { return e.node != nil }

// decoder decodes yaml.v3 nodes into the manifest types strictly: an
// unknown field is an error at its key, a wrong type an error at its
// value. It keeps going after an error so one load reports them all.
type decoder struct {
	file  string
	lines []string
	diags []Diag
}

func (d *decoder) pos(n *yaml.Node) Pos {
	if n == nil {
		return Pos{File: d.file, Line: 1, Col: 1}
	}
	return Pos{File: d.file, Line: n.Line, Col: n.Column}
}

func (d *decoder) errAt(n *yaml.Node, format string, args ...any) {
	d.diags = append(d.diags, d.diagAt(d.pos(n), false, format, args...))
}

func (d *decoder) warnAt(n *yaml.Node, format string, args ...any) {
	d.diags = append(d.diags, d.diagAt(d.pos(n), true, format, args...))
}

func (d *decoder) diagAt(p Pos, warning bool, format string, args ...any) Diag {
	diag := Diag{Pos: p, Message: fmt.Sprintf(format, args...), Warning: warning}
	if p.Line >= 1 && p.Line <= len(d.lines) {
		diag.Snippet = d.lines[p.Line-1]
	}
	return diag
}

// nodeDecoder is implemented by types that decode themselves.
type nodeDecoder interface {
	decodeNode(d *decoder, n *yaml.Node)
}

var (
	exprType        = reflect.TypeOf(Expr{})
	nodeDecoderType = reflect.TypeOf((*nodeDecoder)(nil)).Elem()
)

func resolve(n *yaml.Node) *yaml.Node {
	for n != nil && n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	if n != nil && n.Kind == yaml.DocumentNode && len(n.Content) == 1 {
		return resolve(n.Content[0])
	}
	return n
}

func isNull(n *yaml.Node) bool { return n.Kind == yaml.ScalarNode && n.Tag == "!!null" }

// decode fills v (a pointer) from n.
func (d *decoder) decode(n *yaml.Node, v any) { d.value(n, reflect.ValueOf(v).Elem()) }

func (d *decoder) value(n *yaml.Node, v reflect.Value) {
	n = resolve(n)
	if n == nil {
		return
	}
	if v.CanAddr() && v.Addr().Type().Implements(nodeDecoderType) {
		v.Addr().Interface().(nodeDecoder).decodeNode(d, n)
		return
	}
	if v.Type() == exprType {
		if n.Kind != yaml.ScalarNode || isNull(n) {
			d.errAt(n, "expected a CEL expression (a string)")
			return
		}
		v.Set(reflect.ValueOf(Expr{Src: n.Value, node: n, pos: d.pos(n)}))
		return
	}
	switch v.Kind() {
	case reflect.Pointer:
		if isNull(n) {
			return
		}
		p := reflect.New(v.Type().Elem())
		d.value(n, p.Elem())
		v.Set(p)
	case reflect.Struct:
		d.structValue(n, v)
	case reflect.Slice:
		if isNull(n) {
			return
		}
		if n.Kind != yaml.SequenceNode {
			d.errAt(n, "expected a list")
			return
		}
		s := reflect.MakeSlice(v.Type(), len(n.Content), len(n.Content))
		for i, c := range n.Content {
			d.value(c, s.Index(i))
		}
		v.Set(s)
	case reflect.Map:
		if isNull(n) {
			return
		}
		if n.Kind != yaml.MappingNode {
			d.errAt(n, "expected a map")
			return
		}
		m := reflect.MakeMap(v.Type())
		for i := 0; i+1 < len(n.Content); i += 2 {
			k, val := resolve(n.Content[i]), n.Content[i+1]
			if k.Value == "<<" {
				d.errAt(k, "merge keys (<<) aren't supported; use an anchor for the whole value")
				continue
			}
			e := reflect.New(v.Type().Elem()).Elem()
			d.value(val, e)
			m.SetMapIndex(reflect.ValueOf(k.Value), e)
		}
		v.Set(m)
	case reflect.String:
		if n.Kind != yaml.ScalarNode {
			d.errAt(n, "expected a string")
			return
		}
		if !isNull(n) {
			v.SetString(n.Value)
		}
	case reflect.Bool:
		b, err := strconv.ParseBool(n.Value)
		if n.Kind != yaml.ScalarNode || err != nil || n.Tag != "!!bool" {
			d.errAt(n, "expected true or false")
			return
		}
		v.SetBool(b)
	case reflect.Int:
		i, err := strconv.Atoi(n.Value)
		if n.Kind != yaml.ScalarNode || err != nil {
			d.errAt(n, "expected a whole number")
			return
		}
		v.SetInt(int64(i))
	default:
		d.errAt(n, "unsupported value")
	}
}

func (d *decoder) structValue(n *yaml.Node, v reflect.Value) {
	if n.Kind != yaml.MappingNode {
		if !isNull(n) {
			d.errAt(n, "expected a map of fields")
		}
		return
	}
	t := v.Type()
	fields := map[string]int{}
	var names []string
	for i := range t.NumField() {
		tag, _, _ := strings.Cut(t.Field(i).Tag.Get("yaml"), ",")
		if tag == "" || tag == "-" {
			continue
		}
		fields[tag] = i
		names = append(names, tag)
	}
	seen := map[string]bool{}
	for i := 0; i+1 < len(n.Content); i += 2 {
		k := resolve(n.Content[i])
		idx, ok := fields[k.Value]
		if !ok {
			d.errAt(k, "unknown field %q (expected one of %s)", k.Value, strings.Join(names, ", "))
			continue
		}
		if seen[k.Value] {
			d.errAt(k, "field %q given twice", k.Value)
			continue
		}
		seen[k.Value] = true
		d.value(n.Content[i+1], v.Field(idx))
	}
	if p, ok := v.Addr().Interface().(interface{ setPos(Pos) }); ok {
		p.setPos(d.pos(n))
	}
}

// mapKeys returns the keys of mapping n in file order, with their nodes.
func mapKeys(n *yaml.Node) (keys []string, nodes map[string]*yaml.Node) {
	n = resolve(n)
	nodes = map[string]*yaml.Node{}
	if n == nil || n.Kind != yaml.MappingNode {
		return nil, nodes
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		k := resolve(n.Content[i])
		keys = append(keys, k.Value)
		nodes[k.Value] = k
	}
	return keys, nodes
}

// field returns the value node of key in mapping n (nil when absent).
func field(n *yaml.Node, key string) *yaml.Node {
	n = resolve(n)
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if resolve(n.Content[i]).Value == key {
			return n.Content[i+1]
		}
	}
	return nil
}
