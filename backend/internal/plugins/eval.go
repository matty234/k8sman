package plugins

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/cel-go/common/types"
)

// panelTimeout bounds one panel render (docs/PLUGINS.md §8).
const panelTimeout = 250 * time.Millisecond

// tableRowLimit caps the rows a table block evaluates.
const tableRowLimit = 500

// prepareObject is what plugins see of obj: Secrets have every data and
// stringData value replaced with "" and the last-applied annotation
// dropped (it holds the data too). Other objects are passed as they are:
// CEL never writes to its input, so shared cache objects need no copy.
func prepareObject(kindKey string, obj map[string]any) map[string]any {
	if kindKey != "/Secret" {
		return obj
	}
	out := make(map[string]any, len(obj))
	for k, v := range obj {
		out[k] = v
	}
	for _, f := range []string{"data", "stringData"} {
		if m, ok := obj[f].(map[string]any); ok {
			blank := make(map[string]any, len(m))
			for k := range m {
				blank[k] = ""
			}
			out[f] = blank
		}
	}
	if md, ok := obj["metadata"].(map[string]any); ok {
		if ann, ok := md["annotations"].(map[string]any); ok {
			if _, has := ann["kubectl.kubernetes.io/last-applied-configuration"]; has {
				md2 := make(map[string]any, len(md))
				for k, v := range md {
					md2[k] = v
				}
				ann2 := make(map[string]any, len(ann))
				for k, v := range ann {
					if k != "kubectl.kubernetes.io/last-applied-configuration" {
						ann2[k] = v
					}
				}
				md2["annotations"] = ann2
				out["metadata"] = md2
			}
		}
	}
	return out
}

func newActivation(kp *kindProgs, obj map[string]any, contextName string, now time.Time) *activation {
	ns, _ := nestedString(obj, "metadata", "namespace")
	a := &activation{object: obj, now: types.Timestamp{Time: now}, context: contextName, namespace: ns}
	a.vars = &lazyVars{progs: kp.vars, act: a}
	return a
}

func nestedString(obj map[string]any, path ...string) (string, bool) {
	var cur any = obj
	for _, p := range path {
		m, ok := cur.(map[string]any)
		if !ok {
			return "", false
		}
		cur = m[p]
	}
	s, ok := cur.(string)
	return s, ok
}

// evalErr prefixes err with the expression's place in plugin.yaml.
func evalErr(p *program, err error) error {
	msg := err.Error()
	if strings.Contains(msg, "actual cost limit exceeded") {
		msg = "too expensive: the evaluation went over its cost limit"
	}
	return fmt.Errorf("%s: %s", p.expr.pos, msg)
}

// ColumnProgram evaluates one plugin column (columns.Program).
type ColumnProgram struct {
	plugin  *Plugin
	kp      *kindProgs
	prog    *program
	context string
}

// Eval is the cell for obj.
func (c *ColumnProgram) Eval(obj map[string]any) (any, error) { return c.evalAt(obj, time.Now()) }

func (c *ColumnProgram) evalAt(obj map[string]any, now time.Time) (any, error) {
	start := time.Now()
	a := newActivation(c.kp, prepareObject(c.kp.key, obj), c.context, now)
	v, _, err := c.prog.prg.Eval(a)
	var out any
	if err == nil {
		out, err = toJSON(v)
	}
	c.plugin.stats.record(statColumn, time.Since(start), err)
	if err != nil {
		return nil, evalErr(c.prog, err)
	}
	return out, nil
}

// UsesNow reports whether the cell depends on the time (so a memoised row
// must be re-evaluated as time passes).
func (c *ColumnProgram) UsesNow() bool { return c.prog.usesNow }

// ---- panels ----------------------------------------------------------------

