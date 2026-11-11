package plugins

import (
	"slices"
	"sort"
	"strings"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/ast"
	"github.com/google/cel-go/common/operators"
	"github.com/google/cel-go/common/types"
)

// Cost limits per evaluation (docs/PLUGINS.md §8).
const (
	columnCostLimit = 100_000
	alertCostLimit  = 100_000
	panelCostLimit  = 1_000_000
	panelTotalCost  = 5_000_000
	actionCostLimit = 1_000_000
)

// refSet is which names of a map variable (related, metrics) an
// expression reads; all when it uses the map as a whole.
type refSet struct {
	all   bool
	names []string
}

func (r *refSet) add(o refSet) {
	r.all = r.all || o.all
	for _, n := range o.names {
		if !slices.Contains(r.names, n) {
			r.names = append(r.names, n)
		}
	}
}

func (r refSet) has(name string) bool { return r.all || slices.Contains(r.names, name) }
func (r refSet) empty() bool          { return !r.all && len(r.names) == 0 }

// program is one compiled expression.
type program struct {
	prg  cel.Program
	expr Expr
	// usesNow is true when the expression itself reads `now`.
	usesNow bool
	// vars are the variables it reads; related and metrics the names of
	// those it reads directly (see kindProgs.refs for the transitive ones).
	vars    []string
	related refSet
	metrics refSet
	out     *cel.Type
	// usesRow is true when the expression reads the deprecated alias `row`.
	usesRow bool
}

// kindProgs is one kind entry of a plugin, compiled.
type kindProgs struct {
	key      string
	kind     *Kind
	vars     map[string]*program
	related  []relProg // by name
	metrics  []metricProg
	columns  []colProg
	sections []secProg
	tabs     []tabProg
	actions  []actProg
	alerts   []alertProg
	status   []statusProg
	// panelNeeds and actionNeeds are the related objects (and, for
	// panels, metrics) their expressions read, so only those are looked up.
	panelRelated, panelMetrics, actionRelated refSet
	// panelNow is whether any panel expression reads `now`.
	panelNow bool
	// alertMemo reuses alert results per object version (alerts.go).
	alertMemo alertMemo
}

type colProg struct {
	col  *Column
	prog *program
}

type secProg struct {
	sec           *Section
	when, summary *program
	// badge is the header badge's text, severity and when.
	badgeText, badgeSeverity, badgeWhen *program
	blocks                              []blockProg
}

type tabProg struct {
	tab      *Tab
	when     *program
	sections []secProg
}

type blockProg struct {
	b    *Block
	when *program
	// progs holds the block's expressions by role: "items", "from",
	// "rows", "value", "max", "text"; fields and badges by index
	// ("0.value", "0.link", "0.when", "0.text", "0.severity"); table
	// columns as "col.0.value", "col.0.link", "col.0.severity".
	progs map[string]*program
}

type actProg struct {
	a    *Action
	when *program
	// body and inputs are a patch, subresource or create action's.
	body   *program
	inputs []inputProg
}

type inputProg struct {
	in       *Input
	def      *program
	validate *program
}

type relProg struct {
	name                       string
	rel                        *Related
	when, nameP, selector, nsP *program
	// filter sees `item`, each candidate.
	filter *program
}

type metricProg struct {
	name   string
	metric *Metric
	query  *program
}

type alertProg struct {
	a                    *Alert
	when, message, since *program
}

type statusProg struct {
	c    *StatusCount
	when *program
}

