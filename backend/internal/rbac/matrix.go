package rbac

import (
	"slices"
	"sort"
	"strings"

	rbacv1 "k8s.io/api/rbac/v1"
)

// Verbs are the matrix columns, in order. Other verbs found in rules
// (approve, sign, use, …) are appended after these.
var Verbs = []string{"get", "list", "watch", "create", "update", "patch", "delete", "deletecollection", "escalate", "bind", "impersonate", "*"}

// ResourceInfo is one row candidate: a discovered resource or subresource.
type ResourceInfo struct {
	Group      string   `json:"group"`
	Version    string   `json:"version,omitempty"`
	Resource   string   `json:"resource"` // "pods" or "pods/exec"
	Kind       string   `json:"kind,omitempty"`
	Namespaced bool     `json:"namespaced"`
	Verbs      []string `json:"verbs,omitempty"`
	// Virtual: not served as an API resource but authorized by RBAC
	// (impersonation targets, signers) or only named by a rule.
	Virtual bool `json:"virtual,omitempty"`
}

func (r ResourceInfo) split() (string, string) {
	res, sub, _ := strings.Cut(r.Resource, "/")
	return res, sub
}

// VirtualResources are authorized by RBAC without being API resources.
var VirtualResources = []ResourceInfo{
	{Group: "", Resource: "users", Verbs: []string{"impersonate"}, Virtual: true},
	{Group: "", Resource: "groups", Verbs: []string{"impersonate"}, Virtual: true},
	{Group: "authentication.k8s.io", Resource: "uids", Verbs: []string{"impersonate"}, Virtual: true},
	{Group: "authentication.k8s.io", Resource: "userextras/scopes", Verbs: []string{"impersonate"}, Virtual: true},
	{Group: "certificates.k8s.io", Resource: "signers", Verbs: []string{"approve", "sign", "attest"}, Virtual: true},
}

// Cell is one resource × verb intersection.
type Cell struct {
	// Paths index Matrix.Paths: every grant that allows this.
	Paths []int `json:"paths"`
	// Names is set when every granting rule is limited to resourceNames:
	// only these objects are allowed.
	Names  []string `json:"names,omitempty"`
	Danger string   `json:"danger,omitempty"`
}

// Row is one resource of the matrix.
type Row struct {
	Group      string           `json:"group"`
	Resource   string           `json:"resource"`
	Kind       string           `json:"kind,omitempty"`
	Namespaced bool             `json:"namespaced"`
	Virtual    bool             `json:"virtual,omitempty"`
	Verbs      []string         `json:"verbs,omitempty"` // verbs the resource supports (discovery)
	Cells      map[string]*Cell `json:"cells"`
}

// NonResourceGrant is one nonResourceURL rule.
type NonResourceGrant struct {
	URLs  []string `json:"urls"`
	Verbs []string `json:"verbs"`
	Paths []int    `json:"paths"`
}

// BindingSummary is a binding that names the subject.
type BindingSummary struct {
	Binding     Ref     `json:"binding"`
	Role        Ref     `json:"role"`
	RoleMissing bool    `json:"roleMissing,omitempty"`
	Subject     Subject `json:"subject"` // the matching subject in the binding
	Scope       string  `json:"scope"`
	// Inherited: the subject matched through a group, not by name.
	Inherited bool `json:"inherited,omitempty"`
}

// Matrix is a subject's effective permissions.
type Matrix struct {
	Subject   *Subject `json:"subject,omitempty"`
	Identity  Identity `json:"identity"`
	Namespace string   `json:"namespace"` // "" = cluster-wide
	Verbs     []string `json:"verbs"`
	Rows      []Row    `json:"rows"`
	Paths     []Path   `json:"paths"`
	// NonResource lists nonResourceURL grants (ClusterRoleBindings only).
	NonResource []NonResourceGrant `json:"nonResource"`
	// FullWildcard: some rule grants * on * in every group.
	FullWildcard bool `json:"fullWildcard"`
	// Bindings names the subject anywhere; RoleBindingNamespaces lists the
	// namespaces where RoleBindings add to what's shown cluster-wide.
	Bindings              []BindingSummary `json:"bindings"`
	RoleBindingNamespaces []string         `json:"roleBindingNamespaces"`
	// Missing roles referenced by applicable bindings.
	MissingRoles []Ref `json:"missingRoles,omitempty"`
}