// PanelOut is one plugin's sections for an object (GET /api/plugins/panel).
type PanelOut struct {
	Plugin   string       `json:"plugin"`
	Name     string       `json:"name"`
	Sections []SectionOut `json:"sections"`
	// Errors are the kind entry's compile errors (then there are no
	// sections) or a budget the render ran out of.
	Errors []Diag `json:"errors,omitempty"`
	// Notes say what related objects or metrics couldn't be read (a kind
	// the cluster doesn't serve, a forbidden list, no Prometheus).
	Notes []string `json:"notes,omitempty"`
	// Refresh is how often (seconds) the UI should render the panel again
	// while it is open, when it reads related objects (5), metrics (15) or
	// now (30); 0 = only when the object changes.
	Refresh int `json:"refresh,omitempty"`
}

// SectionOut is a resolved section: blocks are plain JSON objects with a
// "type" (the block type, or "error" with "message").
type SectionOut struct {
	Title     string           `json:"title"`
	Icon      string           `json:"icon,omitempty"`
	Collapsed bool             `json:"collapsed,omitempty"`
	Blocks    []map[string]any `json:"blocks"`
}

type renderer struct {
	ctx  context.Context
	act  *activation
	cost uint64
	errs int
}

func (r *renderer) eval(p *program) (any, error) {
	if p == nil {
		return nil, nil
	}
	if r.cost+r.act.vars.cost > panelTotalCost {
		return nil, errors.New("the panel went over its total cost limit")
	}
	v, det, err := p.prg.ContextEval(r.ctx, r.act)
	if det != nil && det.ActualCost() != nil {
		r.cost += *det.ActualCost()
	}
	if err == nil {
		var out any
		out, err = toJSON(v)
		if err == nil {
			return out, nil
		}
	}
	r.errs++
	return nil, evalErr(p, err)
}

func (r *renderer) cond(p *program) (bool, error) {
	if p == nil {
		return true, nil
	}
	v, err := r.eval(p)
	if err != nil {
		return false, err
	}
	b, ok := v.(bool)
	if !ok {
		return false, evalErr(p, fmt.Errorf("when must be true or false, got %v", v))
	}
	return b, nil
}

func errBlock(err error) map[string]any {
	return map[string]any{"type": "error", "message": err.Error()}
}

func (r *renderer) section(sp secProg) (SectionOut, bool) {
	out := SectionOut{Title: sp.sec.Title, Icon: sp.sec.Icon, Collapsed: sp.sec.Collapsed, Blocks: []map[string]any{}}
	show, err := r.cond(sp.when)
	if err != nil {
		out.Blocks = append(out.Blocks, errBlock(err))
		return out, true
	}
	if !show {
		return out, false
	}
	for _, bp := range sp.blocks {
		if b := r.block(bp); b != nil {
			out.Blocks = append(out.Blocks, b)
		}
	}
	return out, true
}

