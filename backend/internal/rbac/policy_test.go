package rbac

import (
	"slices"
	"strings"
	"testing"

	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func rule(verbs, groups, resources []string, names ...string) rbacv1.PolicyRule {
	return rbacv1.PolicyRule{Verbs: verbs, APIGroups: groups, Resources: resources, ResourceNames: names}
}

func l(s ...string) []string { return s }

func cr(name string, labels map[string]string, agg []map[string]string, rules ...rbacv1.PolicyRule) rbacv1.ClusterRole {
	c := rbacv1.ClusterRole{ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels}, Rules: rules}
	if agg != nil {
		c.AggregationRule = &rbacv1.AggregationRule{}
		for _, m := range agg {
			c.AggregationRule.ClusterRoleSelectors = append(c.AggregationRule.ClusterRoleSelectors, metav1.LabelSelector{MatchLabels: m})
		}
	}
	return c
}

func role(ns, name string, rules ...rbacv1.PolicyRule) rbacv1.Role {
	return rbacv1.Role{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns}, Rules: rules}
}

func sa(ns, name string) rbacv1.Subject {
	return rbacv1.Subject{Kind: rbacv1.ServiceAccountKind, Name: name, Namespace: ns}
}
func user(name string) rbacv1.Subject {
	return rbacv1.Subject{Kind: rbacv1.UserKind, APIGroup: Group, Name: name}
}
func group(name string) rbacv1.Subject {
	return rbacv1.Subject{Kind: rbacv1.GroupKind, APIGroup: Group, Name: name}
}

func rb(ns, name, roleKind, roleName string, subs ...rbacv1.Subject) rbacv1.RoleBinding {
	return rbacv1.RoleBinding{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns}, RoleRef: rbacv1.RoleRef{APIGroup: Group, Kind: roleKind, Name: roleName}, Subjects: subs}
}

func crb(name, roleName string, subs ...rbacv1.Subject) rbacv1.ClusterRoleBinding {
	return rbacv1.ClusterRoleBinding{ObjectMeta: metav1.ObjectMeta{Name: name}, RoleRef: rbacv1.RoleRef{APIGroup: Group, Kind: "ClusterRole", Name: roleName}, Subjects: subs}
}

