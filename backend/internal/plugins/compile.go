package plugins

import (
	"slices"
	"sort"
	"strings"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/ast"
	"github.com/google/cel-go/common/types"
)

// Cost limits per evaluation (docs/PLUGINS.md §8).
const (
	columnCostLimit = 100_000
	panelCostLimit  = 1_000_000
	panelTotalCost  = 5_000_000
	actionCostLimit = 1_000_000
)

// program is one compiled expression.
type program struct {
	prg  cel.Program
	expr Expr
	// usesNow is true when the expression (or a variable it reads) reads
	// `now`.
	usesNow bool
	vars    []string
}

// kindProgs is one kind entry of a plugin, compiled.
type kindProgs struct {
	key      string
	kind     *Kind
	vars     map[string]*program
	columns  []colProg
	sections []secProg
	actions  []actProg
}

type colProg struct {
	col  *Column
	prog *program
}

type secProg struct {
	sec    *Section
	when   *program
	blocks []blockProg
}

type blockProg struct {
	b    *Block
	when *program
	// progs holds the block's expressions by role: "items", "from",
	// "rows", "value", "max", "text"; fields and badges by index
	// ("0.value", "0.link", "0.when", "0.text", "0.severity"); table
	// columns as "col.0.value", "col.0.link".
	progs map[string]*program
}

type actProg struct {
	a    *Action
	when *program
}

// compiler compiles a kind entry's expressions, collecting diags with
// file positions.
type compiler struct {
	d     *decoder
	base  *cel.Env
	row   *cel.Env
	diags []Diag
	known map[string]bool // variable names of the kind entry
}

func (c *compiler) errAt(e Expr, line, col int, msg string) {
	c.diags = append(c.diags, c.d.diagAt(c.d.exprPos(e, line, col), false, "%s", msg))
}

// compile compiles e. want, when set, is the result type required (dyn
// and optionals of it pass). Returns nil when e is unset or failed.
func (c *compiler) compile(e Expr, env *cel.Env, want *cel.Type, limit uint64) *program {
	if !e.IsSet() {
		return nil
	}
	a, iss := env.Compile(e.Src)
	if iss != nil && iss.Err() != nil {
		for _, err := range iss.Errors() {
			line, col := 1, 0
			if err.Location != nil && err.Location.Line() > 0 {
				line, col = err.Location.Line(), err.Location.Column()
			}
			c.errAt(e, line, col, err.Message)
		}
		return nil
	}
	if want != nil {
		out := a.OutputType()
		if !out.IsAssignableType(want) && out != cel.DynType && !(out.Kind() == types.OpaqueKind && out.TypeName() == "optional_type") {
			c.errAt(e, 1, 0, "expected a "+want.String()+", but this is a "+out.String())
			return nil
		}
	}
	p := &program{expr: e}
	native := a.NativeRep()
	info := native.SourceInfo()
	ast.PreOrderVisit(native.Expr(), ast.NewExprVisitor(func(x ast.Expr) {
		switch x.Kind() {
		case ast.IdentKind:
			if x.AsIdent() == varNow {
				p.usesNow = true
			}
		case ast.SelectKind:
			s := x.AsSelect()
			if op := s.Operand(); op.Kind() == ast.IdentKind && op.AsIdent() == varVariables {
				c.useVar(p, e, info.GetStartLocation(x.ID()).Line(), info.GetStartLocation(x.ID()).Column(), s.FieldName())
			}
		case ast.CallKind:
			call := x.AsCall()
			if call.FunctionName() == "_?._" && len(call.Args()) == 2 {
				if op := call.Args()[0]; op.Kind() == ast.IdentKind && op.AsIdent() == varVariables {
					if lit := call.Args()[1]; lit.Kind() == ast.LiteralKind {
						if s, ok := lit.AsLiteral().Value().(string); ok {
							loc := info.GetStartLocation(x.ID())
							c.useVar(p, e, loc.Line(), loc.Column(), s)
						}
					}
				}
			}
		}
	}))
	prg, err := env.Program(a, cel.CostLimit(limit), cel.EvalOptions(cel.OptOptimize), cel.InterruptCheckFrequency(100))
	if err != nil {
		c.errAt(e, 1, 0, err.Error())
		return nil
	}
	p.prg = prg
	return p
}

func (c *compiler) useVar(p *program, e Expr, line, col int, name string) {
	if line <= 0 {
		line, col = 1, 0
	}
	if !c.known[name] {
		c.errAt(e, line, col, "undeclared variable variables."+name)
		return
	}
	if !slices.Contains(p.vars, name) {
		p.vars = append(p.vars, name)
	}
}

