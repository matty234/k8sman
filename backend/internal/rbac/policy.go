// Package rbac resolves effective RBAC permissions from Roles, ClusterRoles
// and their bindings, the way the API server's RBAC authorizer does, and
// explains every grant: which binding → which role (through which
// aggregated ClusterRoles) → which rule.
//
// It is pure: callers list the RBAC objects and pass them in. The matching
// rules mirror k8s.io/kubernetes/pkg/apis/rbac/v1/evaluation_helpers.go and
// plugin/pkg/auth/authorizer/rbac (RoleBinding → ClusterRole only applies in
// the binding's namespace, `*/subresource`, resourceNames never match an
// unnamed request, nonResourceURL `prefix*`, ServiceAccount subjects
// defaulting to the binding's namespace).
package rbac

import (
	"slices"
	"sort"
	"strconv"
	"strings"

	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
)

const Group = "rbac.authorization.k8s.io"

// Ref names an RBAC object (Role, ClusterRole or a binding).
type Ref struct {
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace,omitempty"`
}

// Subject is a binding subject (User, Group or ServiceAccount).
type Subject struct {
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace,omitempty"`
}

// Identity is what a request is authorized as: a user name and groups.
type Identity struct {
	User   string   `json:"user,omitempty"`
	Groups []string `json:"groups"`
}

// ServiceAccountUser is the user name a ServiceAccount authenticates as.
func ServiceAccountUser(ns, name string) string { return "system:serviceaccount:" + ns + ":" + name }

// IdentityFor is the identity a subject authenticates as. ServiceAccounts
// belong to system:serviceaccounts, system:serviceaccounts:<ns> and
// system:authenticated; users to system:authenticated (plus extraGroups);
// a Group subject is evaluated as a bare member of that group.
func IdentityFor(s Subject, extraGroups []string) Identity {
	var id Identity
	switch s.Kind {
	case rbacv1.ServiceAccountKind:
		id = Identity{User: ServiceAccountUser(s.Namespace, s.Name),
			Groups: []string{"system:serviceaccounts", "system:serviceaccounts:" + s.Namespace, "system:authenticated"}}
	case rbacv1.GroupKind:
		id = Identity{Groups: []string{s.Name}}
	default:
		g := "system:authenticated"
		if s.Name == "system:anonymous" {
			g = "system:unauthenticated"
		}
		id = Identity{User: s.Name, Groups: []string{g}}
	}
	for _, g := range extraGroups {
		if g != "" && !slices.Contains(id.Groups, g) {
			id.Groups = append(id.Groups, g)
		}
	}
	return id
}

// Policy is an indexed snapshot of a cluster's RBAC objects.
type Policy struct {
	roles        map[string]*rbacv1.Role // ns/name
	clusterRoles map[string]*rbacv1.ClusterRole
	crNames      []string // sorted, for deterministic aggregation order
	crbs         []rbacv1.ClusterRoleBinding
	rbs          []rbacv1.RoleBinding
	ruleCache    map[string][]SourcedRule
}

// NewPolicy indexes the RBAC objects. The slices are read, not copied.
func NewPolicy(roles []rbacv1.Role, clusterRoles []rbacv1.ClusterRole, rbs []rbacv1.RoleBinding, crbs []rbacv1.ClusterRoleBinding) *Policy {
	p := &Policy{roles: map[string]*rbacv1.Role{}, clusterRoles: map[string]*rbacv1.ClusterRole{}, crbs: crbs, rbs: rbs, ruleCache: map[string][]SourcedRule{}}
	for i := range roles {
		p.roles[roles[i].Namespace+"/"+roles[i].Name] = &roles[i]
	}
	for i := range clusterRoles {
		p.clusterRoles[clusterRoles[i].Name] = &clusterRoles[i]
		p.crNames = append(p.crNames, clusterRoles[i].Name)
	}
	sort.Strings(p.crNames)
	sort.SliceStable(p.crbs, func(i, j int) bool { return p.crbs[i].Name < p.crbs[j].Name })
	sort.SliceStable(p.rbs, func(i, j int) bool {
		if p.rbs[i].Namespace != p.rbs[j].Namespace {
			return p.rbs[i].Namespace < p.rbs[j].Namespace
		}
		return p.rbs[i].Name < p.rbs[j].Name
	})
	return p
}

