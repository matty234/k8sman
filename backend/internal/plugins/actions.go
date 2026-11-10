package plugins

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
)

// Patch actions change the object they are offered for, and only through
// the app's action path: POST /api/actions/plugin.<id>.<action> (read-only
// refusal, availability, dry-run), which calls Host.PatchAction for the
// body. The body is built here, in the backend, from the plugin's CEL and
// the user's inputs, which are checked here too: the UI's form is a
// convenience, not a check.

// InputError is an input the backend refused; Input names it.
type InputError struct {
	Input   string
	Message string
}

func (e *InputError) Error() string { return e.Message }

// PatchOut is a patch action's change, ready to send.
type PatchOut struct {
	Label string
	// Type is merge or json.
	Type string
	// Body is the patch (JSON).
	Body []byte
}

// zeroInput is an input's value when neither the user nor its default
// gives one.
func zeroInput(in *Input) any {
	switch in.InputType() {
	case "int":
		return int64(0)
	case "bool":
		return false
	case "enum":
		return in.Options[0]
	}
	return ""
}

// coerceInput checks a value from the UI against the input's type: JSON
// numbers must be whole for int, enum values one of the options.
func coerceInput(in *Input, v any) (any, error) {
	bad := func(want string) error {
		return &InputError{Input: in.Name, Message: fmt.Sprintf("%s must be %s", orDefault(in.Label, in.Name), want)}
	}
	switch in.InputType() {
	case "int":
		switch x := v.(type) {
		case float64:
			if x != math.Trunc(x) || math.Abs(x) > 1<<53 {
				return nil, bad("a whole number")
			}
			return int64(x), nil
		case int64:
			return x, nil
		case int:
			return int64(x), nil
		case string:
			i, err := strconv.ParseInt(strings.TrimSpace(x), 10, 64)
			if err != nil {
				return nil, bad("a whole number")
			}
			return i, nil
		}
		return nil, bad("a whole number")
	case "bool":
		if b, ok := v.(bool); ok {
			return b, nil
		}
		return nil, bad("true or false")
	case "enum":
		s, ok := v.(string)
		if !ok || !slices.Contains(in.Options, s) {
			return nil, bad("one of " + strings.Join(in.Options, ", "))
		}
		return s, nil
	}
	s, ok := v.(string)
	if !ok {
		return nil, bad("text")
	}
	if len(s) > 4096 {
		return nil, bad("at most 4096 characters")
	}
	return s, nil
}

// patchBody checks the inputs and evaluates patch action ap's body for
// the object in r. given are the user's values by input name (missing
// ones take their default).
func patchBody(ap actProg, r *renderer, given map[string]any) (*PatchOut, error) {
	a := ap.a
	ctx, cancel := context.WithTimeout(context.Background(), actionTimeout)
	defer cancel()
	r.ctx = ctx
	input := map[string]any{}
	for name := range given {
		if !slices.ContainsFunc(a.Inputs, func(in Input) bool { return in.Name == name }) {
			return nil, &InputError{Input: name, Message: fmt.Sprintf("action %s has no input %q", a.ID, name)}
		}
	}
	for _, ip := range ap.inputs {
		v, ok := given[ip.in.Name]
		if !ok || v == nil {
			d, err := r.eval(ip.def)
			if err != nil || d == nil {
				d = zeroInput(ip.in)
			}
			v = d
		}
		cv, err := coerceInput(ip.in, v)
		if err != nil {
			return nil, err
		}
		input[ip.in.Name] = cv
	}
	r.act.input = input
	defer func() { r.act.input = nil }()
	for _, ip := range ap.inputs {
		if ip.validate == nil {
			continue
		}
		ok, err := r.cond(ip.validate)
		if err != nil {
			return nil, &InputError{Input: ip.in.Name, Message: err.Error()}
		}
		if !ok {
			msg := ip.in.ValidateMessage
			if msg == "" {
				msg = orDefault(ip.in.Label, ip.in.Name) + " is not valid"
			}
			return nil, &InputError{Input: ip.in.Name, Message: msg}
		}
	}
	v, err := r.eval(ap.body)
	if err != nil {
		return nil, err
	}
	if err := checkPatch(a.Patch.Type, v); err != nil {
		return nil, fmt.Errorf("%s: %w", a.Patch.Body.pos, err)
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return &PatchOut{Label: a.Label, Type: a.Patch.Type, Body: b}, nil
}

// checkPatch checks the body's shape: a non-empty map for a merge patch, a
// list of {op, path} operations for a JSON patch.
func checkPatch(typ string, v any) error {
	if typ == "merge" {
		m, ok := v.(map[string]any)
		if !ok || len(m) == 0 {
			return fmt.Errorf("a merge patch body must be a non-empty map")
		}
		for _, k := range []string{"apiVersion", "kind"} {
			if _, ok := m[k]; ok {
				return fmt.Errorf("a patch can't change %s", k)
			}
		}
		return nil
	}
	ops, ok := v.([]any)
	if !ok || len(ops) == 0 {
		return fmt.Errorf("a json patch body must be a non-empty list of operations")
	}
	for i, o := range ops {
		m, ok := o.(map[string]any)
		if !ok {
			return fmt.Errorf("operation %d is not a map", i)
		}
		op, _ := m["op"].(string)
		path, _ := m["path"].(string)
		if !slices.Contains(jsonPatchOps, op) {
			return fmt.Errorf("operation %d: op must be one of %s", i, strings.Join(jsonPatchOps, ", "))
		}
		if !strings.HasPrefix(path, "/") {
			return fmt.Errorf("operation %d: path must start with /", i)
		}
		if path == "/apiVersion" || path == "/kind" {
			return fmt.Errorf("a patch can't change %s", path[1:])
		}
	}
	return nil
}