// fixturePolicy is a small but representative RBAC set (generic names).
func fixturePolicy() *Policy {
	return NewPolicy(
		[]rbacv1.Role{
			role("team-a", "pod-reader", rule(l("get", "list", "watch"), l(""), l("pods", "pods/log"))),
			role("team-a", "one-secret", rule(l("get"), l(""), l("secrets"), "db-creds")),
			role("team-b", "exec", rule(l("create"), l(""), l("pods/*"))), // not a wildcard in RBAC
		},
		[]rbacv1.ClusterRole{
			cr("cluster-admin", nil, nil,
				rule(l("*"), l("*"), l("*")),
				rbacv1.PolicyRule{Verbs: l("*"), NonResourceURLs: l("*")}),
			// Aggregation: admin ⊇ edit ⊇ view, each with an extra role.
			cr("view", map[string]string{"agg/edit": "true"}, []map[string]string{{"agg/view": "true"}}),
			cr("edit", map[string]string{"agg/admin": "true"}, []map[string]string{{"agg/edit": "true"}}),
			cr("admin", nil, []map[string]string{{"agg/admin": "true"}}),
			cr("view-core", map[string]string{"agg/view": "true"}, nil, rule(l("get", "list", "watch"), l("", "apps"), l("pods", "deployments", "configmaps"))),
			cr("edit-core", map[string]string{"agg/edit": "true"}, nil, rule(l("create", "update", "patch", "delete"), l(""), l("pods", "configmaps"))),
			cr("admin-rbac", map[string]string{"agg/admin": "true"}, nil, rule(l("create", "update", "patch", "delete"), l(Group), l("rolebindings", "roles"))),
			// Stored rule the aggregation sources don't declare.
			cr("stale-agg", nil, []map[string]string{{"nothing": "matches"}}, rule(l("get"), l(""), l("services"))),
			cr("node-reader", nil, nil, rule(l("get", "list"), l(""), l("nodes"))),
			cr("logs-anywhere", nil, nil, rule(l("get"), l(""), l("*/log"))),
			cr("health", nil, nil, rbacv1.PolicyRule{Verbs: l("get"), NonResourceURLs: l("/healthz", "/metrics/*")}),
			cr("crd-all-verbs", nil, nil, rule(l("*"), l("example.com"), l("widgets"))),
			cr("impersonator", nil, nil, rule(l("impersonate"), l(""), l("users", "groups"))),
		},
		[]rbacv1.RoleBinding{
			rb("team-a", "readers", "Role", "pod-reader", sa("team-a", "app")),
			rb("team-a", "secret", "Role", "one-secret", sa("team-a", "app")),
			// SA subject with no namespace defaults to the binding's.
			rb("team-a", "edit-for-ci", "ClusterRole", "edit", rbacv1.Subject{Kind: rbacv1.ServiceAccountKind, Name: "ci"}),
			// RoleBinding → ClusterRole: only namespaced resources, only in team-b.
			rb("team-b", "nodes-via-rb", "ClusterRole", "node-reader", user("alice")),
			rb("team-b", "admin", "ClusterRole", "admin", user("alice")),
			rb("team-b", "exec", "Role", "exec", group("devs")),
			rb("team-b", "dangling", "Role", "does-not-exist", user("alice")),
			// Every ServiceAccount in team-c can read crds.
			rb("team-c", "all-sas", "ClusterRole", "crd-all-verbs", group("system:serviceaccounts:team-c")),
		},
		[]rbacv1.ClusterRoleBinding{
			crb("root", "cluster-admin", user("root"), group("system:masters")),
			crb("authenticated-health", "health", group("system:authenticated")),
			crb("log-reader", "logs-anywhere", user("system:serviceaccount:monitoring:collector")),
			crb("stale", "stale-agg", user("bob")),
			crb("imp", "impersonator", user("bob")),
		},
	)
}