// compileKind compiles every expression of kind entry k. Errors leave the
// entry unusable (activation is atomic per kind entry).
func compileKind(d *decoder, key string, k *Kind) (*kindProgs, []Diag) {
	base, row, err := envs()
	if err != nil {
		return nil, []Diag{d.diagAt(k.pos, false, "CEL environment: %v", err)}
	}
	c := &compiler{d: d, base: base, row: row, known: map[string]bool{}}
	for name := range k.Variables {
		c.known[name] = true
	}
	kp := &kindProgs{key: key, kind: k, vars: map[string]*program{}}
	names := make([]string, 0, len(k.Variables))
	for name := range k.Variables {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if p := c.compile(k.Variables[name], base, nil, panelCostLimit); p != nil {
			kp.vars[name] = p
		}
	}
	c.checkCycles(kp, k)
	for i := range k.Columns {
		col := &k.Columns[i]
		p := c.compile(col.Value, base, nil, columnCostLimit)
		if p != nil {
			p.usesNow = kp.readsNow(p, nil)
			kp.columns = append(kp.columns, colProg{col: col, prog: p})
		}
	}
	if k.Panel != nil {
		for i := range k.Panel.Sections {
			s := &k.Panel.Sections[i]
			sp := secProg{sec: s, when: c.compile(s.When, base, cel.BoolType, panelCostLimit)}
			for j := range s.Blocks {
				sp.blocks = append(sp.blocks, c.compileBlock(&s.Blocks[j]))
			}
			kp.sections = append(kp.sections, sp)
		}
	}
	for i := range k.Actions {
		a := &k.Actions[i]
		if a.Shell == nil {
			continue
		}
		kp.actions = append(kp.actions, actProg{a: a, when: c.compile(a.When, base, cel.BoolType, actionCostLimit)})
	}
	return kp, c.diags
}

func (c *compiler) compileBlock(b *Block) blockProg {
	bp := blockProg{b: b, when: c.compile(b.When, c.base, cel.BoolType, panelCostLimit), progs: map[string]*program{}}
	set := func(role string, e Expr, env *cel.Env, want *cel.Type) {
		if p := c.compile(e, env, want, panelCostLimit); p != nil {
			bp.progs[role] = p
		}
	}
	switch b.Type {
	case "fields":
		for i, f := range b.Fields {
			set(itoa(i)+".value", f.Value, c.base, nil)
			set(itoa(i)+".link", f.Link, c.base, nil)
			set(itoa(i)+".when", f.When, c.base, cel.BoolType)
		}
	case "badges":
		for i, x := range b.Badges {
			set(itoa(i)+".text", x.Text, c.base, nil)
			set(itoa(i)+".severity", x.Severity, c.base, nil)
			set(itoa(i)+".when", x.When, c.base, cel.BoolType)
		}
	case "chips", "links":
		if b.Items.node != nil {
			n := resolve(b.Items.node)
			set("items", Expr{Src: n.Value, node: n, pos: c.d.pos(n)}, c.base, nil)
		}
	case "conditions":
		set("from", b.From, c.base, nil)
	case "table":
		set("rows", b.Rows, c.base, nil)
		for i, col := range b.Columns {
			set("col."+itoa(i)+".value", col.Value, c.row, nil)
			set("col."+itoa(i)+".link", col.Link, c.row, nil)
		}
	case "bar":
		set("value", b.Value, c.base, nil)
		set("max", b.Max, c.base, nil)
	case "code", "json":
		set("value", b.Value, c.base, nil)
	case "message":
		set("text", b.Text, c.base, nil)
	}
	return bp
}

// checkCycles reports variables that refer to themselves, directly or
// through others, and drops them.
func (c *compiler) checkCycles(kp *kindProgs, k *Kind) {
	const (
		white = iota
		grey
		black
	)
	color := map[string]int{}
	var bad []string
	var visit func(n string) bool
	visit = func(n string) bool {
		switch color[n] {
		case grey:
			return true
		case black:
			return false
		}
		color[n] = grey
		cyc := false
		if p := kp.vars[n]; p != nil {
			for _, m := range p.vars {
				if visit(m) {
					cyc = true
				}
			}
		}
		color[n] = black
		if cyc {
			bad = append(bad, n)
		}
		return cyc
	}
	names := make([]string, 0, len(kp.vars))
	for n := range kp.vars {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		visit(n)
	}
	for _, n := range bad {
		c.errAt(k.Variables[n], 1, 0, "variables."+n+" refers to itself (through "+strings.Join(kp.vars[n].vars, ", ")+")")
		delete(kp.vars, n)
	}
}

// readsNow is whether p reads `now`, directly or through variables.
func (kp *kindProgs) readsNow(p *program, seen map[string]bool) bool {
	if p.usesNow {
		return true
	}
	if seen == nil {
		seen = map[string]bool{}
	}
	for _, v := range p.vars {
		if seen[v] {
			continue
		}
		seen[v] = true
		if vp := kp.vars[v]; vp != nil && kp.readsNow(vp, seen) {
			return true
		}
	}
	return false
}

func itoa(i int) string {
	const digits = "0123456789"
	if i < 10 {
		return digits[i : i+1]
	}
	return itoa(i/10) + digits[i%10:i%10+1]
}
