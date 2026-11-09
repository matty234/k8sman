package rbac

import (
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
