// Package columns evaluates jq-based table columns against Kubernetes objects
// and persists per-resource user customisations.
package columns

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/itchyny/gojq"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// Column is one table column. Query is a jq expression run against the full
// object; the first emitted value becomes the cell (arrays are kept as-is).
type Column struct {
	Name  string `json:"name"`
	Query string `json:"query"`
	// Type is a rendering hint for the UI:
	//   "string" (default), "number", "age" (RFC3339 timestamp → relative age),
	//   "status" (coloured badge), "bool", "labels" (map → chips),
	//   "quantity" (a Kubernetes quantity or percentage such as "250m",
	//   "128Mi", "42%": right-aligned, sorted by value, "—" when empty),
	//   "percent" (a number 0–100 drawn as a small bar, amber from 80 and
	//   red from 90), "usage" (an object {raw, base?, percent?, basis?,
	//   unit: "cpu"|"bytes"}: the value with a bar and percentage of base,
	//   amber from 70 and red from 90, sorted by percent), "ratio" (an
	//   "x/y" count such as ready replicas: narrow, right-aligned, sorted
	//   by x/y).
	Type string `json:"type,omitempty"`
}

// Key identifies a resource independently of version, kubectl style:
// "pods", "deployments.apps", "certificates.cert-manager.io".
func Key(group, resource string) string {
	if group == "" {
		return resource
	}
	return resource + "." + group
}

var (
	nameCol = Column{Name: "Name", Query: ".metadata.name"}
	nsCol   = Column{Name: "Namespace", Query: ".metadata.namespace"}
	ageCol  = Column{Name: "Age", Query: ".metadata.creationTimestamp", Type: "age"}
)

// Defaults returns the built-in or derived default columns for a resource.
func Defaults(rt cluster.ResourceType, printer []cluster.PrinterColumn) []Column {
	head := []Column{nameCol}
	if rt.Namespaced {
		head = append(head, nsCol)
	}
	if body, ok := builtin[Key(rt.Group, rt.Resource)]; ok {
		return append(head, body...)
	}
	cols := head
	hasAge := false
	for _, p := range printer {
		q, ok := jsonPathToJQ(p.JSONPath)
		if !ok {
			continue
		}
		c := Column{Name: p.Name, Query: q}
		switch p.Type {
		case "date":
			c.Type = "age"
			if q == ".metadata.creationTimestamp" {
				hasAge = true
			}
		case "integer", "number":
			c.Type = "number"
		case "boolean":
			c.Type = "bool"
		}
		cols = append(cols, c)
	}
	if !hasAge {
		cols = append(cols, ageCol)
	}
	return cols
}

var simplePath = regexp.MustCompile(`^(\.[A-Za-z0-9_\-]+|\[\d+\])+$`)

// jsonPathToJQ converts simple kubectl JSONPath (.a.b[0].c) to jq. Filters and
// wildcards are not converted.
func jsonPathToJQ(p string) (string, bool) {
	p = strings.TrimSpace(p)
	p = strings.TrimPrefix(strings.TrimSuffix(p, "}"), "{")
	if !simplePath.MatchString(p) {
		return "", false
	}
	// Quote segments that aren't valid jq identifiers (e.g. contain '-').
	var b strings.Builder
	for _, seg := range regexp.MustCompile(`\.[^.\[]+|\[\d+\]`).FindAllString(p, -1) {
		if strings.HasPrefix(seg, ".") && strings.Contains(seg, "-") {
			fmt.Fprintf(&b, "[%q]", seg[1:])
		} else {
			b.WriteString(seg)
		}
	}
	return b.String(), true
}

// Store persists user column overrides as JSON keyed by Key().
type Store struct {
	path string
	mu   sync.RWMutex
	data map[string][]Column
}

// DefaultStorePath is ~/.config/k8sman/columns.json.
func DefaultStorePath() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		dir = os.TempDir()
	}
	// Prefer XDG-style ~/.config on macOS too; it's friendlier to edit by hand.
	if home, err := os.UserHomeDir(); err == nil {
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "k8sman", "columns.json")
}