func TestAllowed(t *testing.T) {
	p := fixturePolicy()
	appSA := IdentityFor(Subject{Kind: "ServiceAccount", Namespace: "team-a", Name: "app"}, nil)
	ciSA := IdentityFor(Subject{Kind: "ServiceAccount", Namespace: "team-a", Name: "ci"}, nil)
	teamCSA := IdentityFor(Subject{Kind: "ServiceAccount", Namespace: "team-c", Name: "anything"}, nil)
	collector := IdentityFor(Subject{Kind: "ServiceAccount", Namespace: "monitoring", Name: "collector"}, nil)
	alice := IdentityFor(Subject{Kind: "User", Name: "alice"}, nil)
	bob := IdentityFor(Subject{Kind: "User", Name: "bob"}, nil)
	dev := IdentityFor(Subject{Kind: "User", Name: "dave"}, []string{"devs"})
	root := IdentityFor(Subject{Kind: "User", Name: "root"}, nil)
	masters := IdentityFor(Subject{Kind: "Group", Name: "system:masters"}, nil)

	type tc struct {
		name       string
		id         Identity
		req        Request
		namespaced bool
		allow      bool
		// via: substring expected in some path's "binding>role>source+via"
		via string
	}
	res := func(verb, group, resource, ns string) Request {
		r, sub, _ := strings.Cut(resource, "/")
		return Request{Verb: verb, Group: group, Resource: r, Subresource: sub, Namespace: ns}
	}
	cases := []tc{
		// Plain Role in the binding namespace only.
		{"role grants in own ns", appSA, res("list", "", "pods", "team-a"), true, true, "RoleBinding/readers"},
		{"role not in other ns", appSA, res("list", "", "pods", "team-b"), true, false, ""},
		{"role subresource exact", appSA, res("get", "", "pods/log", "team-a"), true, true, "pod-reader"},
		{"role verb not granted", appSA, res("delete", "", "pods", "team-a"), true, false, ""},
		// resourceNames.
		{"named secret allowed", appSA, Request{Verb: "get", Resource: "secrets", Name: "db-creds", Namespace: "team-a"}, true, true, "one-secret"},
		{"other secret denied", appSA, Request{Verb: "get", Resource: "secrets", Name: "other", Namespace: "team-a"}, true, false, ""},
		{"unnamed get never matches resourceNames", appSA, res("get", "", "secrets", "team-a"), true, false, ""},
		// Aggregation: admin → edit → view → view-core.
		{"edit includes view's apps rule", ciSA, res("get", "apps", "deployments", "team-a"), true, true, "ClusterRole/edit>view-core via[view]"},
		{"aggregated edit includes view", ciSA, res("list", "", "configmaps", "team-a"), true, true, "ClusterRole/edit>view-core via[view]"},
		{"aggregated edit own source", ciSA, res("create", "", "pods", "team-a"), true, true, "ClusterRole/edit>edit-core via[]"},
		{"admin aggregates edit and view", alice, res("watch", "", "pods", "team-b"), true, true, "ClusterRole/admin>view-core via[edit view]"},
		{"admin aggregates rbac", alice, res("create", Group, "rolebindings", "team-b"), true, true, "admin-rbac"},
		{"stale stored rule kept", bob, res("get", "", "services", "x"), true, true, "ClusterRole/stale-agg>stale-agg"},
		// SA subject defaults to the binding's namespace.
		{"sa subject ns default", ciSA, res("delete", "", "configmaps", "team-a"), true, true, "RoleBinding/edit-for-ci"},
		// RoleBinding → ClusterRole scoping.
		{"rb→cr namespaced in ns", alice, res("delete", "", "pods", "team-b"), true, true, "RoleBinding/admin"},
		{"rb→cr not other ns", alice, res("delete", "", "pods", "team-a"), true, false, ""},
		{"rb→cr never cluster-scoped", alice, res("get", "", "nodes", "team-b"), false, false, ""},
		{"missing role grants nothing", alice, res("get", "", "configmaps", "team-a"), true, false, ""},
		// Wildcards.
		{"cluster-admin * on *", root, res("delete", "example.com", "widgets", "any"), true, true, "cluster-admin"},
		{"group binding system:masters", masters, res("escalate", Group, "clusterroles", ""), false, true, "ClusterRoleBinding/root"},
		{"*/log matches any subresource log", collector, res("get", "", "pods/log", "kube-system"), true, true, "logs-anywhere"},
		{"*/log does not match parent", collector, res("get", "", "pods", "kube-system"), true, false, ""},
		{"pods/* is not a wildcard", dev, res("create", "", "pods/exec", "team-b"), true, false, ""},
		{"verb * in a crd group", teamCSA, res("deletecollection", "example.com", "widgets", "team-c"), true, true, "system:serviceaccounts:team-c"},
		{"verb * only in its group", teamCSA, res("get", "", "widgets", "team-c"), true, false, ""},
		{"impersonate users", bob, res("impersonate", "", "users", ""), false, true, "impersonator"},
		// Group membership & non-resource URLs.
		{"authenticated nonresource exact", appSA, Request{Verb: "get", Path: "/healthz"}, false, true, "Group/system:authenticated"},
		{"nonresource prefix*", alice, Request{Verb: "get", Path: "/metrics/cadvisor"}, false, true, "health"},
		{"nonresource no prefix match", alice, Request{Verb: "get", Path: "/metricsx"}, false, false, ""},
		{"nonresource verb", alice, Request{Verb: "post", Path: "/healthz"}, false, false, ""},
		{"group-only identity has no system:authenticated", IdentityFor(Subject{Kind: "Group", Name: "devs"}, nil), Request{Verb: "get", Path: "/healthz"}, false, false, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			paths := p.Allowed(c.id, c.req, c.namespaced)
			if got := len(paths) > 0; got != c.allow {
				t.Fatalf("allowed = %v, want %v (paths %+v)", got, c.allow, paths)
			}
			if c.via == "" {
				return
			}
			var descs []string
			for _, pa := range paths {
				d := pa.Binding.Kind + "/" + pa.Binding.Name + " " + pa.Role.Kind + "/" + pa.Role.Name + ">" + pa.Rule.Source.Name +
					" via[" + strings.Join(pa.Rule.Via, " ") + "] " + pa.Subject.Kind + "/" + pa.Subject.Name
				descs = append(descs, d)
				if strings.Contains(d, c.via) {
					return
				}
			}
			t.Fatalf("no path contains %q: %v", c.via, descs)
		})
	}
}