func (r *renderer) block(bp blockProg) map[string]any {
	b := bp.b
	show, err := r.cond(bp.when)
	if err != nil {
		return errBlock(err)
	}
	if !show {
		return nil
	}
	out := map[string]any{"type": b.Type}
	var firstErr error
	get := func(role string) any {
		v, err := r.eval(bp.progs[role])
		if err != nil && firstErr == nil {
			firstErr = err
		}
		return v
	}
	switch b.Type {
	case "fields":
		var items []map[string]any
		for i, f := range b.Fields {
			k := itoa(i)
			if p := bp.progs[k+".when"]; p != nil {
				ok, err := r.cond(p)
				if err != nil {
					items = append(items, map[string]any{"label": f.Label, "error": err.Error()})
					continue
				}
				if !ok {
					continue
				}
			}
			v, err := r.eval(bp.progs[k+".value"])
			if err != nil {
				items = append(items, map[string]any{"label": f.Label, "error": err.Error()})
				continue
			}
			if v == nil || v == "" {
				continue
			}
			item := map[string]any{"label": f.Label, "value": v, "type": orDefault(f.Type, "text")}
			if f.Copy {
				item["copy"] = true
			}
			if f.Mono {
				item["mono"] = true
			}
			if p := bp.progs[k+".link"]; p != nil {
				if l, err := r.eval(p); err == nil && l != nil {
					item["link"] = l
				}
			}
			items = append(items, item)
		}
		out["items"] = orEmpty(items)
	case "badges":
		var items []map[string]any
		for i := range b.Badges {
			k := itoa(i)
			if p := bp.progs[k+".when"]; p != nil {
				if ok, err := r.cond(p); err != nil || !ok {
					continue
				}
			}
			t, err := r.eval(bp.progs[k+".text"])
			if err != nil {
				items = append(items, map[string]any{"error": err.Error()})
				continue
			}
			if t == nil || t == "" {
				continue
			}
			item := map[string]any{"text": fmt.Sprint(t)}
			if s, _ := r.eval(bp.progs[k+".severity"]); s != nil {
				item["severity"] = fmt.Sprint(s)
			}
			items = append(items, item)
		}
		out["items"] = orEmpty(items)
	case "chips", "links":
		v := get("items")
		switch v := v.(type) {
		case nil:
			out["items"] = []any{}
		case []any, map[string]any:
			out["items"] = v
		default:
			if firstErr == nil {
				firstErr = evalErr(bp.progs["items"], fmt.Errorf("items must be a list or a map"))
			}
		}
		if b.Empty != "" {
			out["empty"] = b.Empty
		}
	case "conditions":
		if bp.progs["from"] != nil {
			out["conditions"] = get("from")
		} else {
			out["conditions"] = nestedList(r.act.object, "status", "conditions")
		}
	case "table":
		r.table(bp, out, &firstErr)
	case "bar":
		out["label"] = b.Label
		out["value"] = get("value")
		out["max"] = get("max")
		out["format"] = orDefault(b.Format, "number")
	case "code":
		out["value"] = get("value")
		out["language"] = orDefault(b.Language, "text")
	case "json":
		out["value"] = get("value")
	case "settings":
		limit := b.Limit
		if limit <= 0 {
			limit = settingsDefaultLimit
		}
		switch v := get("value").(type) {
		case nil:
			out["rows"], out["total"] = []map[string]any{}, 0
		case map[string]any:
			out["rows"], out["total"] = flattenSettings(v, r.act.namespace, limit)
		default:
			if firstErr == nil {
				firstErr = evalErr(bp.progs["value"], fmt.Errorf("a settings block's value must be a map"))
			}
		}
		if b.Empty != "" {
			out["empty"] = b.Empty
		}
	case "message":
		out["text"] = get("text")
		out["severity"] = orDefault(b.Severity, "info")
		if bp.progs["title"] != nil {
			if t := get("title"); t != nil && t != "" {
				out["title"] = fmt.Sprint(t)
			}
		}
	}
	if firstErr != nil {
		return errBlock(firstErr)
	}
	return out
}

