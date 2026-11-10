package plugins

import (
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common"
	"github.com/google/cel-go/common/ast"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
	"github.com/google/cel-go/common/types/traits"
	"github.com/google/cel-go/ext"
	"github.com/google/cel-go/interpreter"
	"github.com/google/cel-go/parser"

	"github.com/matty234/k8sman/backend/internal/plugins/k8scel"
)

// The CEL environment of k8sman.dev/v1 (docs/PLUGINS.md §5).
//
// Variables: object, variables.<name> (each declared with its own type
// when the kind entry is compiled, and evaluated lazily), now, context, ns
// (the object's namespace; `namespace` is a reserved word in CEL),
// related and metrics (declared everywhere so they type-check; the
// compiler refuses them where they aren't available, see refs), row in
// table block columns, and input in patch bodies and input checks.
//
// age(t) and until(t) are macros for _age(t, now) and _until(t, now), and
// ref(group, kind, name) for ref(group, kind, ns, name), so functions
// stay pure and an expression's use of `now` is visible in its AST.

const (
	varObject    = "object"
	varVariables = "variables"
	varNow       = "now"
	varContext   = "context"
	varNS        = "ns"
	varRow       = "row"
	varRelated   = "related"
	varMetrics   = "metrics"
	varInput     = "input"
	varItem      = "item"
)

var (
	envOnce sync.Once
	baseEnv *cel.Env
	envErr  error
)

// envs returns the shared base environment.
func envs() (*cel.Env, error) {
	envOnce.Do(func() {
		baseEnv, envErr = cel.NewEnv(envOptions()...)
	})
	return baseEnv, envErr
}

var refType = cel.MapType(cel.StringType, cel.StringType)