// OpenStore loads (or lazily creates) the store at path.
func OpenStore(path string) (*Store, error) {
	s := &Store{path: path, data: map[string][]Column{}}
	b, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(b, &s.data); err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	return s, nil
}

// Get returns the user override for key, if any.
func (s *Store) Get(key string) ([]Column, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	c, ok := s.data[key]
	return c, ok
}

// Set stores an override (after validating every query compiles).
func (s *Store) Set(key string, cols []Column) error {
	if err := Validate(cols); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data[key] = cols
	return s.save()
}

// Validate checks that every column's query compiles.
func Validate(cols []Column) error {
	for _, c := range cols {
		if _, err := compile(c.Query); err != nil {
			return fmt.Errorf("column %q: %w", c.Name, err)
		}
	}
	return nil
}

// Delete removes an override, restoring defaults.
func (s *Store) Delete(key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.data, key)
	return s.save()
}

func (s *Store) save() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s.data, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

var (
	cacheMu sync.Mutex
	cache   = map[string]*gojq.Code{}
)

func compile(query string) (*gojq.Code, error) {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	if c, ok := cache[query]; ok {
		return c, nil
	}
	q, err := gojq.Parse(query)
	if err != nil {
		return nil, err
	}
	code, err := gojq.Compile(q)
	if err != nil {
		return nil, err
	}
	cache[query] = code
	return code, nil
}

// Evaluator runs a fixed column set against many objects.
type Evaluator struct {
	cols  []Column
	codes []*gojq.Code
	errs  []error
}

// NewEvaluator compiles the columns. Compile errors are reported per column
// rather than failing the whole table.
func NewEvaluator(cols []Column) *Evaluator {
	e := &Evaluator{cols: cols, codes: make([]*gojq.Code, len(cols)), errs: make([]error, len(cols))}
	for i, c := range cols {
		e.codes[i], e.errs[i] = compile(c.Query)
	}
	return e
}

// Columns returns the evaluator's columns.
func (e *Evaluator) Columns() []Column { return e.cols }

// PrivateCopy deep-copies an object for evaluation. gojq normalises numbers
// by writing every map and slice of its input in place, so objects shared
// between goroutines (the watch cache) must only be evaluated through a
// copy. Numbers are normalised as gojq would (int64 → int), so its own pass
// changes nothing.
func PrivateCopy(obj map[string]any) map[string]any {
	return privateCopy(obj).(map[string]any)
}

func privateCopy(v any) any {
	switch v := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, x := range v {
			out[k] = privateCopy(x)
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, x := range v {
			out[i] = privateCopy(x)
		}
		return out
	case int64:
		if v >= math.MinInt && v <= math.MaxInt {
			return int(v)
		}
		return v
	case float32:
		return float64(v)
	default:
		return v
	}
}

// Row evaluates every column against obj. errs[i] is non-nil when column i
// failed for this object. gojq normalises obj in place (see PrivateCopy).
func (e *Evaluator) Row(obj map[string]any) (cells []any, errs []error) {
	cells = make([]any, len(e.cols))
	errs = make([]error, len(e.cols))
	for i, code := range e.codes {
		if code == nil {
			errs[i] = e.errs[i]
			continue
		}
		cells[i], errs[i] = run(code, obj)
	}
	return cells, errs
}

func run(code *gojq.Code, obj map[string]any) (any, error) {
	iter := code.Run(obj)
	var out []any
	for {
		v, ok := iter.Next()
		if !ok {
			break
		}
		if err, isErr := v.(error); isErr {
			if h, ok := err.(*gojq.HaltError); ok && h.Value() == nil {
				break
			}
			return nil, err
		}
		out = append(out, v)
		if len(out) > 100 {
			break
		}
	}
	switch len(out) {
	case 0:
		return nil, nil
	case 1:
		return out[0], nil
	default:
		// Multiple outputs (e.g. `.spec.containers[].image`) → treat as a list.
		return out, nil
	}
}
