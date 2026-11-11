package plugins

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// Patch, subresource and create actions write to the cluster only through
// the app's action path: POST /api/actions/plugin.<id>.<action> (read-only
// refusal, availability, dry-run), which calls Host.BuildAction for the
// request. Patch actions change the object they are offered for,
// subresource actions call one of its subresources (KubeVirt's restart),
// create actions create an object that refers to it (a migration, a
// snapshot). The body is built here, in the backend, from the plugin's
// CEL and the user's inputs, which are checked here too: the UI's form is
// a convenience, not a check.

// InputError is an input the backend refused; Input names it.
type InputError struct {
	Input   string
	Message string
}

func (e *InputError) Error() string { return e.Message }

// Change is a patch, subresource or create action's request, built and
// checked, ready to send.
type Change struct {
	Label string
	// Kind is patch, subresource or create.
	Kind string
	// PatchType is a patch's: merge or json.
	PatchType string
	// Body is JSON: the patch, the subresource's body, or the object to
	// create.
	Body []byte
	// Subresource, Method, Group and Version are a subresource call's
	// (Group and Version defaulted to the object's).
	Subresource, Method, Group, Version string
	// Object is the object to create; its namespace is "" or the object's.
	Object map[string]any
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

// buildChange checks the inputs and evaluates action ap's body for the
// object in r, of type rt. given are the user's values by input name
// (missing ones take their default).
func buildChange(ap actProg, r *renderer, rt cluster.ResourceType, given map[string]any) (*Change, error) {
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
	out := &Change{Label: a.Label, Kind: a.Kind()}
	var bodyPos Pos
	switch {
	case a.Patch != nil:
		bodyPos, out.PatchType = a.Patch.Body.pos, a.Patch.Type
		err = checkPatch(a.Patch.Type, v)
	case a.Subresource != nil:
		sr := a.Subresource
		bodyPos = sr.Body.pos
		out.Subresource, out.Method = sr.Name, orDefault(sr.Method, "PUT")
		out.Group, out.Version = rt.Group, rt.Version
		if sr.Group != "" {
			out.Group = sr.Group
		}
		if sr.Version != "" {
			out.Version = sr.Version
		}
		if v == nil {
			v = map[string]any{}
		}
		if _, ok := v.(map[string]any); !ok {
			err = fmt.Errorf("a subresource body must be a map")
		}
	case a.Create != nil:
		bodyPos = a.Create.Body.pos
		out.Object, err = checkCreate(a.Create.Kind, r.act.namespace, v)
	}
	if err != nil {
		return nil, fmt.Errorf("%s: %w", bodyPos, err)
	}
	if out.Body, err = json.Marshal(v); err != nil {
		return nil, err
	}
	return out, nil
}

// checkCreate checks a create body: a map with apiVersion and kind of
// kind key, and metadata with a name or generateName, in no namespace
// but ns (the object's).
func checkCreate(key, ns string, v any) (map[string]any, error) {
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("a create body must be a map (the object)")
	}
	apiVersion, _ := obj["apiVersion"].(string)
	kind, _ := obj["kind"].(string)
	if apiVersion == "" || kind == "" {
		return nil, fmt.Errorf("the object needs apiVersion and kind")
	}
	group := ""
	if g, _, found := strings.Cut(apiVersion, "/"); found {
		group = g
	}
	if got := group + "/" + kind; got != key {
		return nil, fmt.Errorf("the object is a %s, but create.kind is %s", got, key)
	}
	if why := createDenied(key); why != "" {
		return nil, errors.New(why)
	}
	md, _ := obj["metadata"].(map[string]any)
	name, _ := md["name"].(string)
	gen, _ := md["generateName"].(string)
	if name == "" && gen == "" {
		return nil, fmt.Errorf("the object needs metadata.name or metadata.generateName")
	}
	if n, set := md["namespace"]; set && n != ns && n != "" {
		return nil, fmt.Errorf("the object's namespace must be the object's own (%q), not %v", ns, n)
	}
	return obj, nil
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