// SourcedRule is a rule plus where it is written down.
type SourcedRule struct {
	Rule rbacv1.PolicyRule `json:"rule"`
	// Source is the role whose .rules holds this rule, Index its position.
	Source Ref `json:"source"`
	Index  int `json:"index"`
	// Via is the aggregation chain from the bound ClusterRole down to (but
	// excluding) Source, e.g. ["admin", "edit"] for a rule of "view" that
	// "edit" aggregates and "admin" aggregates in turn. Empty when the rule
	// is the bound role's own.
	Via []string `json:"via,omitempty"`
}

// RoleRules returns the effective rules of a role, or (nil, false) when it
// doesn't exist. A Role is looked up in ns. For a ClusterRole with an
// aggregationRule the rules are recomputed from the matching ClusterRoles
// (recursively, like the aggregation controller), so each rule is
// attributed to the role that actually declares it; stored rules no source
// declares (e.g. the controller hasn't caught up) are kept as its own.
func (p *Policy) RoleRules(kind, name, ns string) ([]SourcedRule, bool) {
	if kind == "Role" {
		r := p.roles[ns+"/"+name]
		if r == nil {
			return nil, false
		}
		out := make([]SourcedRule, len(r.Rules))
		for i, rule := range r.Rules {
			out[i] = SourcedRule{Rule: rule, Source: Ref{Kind: "Role", Name: name, Namespace: ns}, Index: i}
		}
		return out, true
	}
	if p.clusterRoles[name] == nil {
		return nil, false
	}
	return p.clusterRoleRules(name, map[string]bool{}), true
}

func (p *Policy) clusterRoleRules(name string, visiting map[string]bool) []SourcedRule {
	if rs, ok := p.ruleCache[name]; ok {
		return rs
	}
	cr := p.clusterRoles[name]
	own := func() []SourcedRule {
		out := make([]SourcedRule, len(cr.Rules))
		for i, rule := range cr.Rules {
			out[i] = SourcedRule{Rule: rule, Source: Ref{Kind: "ClusterRole", Name: name}, Index: i}
		}
		return out
	}
	if cr.AggregationRule == nil || len(cr.AggregationRule.ClusterRoleSelectors) == 0 || visiting[name] {
		rs := own()
		if !visiting[name] {
			p.ruleCache[name] = rs
		}
		return rs
	}
	visiting[name] = true
	defer delete(visiting, name)
	var sels []labels.Selector
	for i := range cr.AggregationRule.ClusterRoleSelectors {
		if s, err := metav1.LabelSelectorAsSelector(&cr.AggregationRule.ClusterRoleSelectors[i]); err == nil {
			sels = append(sels, s)
		}
	}
	var out []SourcedRule
	seen := map[string]bool{} // source/index already added
	for _, other := range p.crNames {
		if other == name || visiting[other] {
			continue
		}
		set := labels.Set(p.clusterRoles[other].Labels)
		if !slices.ContainsFunc(sels, func(s labels.Selector) bool { return !s.Empty() && s.Matches(set) }) {
			continue
		}
		for _, sr := range p.clusterRoleRules(other, visiting) {
			k := refKey(sr.Source) + "#" + strconv.Itoa(sr.Index)
			if seen[k] {
				continue
			}
			seen[k] = true
			sr.Via = append([]string{other}, sr.Via...)
			// Via lists the aggregated roles between the bound role and the
			// declaring role; the declaring role itself is Source.
			if sr.Via[len(sr.Via)-1] == sr.Source.Name {
				sr.Via = sr.Via[:len(sr.Via)-1]
			}
			out = append(out, sr)
		}
	}
	// Stored rules that no source declares stay attributed to this role.
	for _, sr := range own() {
		if !slices.ContainsFunc(out, func(o SourcedRule) bool { return ruleEqual(o.Rule, sr.Rule) }) {
			out = append(out, sr)
		}
	}
	p.ruleCache[name] = out
	return out
}

func refKey(r Ref) string { return r.Kind + "/" + r.Namespace + "/" + r.Name }