func (r *renderer) table(bp blockProg, out map[string]any, firstErr *error) {
	b := bp.b
	rowsV, err := r.eval(bp.progs["rows"])
	if err != nil {
		*firstErr = err
		return
	}
	rows, ok := rowsV.([]any)
	if rowsV != nil && !ok {
		*firstErr = evalErr(bp.progs["rows"], fmt.Errorf("rows must be a list"))
		return
	}
	cols := make([]map[string]any, len(b.Columns))
	sortCol := -1
	for i, c := range b.Columns {
		cols[i] = map[string]any{"name": c.Name, "type": orDefault(c.Type, "text")}
		if c.Mono {
			cols[i]["mono"] = true
		}
		if c.Name == b.SortBy {
			sortCol = i
		}
	}
	total := len(rows)
	if len(rows) > tableRowLimit {
		rows = rows[:tableRowLimit]
	}
	// The row's CEL value is converted from its JSON form.
	cells := make([][]map[string]any, 0, len(rows))
	r.act.hasRow = true
	defer func() { r.act.row, r.act.hasRow = nil, false }()
	for _, row := range rows {
		r.act.row = row
		line := make([]map[string]any, len(b.Columns))
		for i := range b.Columns {
			k := "col." + itoa(i)
			v, err := r.eval(bp.progs[k+".value"])
			cell := map[string]any{"value": v}
			if err != nil {
				cell = map[string]any{"error": err.Error()}
			} else if p := bp.progs[k+".link"]; p != nil {
				if l, err := r.eval(p); err == nil && l != nil {
					cell["link"] = l
				}
			}
			line[i] = cell
		}
		cells = append(cells, line)
	}
	if sortCol >= 0 {
		sort.SliceStable(cells, func(i, j int) bool {
			less := lessValue(cells[i][sortCol]["value"], cells[j][sortCol]["value"])
			if b.Descending {
				return lessValue(cells[j][sortCol]["value"], cells[i][sortCol]["value"])
			}
			return less
		})
	}
	limit := b.Limit
	if limit <= 0 {
		limit = 20
	}
	out["columns"] = cols
	out["rows"] = cells
	out["total"] = total
	out["limit"] = limit
	if b.Empty != "" {
		out["empty"] = b.Empty
	}
}

func lessValue(a, b any) bool {
	switch x := a.(type) {
	case int64:
		if y, ok := b.(int64); ok {
			return x < y
		}
	case float64:
		if y, ok := b.(float64); ok {
			return x < y
		}
	}
	return fmt.Sprint(a) < fmt.Sprint(b)
}