// MatrixFor computes the identity's permissions in ns ("" = cluster-wide:
// cluster-scoped resources, and namespaced ones in every namespace).
func (p *Policy) MatrixFor(id Identity, ns string, resources []ResourceInfo) Matrix {
	m := BuildMatrix(p.PathsFor(id, ns), ns, resources)
	m.Identity = id
	seenNS := map[string]bool{}
	for _, b := range p.Bindings() {
		for _, s := range b.Subjects {
			if !AppliesTo(id, s, b.Namespace) {
				continue
			}
			sub := subjectOf(s, b.Namespace)
			scope := "cluster"
			if b.Namespace != "" {
				scope = b.Namespace
				seenNS[b.Namespace] = true
			}
			role := b.RoleRefOf()
			_, ok := p.RoleRules(role.Kind, role.Name, role.Namespace)
			m.Bindings = append(m.Bindings, BindingSummary{Binding: b.Ref, Role: role, RoleMissing: !ok, Subject: sub, Scope: scope,
				Inherited: s.Kind == rbacv1.GroupKind})
			break
		}
	}
	m.RoleBindingNamespaces = sortedKeys(seenNS)
	return m
}

// BuildMatrix lays paths out as a resource × verb matrix. Paths from
// RoleBindings (Scope != "cluster") only fill namespaced rows; ns is only
// used for danger labels.
func BuildMatrix(paths []Path, ns string, resources []ResourceInfo) Matrix {
	m := Matrix{Namespace: ns, Paths: []Path{}, Rows: []Row{}, NonResource: []NonResourceGrant{}, Bindings: []BindingSummary{}, RoleBindingNamespaces: []string{}}
	extraVerbs := map[string]bool{}
	missing := map[string]Ref{}
	for _, path := range paths {
		if path.RoleMissing {
			missing[refKey(path.Role)] = path.Role
			continue
		}
		r := path.Rule.Rule
		i := len(m.Paths)
		m.Paths = append(m.Paths, path)
		for _, v := range r.Verbs {
			if !slices.Contains(Verbs, v) {
				extraVerbs[v] = true
			}
		}
		if slices.Contains(r.Verbs, "*") && slices.Contains(r.Resources, "*") && slices.Contains(r.APIGroups, "*") && len(r.ResourceNames) == 0 {
			m.FullWildcard = true
		}
		if len(r.NonResourceURLs) > 0 && path.Scope == "cluster" {
			m.NonResource = append(m.NonResource, NonResourceGrant{URLs: r.NonResourceURLs, Verbs: r.Verbs, Paths: []int{i}})
		}
	}
	m.Verbs = append(slices.Clone(Verbs), sortedKeys(extraVerbs)...)
	for _, ref := range missing {
		m.MissingRoles = append(m.MissingRoles, ref)
	}
	sort.Slice(m.MissingRoles, func(i, j int) bool { return refKey(m.MissingRoles[i]) < refKey(m.MissingRoles[j]) })

	for _, ri := range rowsFor(m.Paths, resources) {
		res, sub := ri.split()
		row := Row{Group: ri.Group, Resource: ri.Resource, Kind: ri.Kind, Namespaced: ri.Namespaced, Virtual: ri.Virtual, Verbs: ri.Verbs, Cells: map[string]*Cell{}}
		for i, path := range m.Paths {
			if path.Scope != "cluster" && !ri.Namespaced {
				continue // RoleBindings never grant cluster-scoped resources
			}
			r := &path.Rule.Rule
			if len(r.Resources) == 0 || !groupMatches(r, ri.Group) || !resourceMatches(r, res, sub) {
				continue
			}
			for _, v := range m.Verbs {
				if v == "*" {
					if !slices.Contains(r.Verbs, "*") {
						continue
					}
				} else if !verbMatches(r, v) {
					continue
				}
				c := row.Cells[v]
				if c == nil {
					c = &Cell{Paths: []int{}}
					row.Cells[v] = c
				}
				c.Paths = append(c.Paths, i)
			}
		}
		for v, c := range row.Cells {
			// Restricted to names only when no granting rule is unrestricted.
			var names []string
			unrestricted := false
			for _, i := range c.Paths {
				rn := m.Paths[i].Rule.Rule.ResourceNames
				if len(rn) == 0 {
					unrestricted = true
					break
				}
				names = append(names, rn...)
			}
			if !unrestricted {
				slices.Sort(names)
				c.Names = slices.Compact(names)
			}
			c.Danger = Danger(ri.Group, ri.Resource, v, ns)
		}
		m.Rows = append(m.Rows, row)
	}
	return m
}