func ruleEqual(a, b rbacv1.PolicyRule) bool {
	eq := func(x, y []string) bool {
		x, y = slices.Clone(x), slices.Clone(y)
		slices.Sort(x)
		slices.Sort(y)
		return slices.Equal(x, y)
	}
	return eq(a.Verbs, b.Verbs) && eq(a.APIGroups, b.APIGroups) && eq(a.Resources, b.Resources) &&
		eq(a.ResourceNames, b.ResourceNames) && eq(a.NonResourceURLs, b.NonResourceURLs)
}

// AppliesTo reports whether a binding subject names the identity. A
// ServiceAccount subject without a namespace defaults to bindingNS.
func AppliesTo(id Identity, s rbacv1.Subject, bindingNS string) bool {
	switch s.Kind {
	case rbacv1.UserKind:
		return id.User != "" && id.User == s.Name
	case rbacv1.GroupKind:
		return slices.Contains(id.Groups, s.Name)
	case rbacv1.ServiceAccountKind:
		ns := s.Namespace
		if ns == "" {
			ns = bindingNS
		}
		return id.User != "" && id.User == ServiceAccountUser(ns, s.Name)
	}
	return false
}

// Binding is a RoleBinding or ClusterRoleBinding, normalised.
type Binding struct {
	Ref      Ref
	RoleRef  rbacv1.RoleRef
	Subjects []rbacv1.Subject
	// Namespace is "" for ClusterRoleBindings.
	Namespace string
}

// Bindings lists every binding, ClusterRoleBindings first.
func (p *Policy) Bindings() []Binding {
	out := make([]Binding, 0, len(p.crbs)+len(p.rbs))
	for _, b := range p.crbs {
		out = append(out, Binding{Ref: Ref{Kind: "ClusterRoleBinding", Name: b.Name}, RoleRef: b.RoleRef, Subjects: b.Subjects})
	}
	for _, b := range p.rbs {
		out = append(out, Binding{Ref: Ref{Kind: "RoleBinding", Name: b.Name, Namespace: b.Namespace}, RoleRef: b.RoleRef, Subjects: b.Subjects, Namespace: b.Namespace})
	}
	return out
}

// RoleRefOf is the role a binding points at (a Role lives in the binding's
// namespace).
func (b Binding) RoleRefOf() Ref {
	r := Ref{Kind: b.RoleRef.Kind, Name: b.RoleRef.Name}
	if r.Kind == "Role" {
		r.Namespace = b.Namespace
	}
	return r
}

// subjectOf converts an rbacv1 subject, defaulting a ServiceAccount's
// namespace to the binding's.
func subjectOf(s rbacv1.Subject, bindingNS string) Subject {
	out := Subject{Kind: s.Kind, Name: s.Name, Namespace: s.Namespace}
	if s.Kind == rbacv1.ServiceAccountKind && out.Namespace == "" {
		out.Namespace = bindingNS
	}
	if s.Kind != rbacv1.ServiceAccountKind {
		out.Namespace = ""
	}
	return out
}

// ---- rule matching (evaluation_helpers.go) ---------------------------------

func verbMatches(r *rbacv1.PolicyRule, verb string) bool {
	return slices.Contains(r.Verbs, rbacv1.VerbAll) || slices.Contains(r.Verbs, verb)
}

func groupMatches(r *rbacv1.PolicyRule, group string) bool {
	return slices.Contains(r.APIGroups, rbacv1.APIGroupAll) || slices.Contains(r.APIGroups, group)
}

// resourceMatches: "*", an exact "pods/log", or "*/log" for a subresource.
// Note "pods/*" is not a wildcard in Kubernetes RBAC.
func resourceMatches(r *rbacv1.PolicyRule, resource, subresource string) bool {
	combined := resource
	if subresource != "" {
		combined += "/" + subresource
	}
	for _, rr := range r.Resources {
		if rr == rbacv1.ResourceAll || rr == combined {
			return true
		}
		if subresource != "" && rr == "*/"+subresource {
			return true
		}
	}
	return false
}

// nameMatches: an empty resourceNames list matches every name; otherwise
// the request must name one of them (unnamed requests like list or create
// never match).
func nameMatches(r *rbacv1.PolicyRule, name string) bool {
	return len(r.ResourceNames) == 0 || (name != "" && slices.Contains(r.ResourceNames, name))
}