// compiler compiles a kind entry's expressions, collecting diags with
// file positions.
type compiler struct {
	d     *decoder
	base  *cel.Env
	row   *cel.Env
	item  *cel.Env
	input *cel.Env
	diags []Diag
	known map[string]bool // variable names of the kind entry
	kp    *kindProgs
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

// scanRefs finds which names of map variable ident expression x reads:
// ident.name, ident.?name, has(ident.name), ident["name"] and
// ident[?"name"]; any other use reads all of it.
func scanRefs(x ast.Expr, ident string) refSet {
	var out refSet
	idents, named := 0, 0
	isIdent := func(e ast.Expr) bool { return e.Kind() == ast.IdentKind && e.AsIdent() == ident }
	ast.PreOrderVisit(x, ast.NewExprVisitor(func(e ast.Expr) {
		switch e.Kind() {
		case ast.IdentKind:
			if e.AsIdent() == ident {
				idents++
			}
		case ast.SelectKind:
			if s := e.AsSelect(); isIdent(s.Operand()) {
				named++
				out.add(refSet{names: []string{s.FieldName()}})
			}
		case ast.CallKind:
			call := e.AsCall()
			fn := call.FunctionName()
			if fn != operators.OptSelect && fn != operators.Index && fn != operators.OptIndex {
				return
			}
			args := call.Args()
			if len(args) != 2 || !isIdent(args[0]) || args[1].Kind() != ast.LiteralKind {
				return
			}
			if s, ok := args[1].AsLiteral().(types.String); ok {
				named++
				out.add(refSet{names: []string{string(s)}})
			}
		}
	}))
	if idents > named {
		out.all = true
	}
	return out
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
	root := parsed.NativeRep().Expr()
	p := &program{expr: e, vars: vars, out: out, related: scanRefs(root, varRelated), metrics: scanRefs(root, varMetrics)}
	ast.PreOrderVisit(a.NativeRep().Expr(), ast.NewExprVisitor(func(x ast.Expr) {
		if x.Kind() == ast.IdentKind && x.AsIdent() == varNow {
			p.usesNow = true
		}
		if x.Kind() == ast.IdentKind && x.AsIdent() == varRow {
			p.usesRow = true
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

// restrict compiles e for a place where related and metrics (and, with
// noNow, `now`) aren't available, reporting a use at e (also through
// variables). where names the place in the message.
func (c *compiler) restrict(e Expr, env *cel.Env, want *cel.Type, limit uint64, where string, allowRelated, allowMetrics, noNow bool) *program {
	p := c.compile(e, env, want, limit)
	if p == nil {
		return nil
	}
	rel, met, now := c.kp.refs(p)
	bad := ""
	switch {
	case !allowRelated && !rel.empty():
		bad = "related"
	case !allowMetrics && !met.empty():
		bad = "metrics"
	case noNow && now:
		bad = "now"
	}
	if bad == "" {
		return p
	}
	msg := bad + " isn't available in " + where
	if bad == "now" {
		msg += " (it would change the lookup on every evaluation)"
	} else if bad == varRelated {
		msg += " (only in panels and actions)"
	} else {
		msg += " (only in panels)"
	}
	if !directly(p, bad) {
		msg += "; a variable it reads uses " + bad
	}
	c.errAt(e, 1, 0, msg)
	return nil
}

func directly(p *program, what string) bool {
	switch what {
	case varRelated:
		return !p.related.empty()
	case varMetrics:
		return !p.metrics.empty()
	}
	return p.usesNow
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
	base, err := envs()
	if err != nil {
		return nil, []Diag{d.diagAt(k.pos, false, "CEL environment: %v", err)}
	}
	kp := &kindProgs{key: key, kind: k, vars: map[string]*program{}}
	c := &compiler{d: d, base: base, known: map[string]bool{}, kp: kp}
	for name := range k.Variables {
		c.known[name] = true
	}
	env := c.compileVars(kp, k)
	c.base = env
	if c.row, err = env.Extend(cel.Variable(varItem, cel.DynType), cel.Variable(varRow, cel.DynType)); err == nil {
		if c.input, err = env.Extend(cel.Variable(varInput, cel.MapType(cel.StringType, cel.DynType))); err == nil {
			c.item, err = env.Extend(cel.Variable(varItem, cel.MapType(cel.StringType, cel.DynType)))
		}
	}
	if err != nil {
		return nil, []Diag{d.diagAt(k.pos, false, "CEL environment: %v", err)}
	}
	for _, name := range sortedKeys(k.Related) {
		r := k.Related[name]
		rp := relProg{name: name, rel: &r}
		lookup := func(e Expr, env *cel.Env, want *cel.Type, limit uint64) *program {
			return c.restrict(e, env, want, limit, "related lookups", false, false, true)
		}
		rp.when = lookup(r.When, env, cel.BoolType, panelCostLimit)
		rp.nameP = lookup(r.Name, env, cel.StringType, panelCostLimit)
		rp.selector = lookup(r.Selector, env, nil, panelCostLimit)
		rp.nsP = lookup(r.Namespace, env, cel.StringType, panelCostLimit)
		// Once per candidate: a cell's budget.
		rp.filter = lookup(r.Filter, c.item, cel.BoolType, columnCostLimit)
		kp.related = append(kp.related, rp)
	}
	for _, name := range sortedKeys(k.Metrics) {
		m := k.Metrics[name]
		kp.metrics = append(kp.metrics, metricProg{name: name, metric: &m,
			query: c.restrict(m.Query, env, cel.StringType, panelCostLimit, "metric queries", false, false, true)})
	}
	for i := range k.Columns {
		col := &k.Columns[i]
		if p := c.restrict(col.Value, env, nil, columnCostLimit, "columns", false, false, false); p != nil {
			p.usesNow = kp.readsNow(p, nil)
			kp.columns = append(kp.columns, colProg{col: col, prog: p})
		}
	}
	if k.Panel != nil {
		kp.sections = c.compileSections(k.Panel.Sections)
		for i := range k.Panel.Tabs {
			t := &k.Panel.Tabs[i]
			kp.tabs = append(kp.tabs, tabProg{tab: t, when: c.compile(t.When, env, cel.BoolType, panelCostLimit), sections: c.compileSections(t.Sections)})
		}
	}
	for i := range k.Actions {
		a := &k.Actions[i]
		act := func(e Expr, env *cel.Env, want *cel.Type) *program {
			return c.restrict(e, env, want, actionCostLimit, "actions", true, false, false)
		}
		ap := actProg{a: a, when: act(a.When, env, cel.BoolType)}
		if a.Writes() {
			switch {
			case a.Patch != nil:
				ap.body = act(a.Patch.Body, c.input, nil)
			case a.Subresource != nil:
				ap.body = act(a.Subresource.Body, c.input, nil)
			case a.Create != nil:
				ap.body = act(a.Create.Body, c.input, nil)
			}
			for j := range a.Inputs {
				in := &a.Inputs[j]
				ap.inputs = append(ap.inputs, inputProg{in: in, def: act(in.Default, env, nil), validate: act(in.Validate, c.input, cel.BoolType)})
			}
		}
		kp.actions = append(kp.actions, ap)
	}
	for i := range k.Alerts {
		a := &k.Alerts[i]
		al := func(e Expr, want *cel.Type) *program {
			return c.restrict(e, env, want, alertCostLimit, "alerts", false, false, false)
		}
		kp.alerts = append(kp.alerts, alertProg{a: a, when: al(a.When, cel.BoolType), message: al(a.Message, nil), since: al(a.Since, nil)})
	}
	if k.Status != nil {
		for i := range k.Status.Counts {
			sc := &k.Status.Counts[i]
			kp.status = append(kp.status, statusProg{c: sc,
				when: c.restrict(sc.When, env, cel.BoolType, alertCostLimit, "status counts", false, false, false)})
		}
	}
	kp.needs()
	return kp, c.diags
}

// compileSections compiles the sections of a panel or a tab.
func (c *compiler) compileSections(secs []Section) []secProg {
	var out []secProg
	for i := range secs {
		s := &secs[i]
		sp := secProg{sec: s, when: c.compile(s.When, c.base, cel.BoolType, panelCostLimit), summary: c.compile(s.Summary, c.base, nil, panelCostLimit)}
		if b := s.Badge; b != nil {
			sp.badgeText = c.compile(b.Text, c.base, nil, panelCostLimit)
			sp.badgeSeverity = c.compile(b.Severity, c.base, nil, panelCostLimit)
			sp.badgeWhen = c.compile(b.When, c.base, cel.BoolType, panelCostLimit)
		}
		for j := range s.Blocks {
			sp.blocks = append(sp.blocks, c.compileBlock(&s.Blocks[j]))
		}
		out = append(out, sp)
	}
	return out
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// needs works out which related objects and metrics panels and actions
// read, so a render looks up only those.
func (kp *kindProgs) needs() {
	panel := func(p *program) {
		if p == nil {
			return
		}
		rel, met, now := kp.refs(p)
		kp.panelRelated.add(rel)
		kp.panelMetrics.add(met)
		kp.panelNow = kp.panelNow || now
	}
	sections := func(secs []secProg) {
		for _, sp := range secs {
			for _, p := range []*program{sp.when, sp.summary, sp.badgeText, sp.badgeSeverity, sp.badgeWhen} {
				panel(p)
			}
			for _, bp := range sp.blocks {
				panel(bp.when)
				for _, p := range bp.progs {
					panel(p)
				}
			}
		}
	}
	sections(kp.sections)
	for _, tp := range kp.tabs {
		panel(tp.when)
		sections(tp.sections)
	}
	for _, ap := range kp.actions {
		for _, p := range []*program{ap.when, ap.body} {
			if p != nil {
				rel, _, _ := kp.refs(p)
				kp.actionRelated.add(rel)
			}
		}
		for _, ip := range ap.inputs {
			for _, p := range []*program{ip.def, ip.validate} {
				if p != nil {
					rel, _, _ := kp.refs(p)
					kp.actionRelated.add(rel)
				}
			}
		}
	}
}

// refs is what p reads of related and metrics, and whether it reads now,
// directly or through variables.
func (kp *kindProgs) refs(p *program) (rel, met refSet, now bool) {
	seen := map[string]bool{}
	var walk func(p *program)
	walk = func(p *program) {
		rel.add(p.related)
		met.add(p.metrics)
		now = now || p.usesNow
		for _, v := range p.vars {
			if seen[v] {
				continue
			}
			seen[v] = true
			if vp := kp.vars[v]; vp != nil {
				walk(vp)
			}
		}
	}
	walk(p)
	return rel, met, now
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
			set(itoa(i)+".severity", f.Severity, c.base, nil)
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
			set("col."+itoa(i)+".severity", col.Severity, c.row, nil)
			for _, role := range []string{"value", "link", "severity"} {
				if p := bp.progs["col."+itoa(i)+"."+role]; p != nil && p.usesRow {
					c.diags = append(c.diags, c.d.diagAt(c.d.exprPos(p.expr, 1, 0), true, "`row` is deprecated: use `item` (the element being evaluated)"))
				}
			}
		}
	case "bar":
		set("value", b.Value, c.base, nil)
		set("max", b.Max, c.base, nil)
	case "code", "json", "settings":
		set("value", b.Value, c.base, nil)
	case "message":
		set("text", b.Text, c.base, nil)
		set("title", b.Title, c.base, nil)
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

// readsK8sman is whether p's source mentions k8sman, directly or through
// variables.
func (kp *kindProgs) readsK8sman(p *program, seen map[string]bool) bool {
	if strings.Contains(p.expr.Src, "k8sman") {
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
		if vp := kp.vars[v]; vp != nil && kp.readsK8sman(vp, seen) {
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