func envOptions() []cel.EnvOption {
	return []cel.EnvOption{
		cel.OptionalTypes(),
		cel.DefaultUTCTimeZone(true),
		cel.CrossTypeNumericComparisons(true),
		ext.Strings(),
		ext.Sets(),
		k8scel.Lists(),
		k8scel.Regex(),
		k8scel.URLs(),
		k8scel.QuantityLib(),
		cel.Variable(varObject, cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable(varNow, cel.TimestampType),
		cel.Variable(varContext, cel.StringType),
		cel.Variable(varNS, cel.StringType),
		cel.Variable(varRelated, cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable(varMetrics, cel.MapType(cel.StringType, cel.ListType(cel.DynType))),
		cel.Macros(
			parser.NewGlobalMacro("age", 1, nowMacro("_age")),
			parser.NewGlobalMacro("until", 1, nowMacro("_until")),
			parser.NewGlobalMacro("ref", 3, func(eh parser.ExprHelper, _ ast.Expr, args []ast.Expr) (ast.Expr, *common.Error) {
				return eh.NewCall("ref", args[0], args[1], eh.NewIdent(varNS), args[2]), nil
			}),
		),
		cel.Function("ref",
			cel.Overload("ref_dyn", []*cel.Type{cel.DynType}, refType, cel.UnaryBinding(refOf)),
			cel.Overload("ref_group_kind_ns_name", []*cel.Type{cel.StringType, cel.StringType, cel.StringType, cel.StringType}, refType,
				cel.FunctionBinding(func(a ...ref.Val) ref.Val {
					return refVal(str(a[0]), str(a[1]), str(a[2]), str(a[3]))
				})),
		),
		cel.Function("condition",
			cel.Overload("condition_dyn_string", []*cel.Type{cel.DynType, cel.StringType}, cel.OptionalType(cel.DynType),
				cel.BinaryBinding(func(obj, typ ref.Val) ref.Val {
					if c := findCondition(obj, typ); c != nil {
						return types.OptionalOf(c)
					}
					return types.OptionalNone
				})),
		),
		cel.Function("conditionTrue",
			cel.Overload("condition_true_dyn_string", []*cel.Type{cel.DynType, cel.StringType}, cel.BoolType,
				cel.BinaryBinding(func(obj, typ ref.Val) ref.Val {
					c, ok := findCondition(obj, typ).(traits.Mapper)
					if !ok {
						return types.False
					}
					s, found := c.Find(types.String("status"))
					return types.Bool(found && s.Equal(types.String("True")) == types.True)
				})),
		),
		cel.Function("_age",
			cel.Overload("_age_dyn_timestamp", []*cel.Type{cel.DynType, cel.TimestampType}, cel.DurationType,
				cel.BinaryBinding(func(t, now ref.Val) ref.Val {
					ts, err := asTime(t)
					if err != nil {
						return types.NewErr("age: %v", err)
					}
					return types.Duration{Duration: now.(types.Timestamp).Time.Sub(ts)}
				})),
		),
		cel.Function("_until",
			cel.Overload("_until_dyn_timestamp", []*cel.Type{cel.DynType, cel.TimestampType}, cel.DurationType,
				cel.BinaryBinding(func(t, now ref.Val) ref.Val {
					ts, err := asTime(t)
					if err != nil {
						return types.NewErr("until: %v", err)
					}
					return types.Duration{Duration: ts.Sub(now.(types.Timestamp).Time)}
				})),
		),
		cel.Function("humanDuration",
			cel.Overload("human_duration_duration", []*cel.Type{cel.DurationType}, cel.StringType,
				cel.UnaryBinding(func(d ref.Val) ref.Val { return types.String(HumanDuration(d.(types.Duration).Duration)) })),
		),
		cel.Function("promQuote",
			cel.Overload("prom_quote_string", []*cel.Type{cel.StringType}, cel.StringType,
				cel.UnaryBinding(func(s ref.Val) ref.Val { return types.String(strconv.Quote(str(s))) })),
		),
		// list.sort(): CEL iterates maps in no particular order, so a list
		// made from a map's keys needs sorting to be stable. (Not all of
		// ext.Lists: it slows every cell by about 1 µs.)
		cel.Function("sort",
			cel.MemberOverload("list_sort", []*cel.Type{cel.ListType(cel.DynType)}, cel.ListType(cel.DynType),
				cel.UnaryBinding(sortList)),
		),
		// list.flatten(): the lists in a list joined into one (one level),
		// e.g. the results of several reports. CEL's macros can map and
		// filter but not concatenate a list of lists.
		cel.Function("flatten",
			cel.MemberOverload("list_flatten", []*cel.Type{cel.ListType(cel.DynType)}, cel.ListType(cel.DynType),
				cel.UnaryBinding(flattenList)),
		),
		// list.distinct(): each value once, in first-seen order (the
		// device classes of a claim's requests, the nodes of a selector).
		cel.Function("distinct",
			cel.MemberOverload("list_distinct", []*cel.Type{cel.ListType(cel.DynType)}, cel.ListType(cel.DynType),
				cel.UnaryBinding(distinctList)),
		),
	}
}

// distinctList keeps the first of equal values.
func distinctList(v ref.Val) ref.Val {
	l, ok := v.(traits.Lister)
	if !ok {
		return types.NewErr("distinct: expected a list")
	}
	var items []ref.Val
	for it := l.Iterator(); it.HasNext() == types.True; {
		e := it.Next()
		if !slices.ContainsFunc(items, func(x ref.Val) bool { return x.Equal(e) == types.True }) {
			items = append(items, e)
		}
	}
	return types.DefaultTypeAdapter.NativeToValue(items)
}

// flattenList joins the lists in a list; other elements are kept as they
// are.
func flattenList(v ref.Val) ref.Val {
	l, ok := v.(traits.Lister)
	if !ok {
		return types.NewErr("flatten: expected a list")
	}
	var items []ref.Val
	for it := l.Iterator(); it.HasNext() == types.True; {
		e := it.Next()
		inner, ok := e.(traits.Lister)
		if !ok {
			items = append(items, e)
			continue
		}
		for jt := inner.Iterator(); jt.HasNext() == types.True; {
			items = append(items, jt.Next())
		}
	}
	return types.DefaultTypeAdapter.NativeToValue(items)
}

// sortList sorts a list of strings, numbers, booleans or timestamps.
func sortList(v ref.Val) ref.Val {
	l, ok := v.(traits.Lister)
	if !ok {
		return types.NewErr("sort: expected a list")
	}
	var items []ref.Val
	for it := l.Iterator(); it.HasNext() == types.True; {
		items = append(items, it.Next())
	}
	var bad ref.Val
	slices.SortStableFunc(items, func(a, b ref.Val) int {
		c, ok := a.(traits.Comparer)
		if !ok {
			bad = a
			return 0
		}
		r, ok := c.Compare(b).(types.Int)
		if !ok {
			bad = b
			return 0
		}
		return int(r)
	})
	if bad != nil {
		return types.NewErr("sort: can't order %s values", bad.Type().TypeName())
	}
	return types.DefaultTypeAdapter.NativeToValue(items)
}

func nowMacro(fn string) parser.MacroExpander {
	return func(eh parser.ExprHelper, _ ast.Expr, args []ast.Expr) (ast.Expr, *common.Error) {
		return eh.NewCall(fn, args[0], eh.NewIdent(varNow)), nil
	}
}

func str(v ref.Val) string {
	s, _ := v.Value().(string)
	return s
}

func refVal(group, kind, namespace, name string) ref.Val {
	return types.DefaultTypeAdapter.NativeToValue(map[string]string{"group": group, "kind": kind, "namespace": namespace, "name": name})
}

// refOf is ref(obj): group and kind from apiVersion and kind.
func refOf(obj ref.Val) ref.Val {
	m, ok := obj.(traits.Mapper)
	if !ok {
		return types.NewErr("ref: expected an object, got %s", obj.Type().TypeName())
	}
	get := func(m traits.Mapper, k string) string {
		v, ok := m.Find(types.String(k))
		if !ok {
			return ""
		}
		return str(v)
	}
	group, _, _ := strings.Cut(get(m, "apiVersion"), "/")
	if !strings.Contains(get(m, "apiVersion"), "/") {
		group = ""
	}
	md, _ := m.Find(types.String("metadata"))
	mdm, _ := md.(traits.Mapper)
	if mdm == nil {
		return types.NewErr("ref: the object has no metadata")
	}
	return refVal(group, get(m, "kind"), get(mdm, "namespace"), get(mdm, "name"))
}

// findCondition is the entry of obj.status.conditions whose type is typ.
func findCondition(obj, typ ref.Val) ref.Val {
	m, ok := obj.(traits.Mapper)
	if !ok {
		return nil
	}
	st, ok := m.Find(types.String("status"))
	if !ok {
		return nil
	}
	sm, ok := st.(traits.Mapper)
	if !ok {
		return nil
	}
	cs, ok := sm.Find(types.String("conditions"))
	if !ok {
		return nil
	}
	l, ok := cs.(traits.Lister)
	if !ok {
		return nil
	}
	for it := l.Iterator(); it.HasNext() == types.True; {
		c, ok := it.Next().(traits.Mapper)
		if !ok {
			continue
		}
		if t, ok := c.Find(types.String("type")); ok && t.Equal(typ) == types.True {
			return c
		}
	}
	return nil
}

func asTime(v ref.Val) (time.Time, error) {
	if o, ok := v.(*types.Optional); ok {
		if !o.HasValue() {
			return time.Time{}, fmt.Errorf("empty optional")
		}
		v = o.GetValue()
	}
	switch t := v.(type) {
	case types.Timestamp:
		return t.Time, nil
	case types.String:
		return time.Parse(time.RFC3339, string(t))
	}
	return time.Time{}, fmt.Errorf("expected a timestamp or an RFC3339 string, got %s", v.Type().TypeName())
}

// HumanDuration formats d kubectl style: 45s, 3h12m, 29d, 1y20d.
func HumanDuration(d time.Duration) string {
	if d < 0 {
		return "-" + HumanDuration(-d)
	}
	s := int64(d.Round(time.Second) / time.Second)
	switch {
	case s < 120:
		return fmt.Sprintf("%ds", s)
	case s < 600:
		if s%60 == 0 {
			return fmt.Sprintf("%dm", s/60)
		}
		return fmt.Sprintf("%dm%ds", s/60, s%60)
	case s < 3*3600:
		if m := (s / 60) % 60; m != 0 {
			return fmt.Sprintf("%dh%dm", s/3600, m)
		}
		return fmt.Sprintf("%dh", s/3600)
	case s < 48*3600:
		return fmt.Sprintf("%dh", s/3600)
	case s < 8*86400:
		if h := (s / 3600) % 24; h != 0 {
			return fmt.Sprintf("%dd%dh", s/86400, h)
		}
		return fmt.Sprintf("%dd", s/86400)
	case s < 2*365*86400:
		return fmt.Sprintf("%dd", s/86400)
	case s < 8*365*86400:
		if dd := (s / 86400) % 365; dd != 0 {
			return fmt.Sprintf("%dy%dd", s/(365*86400), dd)
		}
		return fmt.Sprintf("%dy", s/(365*86400))
	}
	return fmt.Sprintf("%dy", s/(365*86400))
}

// ---- activation ------------------------------------------------------------

// activation is one evaluation's variables. It is cheaper than a map
// activation and holds the lazy `variables`.
type activation struct {
	object    map[string]any
	vars      *lazyVars
	now       types.Timestamp
	context   string
	namespace string
	row       any
	hasRow    bool
	// item is the candidate a related filter is looking at.
	item    any
	hasItem bool
	// related and metrics are set for panels and actions (nil elsewhere:
	// the compiler keeps them out of columns and alerts).
	related map[string]any
	metrics map[string]any
	input   map[string]any
}

func (a *activation) ResolveName(name string) (any, bool) {
	switch name {
	case varObject:
		return a.object, true
	case varNow:
		return a.now, true
	case varContext:
		return a.context, true
	case varNS:
		return a.namespace, true
	case varRow:
		return a.row, a.hasRow
	case varItem:
		return a.item, a.hasItem
	case varRelated:
		return a.related, a.related != nil
	case varMetrics:
		return a.metrics, a.metrics != nil
	case varInput:
		return a.input, a.input != nil
	}
	if v, ok := strings.CutPrefix(name, varVariables+"."); ok {
		return a.vars.get(v)
	}
	return nil, false
}

func (a *activation) Parent() interpreter.Activation { return nil }

// lazyVars are the kind entry's variables (compiled programs), each
// evaluated on first use, at most once per evaluation.
type lazyVars struct {
	progs map[string]*program
	act   *activation
	done  map[string]ref.Val
	// cost is what evaluating variables cost so far (added to the
	// caller's budget by the panel renderer).
	cost uint64
}

func (l *lazyVars) get(name string) (ref.Val, bool) {
	if v, ok := l.done[name]; ok {
		return v, true
	}
	p, ok := l.progs[name]
	if !ok {
		return nil, false
	}
	if l.done == nil {
		l.done = map[string]ref.Val{}
	}
	out, det, err := p.prg.Eval(l.act)
	if det != nil && det.ActualCost() != nil {
		l.cost += *det.ActualCost()
	}
	if err != nil {
		out = types.NewErr("variables.%s: %v", name, err)
	}
	l.done[name] = out
	return out, true
}

// ---- results ---------------------------------------------------------------

// toJSON converts a CEL result into plain JSON values for the UI. An empty
// optional is nil; timestamps are RFC3339; durations are seconds.
func toJSON(v ref.Val) (any, error) {
	switch x := v.(type) {
	case nil:
		return nil, nil
	case *types.Err:
		return nil, x
	case *types.Optional:
		if !x.HasValue() {
			return nil, nil
		}
		return toJSON(x.GetValue())
	case types.Null:
		return nil, nil
	case types.Bool:
		return bool(x), nil
	case types.Int:
		return int64(x), nil
	case types.Uint:
		return uint64(x), nil
	case types.Double:
		f := float64(x)
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return nil, nil
		}
		return f, nil
	case types.String:
		return string(x), nil
	case types.Bytes:
		return string(x), nil
	case types.Timestamp:
		return x.Time.UTC().Format(time.RFC3339), nil
	case types.Duration:
		return x.Duration.Seconds(), nil
	case k8scel.Quantity:
		return x.Quantity.String(), nil
	case k8scel.URL:
		return x.URL.String(), nil
	case traits.Mapper:
		out := map[string]any{}
		for it := x.Iterator(); it.HasNext() == types.True; {
			k := it.Next()
			val, _ := x.Find(k)
			jv, err := toJSON(val)
			if err != nil {
				return nil, err
			}
			out[fmt.Sprint(k.Value())] = jv
		}
		return out, nil
	case traits.Lister:
		var out []any
		for it := x.Iterator(); it.HasNext() == types.True; {
			jv, err := toJSON(it.Next())
			if err != nil {
				return nil, err
			}
			out = append(out, jv)
		}
		if out == nil {
			out = []any{}
		}
		return out, nil
	}
	if v.Type() == types.TypeType {
		return v.(ref.Type).TypeName(), nil
	}
	return fmt.Sprint(v.Value()), nil
}