func nonResourceMatches(r *rbacv1.PolicyRule, path string) bool {
	for _, u := range r.NonResourceURLs {
		if u == rbacv1.NonResourceAll || u == path || (strings.HasSuffix(u, "*") && strings.HasPrefix(path, strings.TrimRight(u, "*"))) {
			return true
		}
	}
	return false
}

// Request is one authorization question.
type Request struct {
	Verb        string `json:"verb"`
	Group       string `json:"group"`
	Resource    string `json:"resource"`
	Subresource string `json:"subresource,omitempty"`
	Name        string `json:"name,omitempty"`
	// Namespace "" is a cluster-scoped request (or one across all
	// namespaces); only ClusterRoleBindings apply to it.
	Namespace string `json:"namespace,omitempty"`
	// Path makes it a non-resource request (e.g. /healthz).
	Path string `json:"path,omitempty"`
}

// RuleAllows reports whether one rule allows the request.
func RuleAllows(r *rbacv1.PolicyRule, req Request) bool {
	if !verbMatches(r, req.Verb) {
		return false
	}
	if req.Path != "" {
		return nonResourceMatches(r, req.Path)
	}
	return len(r.Resources) > 0 && groupMatches(r, req.Group) && resourceMatches(r, req.Resource, req.Subresource) && nameMatches(r, req.Name)
}

// Path is one way an identity is granted something: binding → role → rule.
type Path struct {
	Binding     Ref         `json:"binding"`
	Role        Ref         `json:"role"`
	RoleMissing bool        `json:"roleMissing,omitempty"`
	Subject     Subject     `json:"subject"` // the binding subject that matched
	Scope       string      `json:"scope"`   // "cluster" or the binding's namespace
	Rule        SourcedRule `json:"rule"`
}

// Key identifies a path for de-duplication.
func (p Path) Key() string {
	return refKey(p.Binding) + "|" + refKey(p.Rule.Source) + "#" + strconv.Itoa(p.Rule.Index) + "|" + p.Subject.Kind + "/" + p.Subject.Namespace + "/" + p.Subject.Name
}

// bindingApplies: ClusterRoleBindings apply everywhere; a RoleBinding only
// to namespaced requests in its namespace. ns "*" means any namespace.
func bindingApplies(b Binding, ns string) bool {
	return b.Namespace == "" || ns == "*" || b.Namespace == ns
}

// PathsFor lists every rule granted to the identity through bindings that
// apply in ns ("" = ClusterRoleBindings only, "*" = every binding).
// Bindings to a missing role yield one path with RoleMissing set and no rule.
func (p *Policy) PathsFor(id Identity, ns string) []Path {
	var out []Path
	for _, b := range p.Bindings() {
		if !bindingApplies(b, ns) {
			continue
		}
		for _, s := range b.Subjects {
			if !AppliesTo(id, s, b.Namespace) {
				continue
			}
			out = append(out, p.bindingPaths(b, subjectOf(s, b.Namespace))...)
			break // one matching subject is enough to explain the binding
		}
	}
	return out
}

func (p *Policy) bindingPaths(b Binding, sub Subject) []Path {
	scope := "cluster"
	if b.Namespace != "" {
		scope = b.Namespace
	}
	role := b.RoleRefOf()
	rules, ok := p.RoleRules(role.Kind, role.Name, role.Namespace)
	if !ok {
		return []Path{{Binding: b.Ref, Role: role, RoleMissing: true, Subject: sub, Scope: scope}}
	}
	out := make([]Path, 0, len(rules))
	for _, r := range rules {
		out = append(out, Path{Binding: b.Ref, Role: role, Subject: sub, Scope: scope, Rule: r})
	}
	return out
}

// Allowed returns the paths that allow req for the identity (empty =
// denied by RBAC). namespaced says whether the resource is namespaced: a
// RoleBinding never grants cluster-scoped resources or non-resource URLs.
func (p *Policy) Allowed(id Identity, req Request, namespaced bool) []Path {
	ns := req.Namespace
	if req.Path != "" || !namespaced {
		ns = ""
	}
	var out []Path
	for _, path := range p.PathsFor(id, ns) {
		if !path.RoleMissing && RuleAllows(&path.Rule.Rule, req) {
			out = append(out, path)
		}
	}
	return out
}