// rowsFor is every discovered resource plus anything a rule names
// explicitly that discovery doesn't serve (uninstalled CRDs, virtual
// resources), sorted by group then resource.
func rowsFor(paths []Path, resources []ResourceInfo) []ResourceInfo {
	seen := map[string]bool{}
	var out []ResourceInfo
	add := func(r ResourceInfo) {
		k := r.Group + "/" + r.Resource
		if !seen[k] {
			seen[k] = true
			out = append(out, r)
		}
	}
	for _, r := range resources {
		add(r)
	}
	byName := map[string][]ResourceInfo{}
	for _, r := range out {
		byName[r.Resource] = append(byName[r.Resource], r)
	}
	virtual := map[string]ResourceInfo{}
	for _, v := range VirtualResources {
		virtual[v.Group+"/"+v.Resource] = v
	}
	for _, path := range paths {
		r := path.Rule.Rule
		for _, res := range r.Resources {
			if res == "*" || strings.HasPrefix(res, "*/") {
				continue
			}
			for _, g := range r.APIGroups {
				if g == "*" {
					if len(byName[res]) == 0 {
						add(ResourceInfo{Group: "*", Resource: res, Namespaced: true, Virtual: true})
					}
					continue
				}
				if v, ok := virtual[g+"/"+res]; ok {
					add(v)
				} else if !seen[g+"/"+res] {
					// Named by a rule but not served: assume namespaced so
					// RoleBindings show up too.
					add(ResourceInfo{Group: g, Resource: res, Namespaced: true, Virtual: true})
				}
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Group != out[j].Group {
			return groupOrder(out[i].Group) < groupOrder(out[j].Group)
		}
		return out[i].Resource < out[j].Resource
	})
	return out
}

// groupOrder sorts the core group first.
func groupOrder(g string) string {
	if g == "" {
		return ""
	}
	return "~" + g
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Danger labels a grant that amounts to privilege escalation or broad data
// access; "" when it isn't notable. ns is the scope ("" = cluster-wide).
func Danger(group, resource, verb, ns string) string {
	allVerbs := verb == "*"
	is := func(vs ...string) bool { return allVerbs || slices.Contains(vs, verb) }
	switch {
	case group == "" && resource == "secrets" && is("get", "list", "watch"):
		return "Reads Secrets (including ServiceAccount tokens)"
	case group == "" && (resource == "pods/exec" || resource == "pods/attach") && is("create", "get"):
		return "Runs commands inside pods"
	case group == "" && resource == "nodes/proxy" && is("get", "create"):
		return "Direct kubelet API access (exec into any pod on the node)"
	case group == Group && (resource == "roles" || resource == "clusterroles") && is("escalate", "bind"):
		return "Can grant permissions it doesn't hold (escalate/bind)"
	case is("impersonate") && verb != "*":
		return "Can act as other users, groups or ServiceAccounts"
	case group == "" && resource == "serviceaccounts/token" && is("create"):
		return "Can mint ServiceAccount tokens"
	case group == "" && resource == "pods" && is("create") && (ns == "" || ns == "kube-system"):
		return "Can create pods in kube-system (run as any system ServiceAccount)"
	case group == Group && is("create", "update", "patch") && (resource == "rolebindings" || resource == "clusterrolebindings" || resource == "roles" || resource == "clusterroles"):
		return "Can change RBAC"
	}
	return ""
}

// WhoCanEntry is one subject that can perform a request, with every path.
type WhoCanEntry struct {
	Subject Subject `json:"subject"`
	Paths   []Path  `json:"paths"`
	// Partial: every path is limited to resourceNames that don't include
	// the requested name (or no name was given): Names lists them.
	Partial bool     `json:"partial,omitempty"`
	Names   []string `json:"names,omitempty"`
	// FullWildcard: granted through * on * (cluster-admin equivalent).
	FullWildcard bool `json:"fullWildcard,omitempty"`
	// Scopes are where the grant applies ("cluster" or namespaces).
	Scopes []string `json:"scopes"`
}

// WhoCanResult answers "who can <verb> <resource>".
type WhoCanResult struct {
	Request Request       `json:"request"`
	Danger  string        `json:"danger,omitempty"`
	Entries []WhoCanEntry `json:"entries"`
}

// WhoCan lists every binding subject that can perform req. With
// req.Namespace "*" RoleBindings in any namespace count. Grants limited to
// resourceNames are included as partial when the request has no name.
func (p *Policy) WhoCan(req Request, namespaced bool) WhoCanResult {
	res := WhoCanResult{Request: req, Danger: Danger(req.Group, combined(req), req.Verb, strings.TrimPrefix(req.Namespace, "*")), Entries: []WhoCanEntry{}}
	ns := req.Namespace
	if req.Path != "" || !namespaced {
		ns = ""
	}
	byKey := map[string]*WhoCanEntry{}
	var order []string
	for _, b := range p.Bindings() {
		if !bindingApplies(b, ns) {
			continue
		}
		var matched []Path
		partial := true
		var names []string
		for _, path := range p.bindingPaths(b, Subject{}) {
			if path.RoleMissing {
				continue
			}
			r := &path.Rule.Rule
			probe := req
			full := RuleAllows(r, probe)
			if !full && req.Name == "" && len(r.ResourceNames) > 0 {
				probe.Name = r.ResourceNames[0]
				if RuleAllows(r, probe) {
					matched = append(matched, path)
					names = append(names, r.ResourceNames...)
				}
				continue
			}
			if full {
				matched = append(matched, path)
				partial = false
			}
		}
		if len(matched) == 0 {
			continue
		}
		for _, s := range b.Subjects {
			sub := subjectOf(s, b.Namespace)
			k := sub.Kind + "/" + sub.Namespace + "/" + sub.Name
			e := byKey[k]
			if e == nil {
				e = &WhoCanEntry{Subject: sub, Partial: true, Scopes: []string{}}
				byKey[k] = e
				order = append(order, k)
			}
			for _, path := range matched {
				path.Subject = sub
				e.Paths = append(e.Paths, path)
				r := path.Rule.Rule
				if slices.Contains(r.Verbs, "*") && slices.Contains(r.Resources, "*") && slices.Contains(r.APIGroups, "*") {
					e.FullWildcard = true
				}
				if !slices.Contains(e.Scopes, path.Scope) {
					e.Scopes = append(e.Scopes, path.Scope)
				}
			}
			if !partial {
				e.Partial = false
				e.Names = nil
			} else if e.Partial {
				e.Names = append(e.Names, names...)
			}
		}
	}
	for _, k := range order {
		e := byKey[k]
		if e.Partial {
			slices.Sort(e.Names)
			e.Names = slices.Compact(e.Names)
		} else {
			e.Names = nil
		}
		res.Entries = append(res.Entries, *e)
	}
	sort.SliceStable(res.Entries, func(i, j int) bool {
		a, b := res.Entries[i], res.Entries[j]
		if a.Partial != b.Partial {
			return !a.Partial
		}
		if subjectRank(a.Subject) != subjectRank(b.Subject) {
			return subjectRank(a.Subject) < subjectRank(b.Subject)
		}
		return a.Subject.Namespace+"/"+a.Subject.Name < b.Subject.Namespace+"/"+b.Subject.Name
	})
	return res
}

func combined(req Request) string {
	if req.Subresource != "" {
		return req.Resource + "/" + req.Subresource
	}
	return req.Resource
}

func subjectRank(s Subject) int {
	switch s.Kind {
	case rbacv1.UserKind:
		return 0
	case rbacv1.GroupKind:
		return 1
	}
	return 2
}

// SubjectList is every subject the cluster's bindings name, plus the
// ServiceAccounts that exist.
type SubjectList struct {
	ServiceAccounts []SubjectInfo `json:"serviceAccounts"`
	Users           []SubjectInfo `json:"users"`
	Groups          []SubjectInfo `json:"groups"`
}

// SubjectInfo is a subject and how many bindings name it.
type SubjectInfo struct {
	Subject
	Bindings int `json:"bindings"`
	// Exists is false for ServiceAccounts bindings name but that don't exist.
	Exists bool `json:"exists"`
}

// Subjects collects binding subjects; serviceAccounts are the existing SAs
// ("namespace/name"), nil when they couldn't be listed.
func (p *Policy) Subjects(serviceAccounts []Subject) SubjectList {
	count := map[string]int{}
	info := map[string]Subject{}
	for _, b := range p.Bindings() {
		for _, s := range b.Subjects {
			sub := subjectOf(s, b.Namespace)
			k := sub.Kind + "/" + sub.Namespace + "/" + sub.Name
			count[k]++
			info[k] = sub
		}
	}
	exists := map[string]bool{}
	for _, sa := range serviceAccounts {
		sa.Kind = rbacv1.ServiceAccountKind
		k := sa.Kind + "/" + sa.Namespace + "/" + sa.Name
		exists[k] = true
		info[k] = sa
	}
	out := SubjectList{ServiceAccounts: []SubjectInfo{}, Users: []SubjectInfo{}, Groups: []SubjectInfo{}}
	keys := make([]string, 0, len(info))
	for k := range info {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		s := info[k]
		si := SubjectInfo{Subject: s, Bindings: count[k], Exists: true}
		switch s.Kind {
		case rbacv1.ServiceAccountKind:
			si.Exists = serviceAccounts == nil || exists[k]
			out.ServiceAccounts = append(out.ServiceAccounts, si)
		case rbacv1.GroupKind:
			out.Groups = append(out.Groups, si)
		default:
			out.Users = append(out.Users, si)
		}
	}
	return out
}

// RoleMatrix lays out one role's rules (for the inspector's compact view).
// A ClusterRole's rules fill every row; a Role's only namespaced ones.
func (p *Policy) RoleMatrix(kind, name, ns string, resources []ResourceInfo) (Matrix, bool) {
	rules, ok := p.RoleRules(kind, name, ns)
	if !ok {
		return Matrix{}, false
	}
	role := Ref{Kind: kind, Name: name, Namespace: ns}
	scope := "cluster"
	if kind == "Role" {
		scope = ns
	}
	paths := make([]Path, len(rules))
	for i, r := range rules {
		paths[i] = Path{Role: role, Scope: scope, Rule: r}
	}
	return BuildMatrix(paths, ns, resources), true
}

// RulesMatrix lays out bare rules (e.g. from a SelfSubjectRulesReview),
// attributed to source.
func RulesMatrix(rules []rbacv1.PolicyRule, source Ref, ns string, resources []ResourceInfo) Matrix {
	paths := make([]Path, len(rules))
	for i, r := range rules {
		paths[i] = Path{Role: source, Scope: "cluster", Rule: SourcedRule{Rule: r, Source: source, Index: i}}
	}
	return BuildMatrix(paths, ns, resources)
}
