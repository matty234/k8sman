package plugins

import (
	"slices"
	"sort"
	"strings"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/ast"
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
	out     *cel.Type
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

// parse parses e and finds the variables it reads (variables.<name>),
// reporting unknown ones. ok is false when e can't be used.
func (c *compiler) parse(e Expr, env *cel.Env) (*cel.Ast, []string, bool) {
	a, iss := env.Parse(e.Src)
	if iss != nil && iss.Err() != nil {
		c.issues(e, iss)
		return nil, nil, false
	}
	var vars []string
	ok := true
	native := a.NativeRep()
	info := native.SourceInfo()
	ast.PreOrderVisit(native.Expr(), ast.NewExprVisitor(func(x ast.Expr) {
		if x.Kind() != ast.SelectKind {
			return
		}
		s := x.AsSelect()
		if op := s.Operand(); op.Kind() == ast.IdentKind && op.AsIdent() == varVariables {
			name := s.FieldName()
			if !c.known[name] {
				loc := info.GetStartLocation(x.ID())
				line, col := loc.Line(), loc.Column()
				if line <= 0 {
					line, col = 1, 0
				}
				c.errAt(e, line, col, "undeclared variable variables."+name)
				ok = false
			} else if !slices.Contains(vars, name) {
				vars = append(vars, name)
			}
		}
	}))
	return a, vars, ok
}

func (c *compiler) issues(e Expr, iss *cel.Issues) {
	for _, err := range iss.Errors() {
		line, col := 1, 0
		if err.Location != nil && err.Location.Line() > 0 {
			line, col = err.Location.Line(), err.Location.Column()
		}
		c.errAt(e, line, col, err.Message)
	}
}

// compile compiles e. want, when set, is the result type required (dyn
// passes). Returns nil when e is unset or failed.
func (c *compiler) compile(e Expr, env *cel.Env, want *cel.Type, limit uint64) *program {
	if !e.IsSet() {
		return nil
	}
	parsed, vars, ok := c.parse(e, env)
	if !ok {
		return nil
	}
	a, iss := env.Check(parsed)
	if iss != nil && iss.Err() != nil {
		c.issues(e, iss)
		return nil
	}
	out := a.OutputType()
	if want != nil && !out.IsAssignableType(want) && out != cel.DynType {
		c.errAt(e, 1, 0, "expected a "+want.String()+", but this is a "+out.String())
		return nil
	}
	p := &program{expr: e, vars: vars, out: out}
	ast.PreOrderVisit(a.NativeRep().Expr(), ast.NewExprVisitor(func(x ast.Expr) {
		if x.Kind() == ast.IdentKind && x.AsIdent() == varNow {
			p.usesNow = true
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

// compileVars compiles the kind's variables in dependency order: each is
// declared to the next as `variables.<name>` with its checked type, so
// `variables.notAfter.value()` type-checks as precisely as the
// expression it names. Returns the environment with all of them.
func (c *compiler) compileVars(kp *kindProgs, k *Kind) *cel.Env {
	names := make([]string, 0, len(k.Variables))
	for name := range k.Variables {
		names = append(names, name)
	}
	sort.Strings(names)
	deps := map[string][]string{}
	for _, name := range names {
		if _, vars, ok := c.parse(k.Variables[name], c.base); ok {
			deps[name] = vars
		}
	}
	const (
		white = iota
		grey
		black
	)
	color := map[string]int{}
	var order []string
	var visit func(n string, path []string) bool
	visit = func(n string, path []string) bool {
		switch color[n] {
		case grey:
			c.errAt(k.Variables[n], 1, 0, "variables."+n+" refers to itself (through "+strings.Join(append(path, n), " → ")+")")
			return false
		case black:
			return true
		}
		color[n] = grey
		good := true
		for _, m := range deps[n] {
			if !visit(m, append(path, n)) {
				good = false
			}
		}
		color[n] = black
		if good {
			order = append(order, n)
		}
		return good
	}
	for _, n := range names {
		visit(n, nil)
	}
	env := c.base
	declared := map[string]bool{}
	for _, n := range order {
		if !slices.ContainsFunc(deps[n], func(d string) bool { return !declared[d] }) {
			if p := c.compile(k.Variables[n], env, nil, panelCostLimit); p != nil {
				kp.vars[n] = p
				if next, err := env.Extend(cel.Variable(varVariables+"."+n, p.out)); err == nil {
					env = next
					declared[n] = true
					continue
				}
			}
		}
		// Failed (or depends on one that failed): stays declared as dyn
		// so later expressions report their own problems only.
		if next, err := env.Extend(cel.Variable(varVariables+"."+n, cel.DynType)); err == nil {
			env = next
		}
	}
	for _, n := range names {
		if color[n] == black && !slices.Contains(order, n) {
			if next, err := env.Extend(cel.Variable(varVariables+"."+n, cel.DynType)); err == nil {
				env = next
			}
		}
	}
	return env
}

// compileKind compiles every expression of kind entry k. Errors leave the
// entry unusable (activation is atomic per kind entry).
func compileKind(d *decoder, key string, k *Kind) (*kindProgs, []Diag) {
	base, _, err := envs()
	if err != nil {
		return nil, []Diag{d.diagAt(k.pos, false, "CEL environment: %v", err)}
	}
	c := &compiler{d: d, base: base, known: map[string]bool{}}
	for name := range k.Variables {
		c.known[name] = true
	}
	kp := &kindProgs{key: key, kind: k, vars: map[string]*program{}}
	env := c.compileVars(kp, k)
	c.base = env
	if c.row, err = env.Extend(cel.Variable(varRow, cel.DynType)); err != nil {
		return nil, []Diag{d.diagAt(k.pos, false, "CEL environment: %v", err)}
	}
	for i := range k.Columns {
		col := &k.Columns[i]
		p := c.compile(col.Value, env, nil, columnCostLimit)
		if p != nil {
			p.usesNow = kp.readsNow(p, nil)
			kp.columns = append(kp.columns, colProg{col: col, prog: p})
		}
	}
	if k.Panel != nil {
		for i := range k.Panel.Sections {
			s := &k.Panel.Sections[i]
			sp := secProg{sec: s, when: c.compile(s.When, env, cel.BoolType, panelCostLimit)}
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
		kp.actions = append(kp.actions, actProg{a: a, when: c.compile(a.When, env, cel.BoolType, actionCostLimit)})
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