func TestMatrix(t *testing.T) {
	p := fixturePolicy()
	resources := []ResourceInfo{
		{Group: "", Resource: "pods", Namespaced: true},
		{Group: "", Resource: "pods/exec", Namespaced: true},
		{Group: "", Resource: "pods/log", Namespaced: true},
		{Group: "", Resource: "secrets", Namespaced: true},
		{Group: "", Resource: "nodes"},
		{Group: "apps", Resource: "deployments", Namespaced: true},
	}
	alice := IdentityFor(Subject{Kind: "User", Name: "alice"}, nil)

	// Cluster-wide: only ClusterRoleBindings (system:authenticated → health).
	m := p.MatrixFor(alice, "", resources)
	for _, r := range m.Rows {
		if len(r.Cells) > 0 {
			t.Errorf("cluster-wide row %s/%s has cells %v", r.Group, r.Resource, r.Cells)
		}
	}
	if len(m.NonResource) != 1 || !slices.Contains(m.NonResource[0].URLs, "/healthz") {
		t.Errorf("nonResource = %+v", m.NonResource)
	}
	if !slices.Equal(m.RoleBindingNamespaces, []string{"team-b"}) {
		t.Errorf("roleBindingNamespaces = %v", m.RoleBindingNamespaces)
	}
	if len(m.MissingRoles) != 0 {
		t.Errorf("cluster-wide view shouldn't report team-b's dangling binding: %v", m.MissingRoles)
	}

	// team-b: admin (aggregated) on namespaced rows; nodes stays empty.
	m = p.MatrixFor(alice, "team-b", resources)
	row := func(res string) Row {
		for _, r := range m.Rows {
			if r.Resource == res {
				return r
			}
		}
		t.Fatalf("no row %s", res)
		return Row{}
	}
	if c := row("pods").Cells["delete"]; c == nil || len(c.Paths) != 1 {
		t.Errorf("pods delete = %+v", c)
	}
	if len(row("nodes").Cells) != 0 {
		t.Errorf("RoleBinding→ClusterRole must not grant nodes: %v", row("nodes").Cells)
	}
	if row("pods").Cells["*"] != nil {
		t.Errorf("* column only for wildcard verbs")
	}
	if len(m.MissingRoles) != 1 || m.MissingRoles[0].Name != "does-not-exist" {
		t.Errorf("missing roles = %v", m.MissingRoles)
	}

	// resourceNames restrict the cell, and secrets are flagged.
	app := IdentityFor(Subject{Kind: "ServiceAccount", Namespace: "team-a", Name: "app"}, nil)
	m = p.MatrixFor(app, "team-a", resources)
	c := row("secrets").Cells["get"]
	if c == nil || !slices.Equal(c.Names, []string{"db-creds"}) || c.Danger == "" {
		t.Errorf("secrets get = %+v", c)
	}

	// Root: full wildcard, every row & verb incl. "*", virtual rows appear.
	root := IdentityFor(Subject{Kind: "User", Name: "root"}, nil)
	m = p.MatrixFor(root, "", resources)
	if !m.FullWildcard || row("nodes").Cells["*"] == nil || row("pods/exec").Cells["create"].Danger == "" {
		t.Errorf("root matrix: full=%v nodes=%v", m.FullWildcard, row("nodes").Cells)
	}

	// Rules naming resources discovery doesn't serve get a virtual row.
	bob := IdentityFor(Subject{Kind: "User", Name: "bob"}, nil)
	m = p.MatrixFor(bob, "", resources)
	if r := row("users"); !r.Virtual || r.Cells["impersonate"] == nil || r.Cells["impersonate"].Danger == "" {
		t.Errorf("users row = %+v", r)
	}
}