func nestedList(obj map[string]any, path ...string) []any {
	var cur any = obj
	for _, p := range path {
		m, ok := cur.(map[string]any)
		if !ok {
			return []any{}
		}
		cur = m[p]
	}
	if l, ok := cur.([]any); ok {
		return l
	}
	return []any{}
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func orEmpty(items []map[string]any) []map[string]any {
	if items == nil {
		return []map[string]any{}
	}
	return items
}

// renderPanel renders kind entry kp's sections for obj.
func renderPanel(p *Plugin, kp *kindProgs, obj map[string]any, env Env) PanelOut {
	start := time.Now()
	out := PanelOut{Plugin: p.ID(), Name: p.Name(), Sections: []SectionOut{}}
	r := &renderer{act: newActivation(kp, prepareObject(kp.key, obj), env.Context, env.now())}
	// Lookups first, with their own budget (a cold related kind costs a
	// LIST), then the sections with the render's.
	var ns notes
	lctx, lcancel := context.WithTimeout(context.Background(), panelTimeout)
	r.ctx = lctx
	r.resolveRelated(kp, kp.panelRelated, env, &ns)
	r.resolveMetrics(kp, kp.panelMetrics, env, &ns)
	lcancel()
	out.Notes = ns
	for _, need := range []struct {
		on   bool
		secs int
	}{{kp.panelNow, 30}, {!kp.panelMetrics.empty(), 15}, {!kp.panelRelated.empty(), 5}} {
		if need.on {
			out.Refresh = need.secs
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), panelTimeout)
	defer cancel()
	r.ctx = ctx
	for _, sp := range kp.sections {
		if s, ok := r.section(sp); ok {
			out.Sections = append(out.Sections, s)
		}
	}
	var err error
	if r.errs > 0 {
		err = fmt.Errorf("%d errors", r.errs)
	}
	if ctx.Err() != nil {
		err = fmt.Errorf("operation interrupted: the panel took longer than %s", panelTimeout)
		out.Errors = append(out.Errors, Diag{Pos: Pos{File: ManifestFile}, Message: err.Error()})
	}
	p.stats.record(statPanel, time.Since(start), err)
	return out
}

// ---- actions ---------------------------------------------------------------

// ActionOut is an action offered for an object.
type ActionOut struct {
	Plugin string `json:"plugin"`
	ID     string `json:"id"`
	// Type is shell (a command on this computer) or patch (a change to
	// the object through POST /api/actions/plugin.<plugin>.<id>).
	Type      string `json:"type"`
	Label     string `json:"label"`
	Icon      string `json:"icon,omitempty"`
	Shortcut  string `json:"shortcut,omitempty"`
	Message   string `json:"message,omitempty"`
	Dangerous bool   `json:"dangerous"`
	// Argv is a shell action's command as it will run (shown in the
	// confirmation).
	Argv []string `json:"argv,omitempty"`
	// Background shell actions run without a dock tab.
	Background bool `json:"background,omitempty"`
	// PatchType and Inputs are a patch action's (inputs with their
	// defaults evaluated for the object).
	PatchType string     `json:"patchType,omitempty"`
	Inputs    []InputOut `json:"inputs,omitempty"`
	// Consented is whether the user has agreed to the plugin's current
	// permissions; the UI asks first when not.
	Consented bool `json:"consented"`
}

// InputOut is a patch action's form field.
type InputOut struct {
	Name    string   `json:"name"`
	Label   string   `json:"label"`
	Type    string   `json:"type"`
	Options []string `json:"options,omitempty"`
	Default any      `json:"default"`
	// ValidateMessage is shown when the backend refuses the value.
	ValidateMessage string `json:"validateMessage,omitempty"`
}

// actionTimeout bounds one action evaluation (docs/PLUGINS.md §8).
const actionTimeout = 50 * time.Millisecond

// offered evaluates `when` of kp's actions for obj, after looking up the
// related objects action expressions read. The renderer is returned for
// further expressions of the same object (input defaults, patch bodies).
func offered(p *Plugin, kp *kindProgs, obj map[string]any, env Env) ([]actProg, *renderer, []error) {
	if len(kp.actions) == 0 {
		return nil, nil, nil
	}
	var out []actProg
	var errs []error
	start := time.Now()
	r := &renderer{act: newActivation(kp, prepareObject(kp.key, obj), env.Context, env.now())}
	lctx, lcancel := context.WithTimeout(context.Background(), actionTimeout)
	r.ctx = lctx
	var ns notes
	r.resolveRelated(kp, kp.actionRelated, env, &ns)
	lcancel()
	ctx, cancel := context.WithTimeout(context.Background(), actionTimeout)
	defer cancel()
	r.ctx = ctx
	for _, ap := range kp.actions {
		ok, err := r.cond(ap.when)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if ok {
			out = append(out, ap)
		}
	}
	p.stats.record(statAction, time.Since(start), errors.Join(errs...))
	r.ctx = context.Background()
	return out, r, errs
}

// actionOut describes offered action ap, evaluating its inputs' defaults.
func actionOut(p *Plugin, ap actProg, r *renderer, vars func() ShellVars, consented bool) ActionOut {
	a := ap.a
	out := ActionOut{Plugin: p.ID(), ID: a.ID, Label: a.Label, Icon: a.Icon, Shortcut: a.Shortcut, Message: a.Message,
		Dangerous: a.IsDangerous(), Consented: consented}
	if a.Shell != nil {
		out.Type, out.Argv, out.Background = "shell", a.Argv(vars()), a.Shell.Background
		return out
	}
	out.Type, out.PatchType = "patch", a.Patch.Type
	ctx, cancel := context.WithTimeout(context.Background(), actionTimeout)
	defer cancel()
	r.ctx = ctx
	for _, ip := range ap.inputs {
		in := ip.in
		io := InputOut{Name: in.Name, Label: orDefault(in.Label, in.Name), Type: in.InputType(), Options: in.Options, ValidateMessage: in.ValidateMessage}
		if v, err := r.eval(ip.def); err == nil && v != nil {
			io.Default = v
		} else {
			io.Default = zeroInput(in)
		}
		out.Inputs = append(out.Inputs, io)
	}
	return out
}
