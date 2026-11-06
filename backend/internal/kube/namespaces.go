package kube

import (
	"context"
	"errors"
	"maps"
	"net/url"
	"slices"
	"strings"
	"sync"
)

// Namespaces is a namespace scope: nil or empty means all namespaces,
// otherwise the namespaces in it (sorted, without duplicates).
type Namespaces []string

// ErrBothNamespaceParams is returned when a request sets both namespace and
// namespaces.
var ErrBothNamespaceParams = errors.New("set namespace or namespaces, not both")

// ParseNamespaces reads the scope of a request: `namespace=a` (one) or
// `namespaces=a,b,c` (a set; repeated parameters are joined). Neither means
// all namespaces.
func ParseNamespaces(q url.Values) (Namespaces, error) {
	one := q.Get("namespace")
	var set []string
	for _, v := range q["namespaces"] {
		for _, ns := range strings.Split(v, ",") {
			if ns = strings.TrimSpace(ns); ns != "" {
				set = append(set, ns)
			}
		}
	}
	if one != "" && len(set) > 0 {
		return nil, ErrBothNamespaceParams
	}
	if one != "" {
		return Namespaces{one}, nil
	}
	return SplitNamespaces(strings.Join(set, ",")), nil
}

// SplitNamespaces parses "a,b" (as Namespaces.String writes it).
func SplitNamespaces(s string) Namespaces {
	var out []string
	for _, ns := range strings.Split(s, ",") {
		if ns = strings.TrimSpace(ns); ns != "" {
			out = append(out, ns)
		}
	}
	if len(out) == 0 {
		return nil
	}
	slices.Sort(out)
	return slices.Compact(out)
}

// All reports whether the scope is every namespace.
func (n Namespaces) All() bool { return len(n) == 0 }

// Single is the one namespace of a one-namespace scope, else "".
func (n Namespaces) Single() string {
	if len(n) == 1 {
		return n[0]
	}
	return ""
}

// Contains reports whether objects in ns are in scope ("" = cluster-scoped
// objects, which every scope includes).
func (n Namespaces) Contains(ns string) bool {
	return len(n) == 0 || ns == "" || slices.Contains(n, ns)
}

// String is the comma-separated form ("" = all).
func (n Namespaces) String() string { return strings.Join(n, ",") }

// Skipped collects the namespaces of a namespace set that could not be
// read (e.g. RBAC forbids them) while a request listed several types, so
// the response can say which were left out. Safe for concurrent use.
type Skipped struct {
	mu    sync.Mutex
	order []string
	errs  map[string]error
}

type skippedKey struct{}

// WithSkipped returns a context whose scoped lists report the namespaces
// they leave out to the returned collector.
func WithSkipped(ctx context.Context) (context.Context, *Skipped) {
	s := &Skipped{errs: map[string]error{}}
	return context.WithValue(ctx, skippedKey{}, s), s
}

// ReportSkipped records that ns was left out because of err. It does
// nothing when ctx has no collector. The first error per namespace is kept.
func ReportSkipped(ctx context.Context, ns string, err error) {
	s, _ := ctx.Value(skippedKey{}).(*Skipped)
	if s == nil || err == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.errs[ns]; !ok {
		s.errs[ns] = err
		s.order = append(s.order, ns)
	}
}

// Each calls f for every skipped namespace, sorted by name.
func (s *Skipped) Each(f func(ns string, err error)) {
	s.mu.Lock()
	names := slices.Clone(s.order)
	errs := maps.Clone(s.errs)
	s.mu.Unlock()
	slices.Sort(names)
	for _, ns := range names {
		f(ns, errs[ns])
	}
}