func TestWhoCan(t *testing.T) {
	p := fixturePolicy()
	names := func(r WhoCanResult) []string {
		var out []string
		for _, e := range r.Entries {
			s := e.Subject.Kind + ":" + e.Subject.Name
			if e.Partial {
				s += "(partial " + strings.Join(e.Names, ",") + ")"
			}
			out = append(out, s)
		}
		return out
	}
	r := p.WhoCan(Request{Verb: "get", Resource: "secrets", Namespace: "team-a"}, true)
	want := []string{"User:root", "Group:system:masters", "ServiceAccount:app(partial db-creds)"}
	if got := names(r); !slices.Equal(got, want) {
		t.Errorf("who can get secrets in team-a = %v, want %v", got, want)
	}
	if r.Danger == "" {
		t.Errorf("reading secrets should be flagged")
	}
	if !r.Entries[0].FullWildcard {
		t.Errorf("root should be flagged full wildcard")
	}

	// Named: the restricted grant is now complete.
	r = p.WhoCan(Request{Verb: "get", Resource: "secrets", Namespace: "team-a", Name: "db-creds"}, true)
	if got := names(r); !slices.Contains(got, "ServiceAccount:app") {
		t.Errorf("named = %v", got)
	}

	// Any namespace: RoleBindings everywhere count.
	r = p.WhoCan(Request{Verb: "delete", Resource: "pods", Namespace: "*"}, true)
	got := names(r)
	for _, w := range []string{"User:alice", "ServiceAccount:ci"} {
		if !slices.Contains(got, w) {
			t.Errorf("delete pods anywhere: missing %s in %v", w, got)
		}
	}
	// Cluster-wide only: RoleBindings don't.
	r = p.WhoCan(Request{Verb: "delete", Resource: "pods"}, true)
	if got := names(r); slices.Contains(got, "User:alice") {
		t.Errorf("cluster-wide must ignore RoleBindings: %v", got)
	}
	// Cluster-scoped: RoleBinding→ClusterRole never counts.
	r = p.WhoCan(Request{Verb: "list", Resource: "nodes", Namespace: "*"}, false)
	if got := names(r); slices.Contains(got, "User:alice") {
		t.Errorf("nodes via RoleBinding must not count: %v", got)
	}
}

func TestSubjects(t *testing.T) {
	p := fixturePolicy()
	s := p.Subjects([]Subject{{Namespace: "team-a", Name: "app"}, {Namespace: "team-z", Name: "lonely"}})
	find := func(list []SubjectInfo, name string) *SubjectInfo {
		for i := range list {
			if list[i].Name == name {
				return &list[i]
			}
		}
		return nil
	}
	if a := find(s.ServiceAccounts, "app"); a == nil || a.Bindings != 2 || !a.Exists {
		t.Errorf("app = %+v", a)
	}
	if c := find(s.ServiceAccounts, "ci"); c == nil || c.Namespace != "team-a" || c.Exists {
		t.Errorf("ci (bound, missing) = %+v", c)
	}
	if find(s.ServiceAccounts, "lonely") == nil || find(s.Users, "alice") == nil || find(s.Groups, "devs") == nil {
		t.Errorf("subjects = %+v", s)
	}
}
