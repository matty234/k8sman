package security

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

var now = time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)

func ptr[T any](v T) *T { return &v }

func meta(ns, name string, labels map[string]string) metav1.ObjectMeta {
	return metav1.ObjectMeta{Namespace: ns, Name: name, Labels: labels}
}

func ownedBy(apiVersion, kind, name string) []metav1.OwnerReference {
	return []metav1.OwnerReference{{APIVersion: apiVersion, Kind: kind, Name: name, Controller: ptr(true)}}
}

// hardened is a container that passes every check.
func hardened(name, image string) corev1.Container {
	return corev1.Container{
		Name: name, Image: image,
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("10m"), corev1.ResourceMemory: resource.MustParse("16Mi")},
			Limits:   corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("64Mi")},
		},
		ReadinessProbe: &corev1.Probe{},
		SecurityContext: &corev1.SecurityContext{
			RunAsNonRoot:             ptr(true),
			AllowPrivilegeEscalation: ptr(false),
			ReadOnlyRootFilesystem:   ptr(true),
			SeccompProfile:           &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault},
			Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
		},
	}
}

func hardenedSpec() corev1.PodSpec {
	return corev1.PodSpec{ServiceAccountName: "app", AutomountServiceAccountToken: ptr(false), Containers: []corev1.Container{hardened("app", "example/app:1.0")}}
}

func deployment(ns, name string, labels map[string]string, spec corev1.PodSpec) appsv1.Deployment {
	return appsv1.Deployment{ObjectMeta: meta(ns, name, nil), Spec: appsv1.DeploymentSpec{
		Selector: &metav1.LabelSelector{MatchLabels: labels},
		Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: labels}, Spec: spec},
	}}
}

func find(res *Result, check string) []Finding {
	var out []Finding
	for _, f := range res.Findings {
		if f.Check == check {
			out = append(out, f)
		}
	}
	return out
}

func findOne(t *testing.T, res *Result, check string) Finding {
	t.Helper()
	fs := find(res, check)
	if len(fs) != 1 {
		t.Fatalf("want 1 %s finding, got %d: %+v", check, len(fs), fs)
	}
	return fs[0]
}

func hasObj(f Finding, kind, name string) bool {
	for _, o := range f.Objects {
		if o.Kind == kind && o.Name == name {
			return true
		}
	}
	return false
}

// ---- network policy semantics ---------------------------------------------

func np(ns, name string, sel metav1.LabelSelector, types []networkingv1.PolicyType, in []networkingv1.NetworkPolicyIngressRule, eg []networkingv1.NetworkPolicyEgressRule) networkingv1.NetworkPolicy {
	return networkingv1.NetworkPolicy{ObjectMeta: meta(ns, name, nil), Spec: networkingv1.NetworkPolicySpec{PodSelector: sel, PolicyTypes: types, Ingress: in, Egress: eg}}
}

var (
	ingressT = []networkingv1.PolicyType{networkingv1.PolicyTypeIngress}
	egressT  = []networkingv1.PolicyType{networkingv1.PolicyTypeEgress}
	bothT    = []networkingv1.PolicyType{networkingv1.PolicyTypeIngress, networkingv1.PolicyTypeEgress}
	all      = metav1.LabelSelector{}
	web      = map[string]string{"app": "web"}
)

func TestNetworkFindingsAndMatrix(t *testing.T) {
	in := Input{
		Now: now,
		Namespaces: []corev1.Namespace{
			{ObjectMeta: meta("", "open", nil)},
			{ObjectMeta: meta("", "partial", nil)},
			{ObjectMeta: meta("", "locked", map[string]string{"pod-security.kubernetes.io/enforce": "restricted"})},
			{ObjectMeta: meta("", "empty", nil)},
			{ObjectMeta: meta("", "kube-system", nil)},
		},
		Deployments: []appsv1.Deployment{
			deployment("open", "web", web, hardenedSpec()),
			deployment("partial", "web", web, hardenedSpec()),
			deployment("partial", "db", map[string]string{"app": "db"}, hardenedSpec()),
			deployment("locked", "web", web, hardenedSpec()),
			deployment("kube-system", "dns", map[string]string{"k8s-app": "dns"}, hardenedSpec()),
		},
		NetworkPolicies: []networkingv1.NetworkPolicy{
			np("partial", "db-only", metav1.LabelSelector{MatchLabels: map[string]string{"app": "db"}}, ingressT,
				[]networkingv1.NetworkPolicyIngressRule{{From: []networkingv1.NetworkPolicyPeer{{PodSelector: &metav1.LabelSelector{MatchLabels: web}}}}}, nil),
			np("locked", "deny", all, bothT, nil, nil),
			np("locked", "public", metav1.LabelSelector{MatchLabels: web}, ingressT,
				[]networkingv1.NetworkPolicyIngressRule{{From: []networkingv1.NetworkPolicyPeer{{IPBlock: &networkingv1.IPBlock{CIDR: "0.0.0.0/0"}}}}}, nil),
		},
	}
	res := Analyze(in)

	noPol := findOne(t, res, "network.no-policy")
	if noPol.Severity != Medium || !hasObj(noPol, "Namespace", "open") || hasObj(noPol, "Namespace", "empty") || hasObj(noPol, "Namespace", "kube-system") {
		t.Errorf("no-policy should list open only (empty has no workloads, kube-system is system): %+v", noPol)
	}
	unr := find(res, "network.ingress-unrestricted")
	if len(unr) != 2 {
		t.Fatalf("partial and locked: %+v", unr)
	}
	for _, f := range unr {
		// partial: web is unprotected, db is protected. locked: web is
		// isolated by the default deny but "public" re-opens it to 0.0.0.0/0.
		if !hasObj(f, "Deployment", "web") || hasObj(f, "Deployment", "db") || f.Title != "1 workload in "+f.Namespace+" accepts ingress from anywhere" {
			t.Errorf("unrestricted: %+v", f)
		}
	}
	ndd := findOne(t, res, "network.no-default-deny")
	if !hasObj(ndd, "Namespace", "partial") || hasObj(ndd, "Namespace", "locked") {
		t.Errorf("no-default-deny: %+v", ndd)
	}
	anyIn := findOne(t, res, "network.policy-allows-any-ingress")
	if !hasObj(anyIn, "NetworkPolicy", "public") {
		t.Errorf("allow-any: %+v", anyIn)
	}

	rows := map[string]NamespaceNetwork{}
	for _, r := range res.Network {
		rows[r.Namespace] = r
	}
	if _, ok := rows["kube-system"]; ok {
		t.Error("kube-system excluded by default")
	}
	if r := rows["open"]; r.Ingress != ModeOpen || r.Egress != ModeOpen || r.Policies != 0 || r.IngressOpen != 1 {
		t.Errorf("open row: %+v", r)
	}
	if r := rows["partial"]; r.Ingress != ModePartial || r.Egress != ModeOpen || r.IngressOpen != 1 {
		t.Errorf("partial row: %+v", r)
	}
	// locked/web is isolated but a policy re-opens it to 0.0.0.0/0.
	if r := rows["locked"]; r.Ingress != ModeDenyAll || r.Egress != ModeDenyAll || r.IngressOpen != 1 || r.PSA != "restricted" {
		t.Errorf("locked row: %+v", r)
	}

	in.IncludeSystem = true
	res = Analyze(in)
	if !hasObj(findOne(t, res, "network.no-policy"), "Namespace", "kube-system") {
		t.Error("includeSystem includes kube-system")
	}
}

func TestExposure(t *testing.T) {
	lb := corev1.Service{ObjectMeta: meta("app", "public", nil), Spec: corev1.ServiceSpec{
		Type: corev1.ServiceTypeLoadBalancer, Selector: web, Ports: []corev1.ServicePort{{Port: 80, NodePort: 31000}},
	}}
	restricted := lb
	restricted.Name = "restricted"
	restricted.Spec.LoadBalancerSourceRanges = []string{"203.0.113.0/24"}
	np := corev1.Service{ObjectMeta: meta("app", "np", nil), Spec: corev1.ServiceSpec{
		Type: corev1.ServiceTypeNodePort, Selector: web, Ports: []corev1.ServicePort{{Port: 22, NodePort: 22}},
	}}
	ext := corev1.Service{ObjectMeta: meta("app", "ext", nil), Spec: corev1.ServiceSpec{Selector: web, ExternalIPs: []string{"1.2.3.4"}, Ports: []corev1.ServicePort{{Port: 80}}}}
	ing := networkingv1.Ingress{ObjectMeta: meta("app", "site", nil), Spec: networkingv1.IngressSpec{
		TLS: []networkingv1.IngressTLS{{Hosts: []string{"secure.example.com"}}},
		Rules: []networkingv1.IngressRule{
			{Host: "secure.example.com", IngressRuleValue: networkingv1.IngressRuleValue{HTTP: &networkingv1.HTTPIngressRuleValue{Paths: []networkingv1.HTTPIngressPath{{Backend: networkingv1.IngressBackend{Service: &networkingv1.IngressServiceBackend{Name: "public"}}}}}}},
			{Host: "plain.example.com", IngressRuleValue: networkingv1.IngressRuleValue{HTTP: &networkingv1.HTTPIngressRuleValue{Paths: []networkingv1.HTTPIngressPath{{Backend: networkingv1.IngressBackend{Service: &networkingv1.IngressServiceBackend{Name: "public"}}}}}}},
		},
	}}
	gw := unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "gateway.networking.k8s.io/v1", "kind": "Gateway",
		"metadata": map[string]any{"namespace": "app", "name": "gw"},
		"spec": map[string]any{"listeners": []any{
			map[string]any{"name": "http", "protocol": "HTTP", "port": int64(80)},
			map[string]any{"name": "https", "protocol": "HTTPS", "port": int64(443), "hostname": "x.example.com"},
		}},
	}}
	route := unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
		"metadata": map[string]any{"namespace": "app", "name": "route"},
		"spec": map[string]any{
			"parentRefs": []any{map[string]any{"name": "gw"}},
			"rules":      []any{map[string]any{"backendRefs": []any{map[string]any{"name": "public", "port": int64(80)}}}},
		},
	}}
	hostPortSpec := hardenedSpec()
	hostPortSpec.Containers[0].Ports = []corev1.ContainerPort{{ContainerPort: 9100, HostPort: 9100}}
	in := Input{
		Now:         now,
		Deployments: []appsv1.Deployment{deployment("app", "web", web, hardenedSpec()), deployment("app", "agent", map[string]string{"app": "agent"}, hostPortSpec)},
		Services:    []corev1.Service{lb, restricted, np, ext},
		Ingresses:   []networkingv1.Ingress{ing},
		Gateways:    []unstructured.Unstructured{gw},
		HTTPRoutes:  []unstructured.Unstructured{route},
	}
	res := Analyze(in)
	lbs := find(res, "network.loadbalancer")
	if len(lbs) != 2 {
		t.Fatalf("two LBs: %+v", lbs)
	}
	for _, f := range lbs {
		switch {
		case strings.Contains(f.Title, "public"):
			if f.Severity != High || !hasObj(f, "Deployment", "web") || !strings.Contains(f.Detail, "not protected") {
				t.Errorf("unrestricted LB to unprotected pods is high: %+v", f)
			}
		default:
			if f.Severity != Low || !strings.Contains(f.Detail, "203.0.113.0/24") {
				t.Errorf("source-ranged LB is low: %+v", f)
			}
		}
	}
	if f := findOne(t, res, "network.nodeport"); f.Severity != Medium {
		t.Errorf("nodeport to unprotected pods: %+v", f)
	}
	if f := findOne(t, res, "practices.privileged-nodeport"); !strings.Contains(f.Detail, "22") {
		t.Errorf("privileged node port: %+v", f)
	}
	findOne(t, res, "network.externalips")
	if f := findOne(t, res, "network.ingress"); f.Severity != Info || !hasObj(f, "Service", "public") || !hasObj(f, "Deployment", "web") {
		t.Errorf("ingress exposure: %+v", f)
	}
	if f := findOne(t, res, "practices.ingress-no-tls"); !strings.Contains(f.Title, "plain.example.com") || strings.Contains(f.Title, "secure.example.com") {
		t.Errorf("ingress tls: %+v", f)
	}
	g := findOne(t, res, "network.gateway")
	if !hasObj(g, "HTTPRoute", "route") || !hasObj(g, "Deployment", "web") || !strings.Contains(g.Detail, "HTTP *:80") {
		t.Errorf("gateway: %+v", g)
	}
	findOne(t, res, "practices.gateway-no-tls")
	if f := findOne(t, res, "network.host-network"); !hasObj(f, "Deployment", "agent") || !strings.Contains(f.Title, "9100") {
		t.Errorf("hostPort: %+v", f)
	}
	if !res.Sources.GatewayAPI {
		t.Error("gateway API source")
	}
	if r := res.Network[0]; r.Exposed != 6 { // lb, restricted, np, ext, ingress, gateway
		t.Errorf("exposed count: %+v", r)
	}

	// Protect web with a default-deny ingress: the LB drops to medium.
	in.NetworkPolicies = []networkingv1.NetworkPolicy{npDeny("app")}
	res = Analyze(in)
	for _, f := range find(res, "network.loadbalancer") {
		if strings.Contains(f.Title, "public") && (f.Severity != Medium || !strings.Contains(f.Detail, "are protected")) {
			t.Errorf("LB to protected pods is medium: %+v", f)
		}
	}
}

func npDeny(ns string) networkingv1.NetworkPolicy {
	return np(ns, "default-deny", all, bothT, nil, nil)
}

// ---- RBAC -----------------------------------------------------------------

func rule(groups, resources, verbs []string) rbacv1.PolicyRule {
	return rbacv1.PolicyRule{APIGroups: groups, Resources: resources, Verbs: verbs}
}

func s(v ...string) []string { return v }

func rbacInput() Input {
	sa := func(ns, name string) corev1.ServiceAccount {
		return corev1.ServiceAccount{ObjectMeta: meta(ns, name, nil)}
	}
	used := hardenedSpec()
	used.ServiceAccountName = "deployer"
	return Input{
		Now:             now,
		Namespaces:      []corev1.Namespace{{ObjectMeta: meta("", "ci", nil)}, {ObjectMeta: meta("", "app", nil)}},
		ServiceAccounts: []corev1.ServiceAccount{sa("ci", "idle-admin"), sa("ci", "deployer"), sa("ci", "default"), sa("kube-system", "kindnet")},
		Deployments:     []appsv1.Deployment{deployment("ci", "runner", map[string]string{"app": "runner"}, used)},
		ClusterRoles: []rbacv1.ClusterRole{
			{ObjectMeta: meta("", "everything", nil), Rules: []rbacv1.PolicyRule{rule(s("*"), s("*"), s("*"))}},
			{ObjectMeta: meta("", "cluster-admin", map[string]string{"kubernetes.io/bootstrapping": "rbac-defaults"}), Rules: []rbacv1.PolicyRule{rule(s("*"), s("*"), s("*"))}},
			{ObjectMeta: meta("", "secret-reader", nil), Rules: []rbacv1.PolicyRule{rule(s(""), s("secrets"), s("get", "list"))}},
			{ObjectMeta: meta("", "leftover", nil), Rules: []rbacv1.PolicyRule{rule(s(""), s("pods"), s("get"))}},
			{ObjectMeta: meta("", "system:controller:foo", nil)},
			{ObjectMeta: meta("", "view-extra", map[string]string{"rbac.authorization.k8s.io/aggregate-to-view": "true"})},
			{ObjectMeta: meta("", "kindnet", nil), Rules: []rbacv1.PolicyRule{rule(s(""), s("nodes"), s("list"))}},
		},
		Roles: []rbacv1.Role{
			{ObjectMeta: meta("ci", "orphan", nil), Rules: []rbacv1.PolicyRule{rule(s(""), s("pods/exec"), s("create"))}},
		},
		ClusterRoleBindings: []rbacv1.ClusterRoleBinding{
			{ObjectMeta: meta("", "idle-admin", nil), RoleRef: rbacv1.RoleRef{Kind: "ClusterRole", Name: "everything"},
				Subjects: []rbacv1.Subject{{Kind: "ServiceAccount", Name: "idle-admin", Namespace: "ci"}}},
			{ObjectMeta: meta("", "deployer-admin", nil), RoleRef: rbacv1.RoleRef{Kind: "ClusterRole", Name: "everything"},
				Subjects: []rbacv1.Subject{{Kind: "ServiceAccount", Name: "deployer", Namespace: "ci"}}},
			{ObjectMeta: meta("", "cluster-admin", map[string]string{"kubernetes.io/bootstrapping": "rbac-defaults"}), RoleRef: rbacv1.RoleRef{Kind: "ClusterRole", Name: "cluster-admin"},
				Subjects: []rbacv1.Subject{{Kind: "Group", Name: "system:masters"}}},
			{ObjectMeta: meta("", "kindnet", nil), RoleRef: rbacv1.RoleRef{Kind: "ClusterRole", Name: "kindnet"},
				Subjects: []rbacv1.Subject{{Kind: "ServiceAccount", Name: "kindnet", Namespace: "kube-system"}}},
			{ObjectMeta: meta("", "ops", nil), RoleRef: rbacv1.RoleRef{Kind: "ClusterRole", Name: "secret-reader"},
				Subjects: []rbacv1.Subject{{Kind: "Group", Name: "ops-team"}}},
		},
		RoleBindings: []rbacv1.RoleBinding{
			{ObjectMeta: meta("app", "ghost", nil), RoleRef: rbacv1.RoleRef{Kind: "ClusterRole", Name: "secret-reader"},
				Subjects: []rbacv1.Subject{{Kind: "ServiceAccount", Name: "deleted-bot"}}},
			{ObjectMeta: meta("app", "dangling", nil), RoleRef: rbacv1.RoleRef{Kind: "Role", Name: "nope"},
				Subjects: []rbacv1.Subject{{Kind: "User", Name: "alice"}}},
		},
	}
}

func TestRBAC(t *testing.T) {
	res := Analyze(rbacInput())

	unused := findOne(t, res, "rbac.unused-privileged")
	if unused.Severity != Critical || !hasObj(unused, "ClusterRoleBinding", "idle-admin") || !hasObj(unused, "ServiceAccount", "idle-admin") {
		t.Errorf("unused cluster admin: %+v", unused)
	}
	perm := find(res, "rbac.permissive")
	byName := map[string]Finding{}
	for _, f := range perm {
		byName[f.Objects[0].Name] = f
	}
	if f, ok := byName["deployer-admin"]; !ok || f.Severity != Critical || !strings.Contains(f.Title, "cluster-admin-equivalent") {
		t.Errorf("used cluster admin: %+v", f)
	}
	if f, ok := byName["ops"]; !ok || f.Severity != High {
		t.Errorf("group secret reader cluster-wide is high: %+v", f)
	}
	if _, ok := byName["cluster-admin"]; ok {
		t.Error("default system:masters binding excluded")
	}
	if _, ok := byName["kindnet"]; ok {
		t.Error("kube-system controller binding excluded")
	}
	// ghost: secret-reader for a ServiceAccount that doesn't exist is
	// reported as a missing subject, not as a permissive/unused grant.
	if _, ok := byName["ghost"]; ok {
		t.Error("ghost is reported by missing-subject")
	}
	ms := findOne(t, res, "rbac.missing-subject")
	if ms.Severity != Medium || !strings.Contains(ms.Detail, "app/deleted-bot") {
		t.Errorf("missing subject: %+v", ms)
	}
	mr := findOne(t, res, "rbac.missing-role")
	if !hasObj(mr, "RoleBinding", "dangling") || !strings.Contains(mr.Title, "Role nope") {
		t.Errorf("missing role: %+v", mr)
	}
	unbound := find(res, "rbac.unbound-role")
	if len(unbound) != 2 {
		t.Fatalf("unbound: %+v", unbound)
	}
	for _, f := range unbound {
		if f.Severity != Info {
			t.Errorf("unbound roles are info: %+v", f)
		}
		if hasObj(f, "ClusterRole", "system:controller:foo") || hasObj(f, "ClusterRole", "view-extra") || hasObj(f, "ClusterRole", "everything") {
			t.Errorf("system, aggregated and bound roles are excluded: %+v", f)
		}
	}
	if !hasObj(unbound[0], "ClusterRole", "leftover") && !hasObj(unbound[1], "ClusterRole", "leftover") {
		t.Error("leftover ClusterRole is unbound")
	}

	// Ranked table: cluster-wide full wildcards first, unused before used.
	if len(res.Permissive) < 3 || res.Permissive[0].Binding.Name != "idle-admin" || !res.Permissive[0].Unused || res.Permissive[0].Score != 100 {
		t.Fatalf("ranking: %+v", res.Permissive)
	}
	if res.Permissive[1].Binding.Name != "deployer-admin" || res.Permissive[1].Unused {
		t.Errorf("second: %+v", res.Permissive[1])
	}
	for _, g := range res.Permissive {
		if g.System {
			t.Errorf("system grant listed without includeSystem: %+v", g)
		}
		if g.Binding.Name == "deployer-admin" && (g.Subjects[0].Used == nil || !*g.Subjects[0].Used || !*g.Subjects[0].Exists) {
			t.Errorf("deployer subject: %+v", g.Subjects)
		}
	}

	in := rbacInput()
	in.IncludeSystem = true
	res = Analyze(in)
	found := false
	for _, g := range res.Permissive {
		if g.Binding.Name == "cluster-admin" && g.System {
			found = true
		}
	}
	if !found {
		t.Error("includeSystem lists the default cluster-admin binding")
	}

	// Scoped to app: only bindings that touch app.
	in = rbacInput()
	in.Namespace = "app"
	res = Analyze(in)
	for _, g := range res.Permissive {
		if g.Binding.Kind == "ClusterRoleBinding" {
			t.Errorf("CRBs without subjects in app are out of scope: %+v", g)
		}
	}
	if len(find(res, "rbac.unbound-role")) != 0 {
		t.Error("cluster roles aren't reported when scoped")
	}
}

// ---- workload hardening ---------------------------------------------------

func checks(vs []Violation) map[string]Violation {
	out := map[string]Violation{}
	for _, v := range vs {
		out[v.Check] = v
	}
	return out
}

// ---- best practices -------------------------------------------------------

// ---- images (Trivy Operator) ----------------------------------------------

func loadUnstructured(t *testing.T, path string) unstructured.Unstructured {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var u unstructured.Unstructured
	if err := json.Unmarshal(b, &u.Object); err != nil {
		t.Fatal(err)
	}
	return u
}

func vulnReport(ns, name, rsName, container, repo, tag, updated string, vulns ...map[string]any) unstructured.Unstructured {
	vs := make([]any, len(vulns))
	for i, v := range vulns {
		vs[i] = v
	}
	return unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "aquasecurity.github.io/v1alpha1", "kind": "VulnerabilityReport",
		"metadata": map[string]any{"namespace": ns, "name": name, "labels": map[string]any{
			"trivy-operator.resource.kind": "ReplicaSet", "trivy-operator.resource.name": rsName,
			"trivy-operator.resource.namespace": ns, "trivy-operator.container.name": container,
		}},
		"report": map[string]any{
			"artifact": map[string]any{"repository": repo, "tag": tag}, "registry": map[string]any{"server": "index.docker.io"},
			"updateTimestamp": updated, "vulnerabilities": vs,
		},
	}}
}

func vuln(id, sev, pkg, fixed string, score float64) map[string]any {
	return map[string]any{"vulnerabilityID": id, "severity": sev, "resource": pkg, "installedVersion": "1.0", "fixedVersion": fixed, "score": score, "title": id + " title"}
}

func TestTrivyOperatorReports(t *testing.T) {
	// Real report captured from the kind cluster (nginx:latest in security-demo).
	real := loadUnstructured(t, "testdata/vulnerabilityreport-nginx.json")
	spec := hardenedSpec()
	spec.Containers[0].Name, spec.Containers[0].Image = "nginx", "nginx:latest"
	rs := appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Namespace: "security-demo", Name: "web-latest-8478dd9d8d", OwnerReferences: ownedBy("apps/v1", "Deployment", "web-latest")}}

	apiSpec := hardenedSpec()
	apiSpec.Containers[0].Image = "example/api:2"
	rsAPI := appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Namespace: "app", Name: "api-1", OwnerReferences: ownedBy("apps/v1", "Deployment", "api")}}
	rsAPI2 := appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Namespace: "app", Name: "api-2", OwnerReferences: ownedBy("apps/v1", "Deployment", "api")}}
	old := vulnReport("app", "replicaset-api-1-app", "api-1", "app", "example/api", "2", "2026-11-01T00:00:00Z", vuln("CVE-OLD", "CRITICAL", "x", "", 9))
	newer := vulnReport("app", "replicaset-api-2-app", "api-2", "app", "example/api", "2", "2026-11-03T00:00:00Z",
		vuln("CVE-1", "CRITICAL", "openssl", "3.0.14", 9.8),
		vuln("CVE-1", "CRITICAL", "openssl", "3.0.14", 9.8), // duplicate (same pkg) counted once
		vuln("CVE-2", "CRITICAL", "zlib", "", 9.1),
		vuln("CVE-3", "HIGH", "libc", "2.36-9", 7.5),
		vuln("CVE-4", "MEDIUM", "curl", "", 5),
	)
	secrets := unstructured.Unstructured{Object: map[string]any{
		"metadata": map[string]any{"namespace": "app", "name": "replicaset-api-2-app", "labels": map[string]any{
			"trivy-operator.resource.kind": "ReplicaSet", "trivy-operator.resource.name": "api-2", "trivy-operator.container.name": "app"}},
		"report": map[string]any{"secrets": []any{map[string]any{"title": "AWS Access Key", "target": "/app/.env", "severity": "CRITICAL"}}},
	}}
	rbacReport := unstructured.Unstructured{Object: map[string]any{
		"metadata": map[string]any{"name": "clusterrole-abc", "labels": map[string]any{"trivy-operator.resource.kind": "ClusterRole", "trivy-operator.resource.name-hash": "abc"},
			"annotations": map[string]any{"trivy-operator.resource.name": "custom:viewer"}},
		"report": map[string]any{"checks": []any{
			map[string]any{"checkID": "KSV-0041", "title": "Manage secrets", "severity": "CRITICAL", "success": false},
			map[string]any{"checkID": "KSV-0001", "title": "ok", "severity": "HIGH", "success": true},
		}},
	}}
	res := Analyze(Input{
		Now:           now,
		Deployments:   []appsv1.Deployment{deployment("security-demo", "web-latest", web, spec), deployment("app", "api", map[string]string{"app": "api"}, apiSpec)},
		ReplicaSets:   []appsv1.ReplicaSet{rs, rsAPI, rsAPI2},
		TrivyOperator: true, VulnerabilityReports: []unstructured.Unstructured{real, old, newer},
		ExposedSecretReports:         []unstructured.Unstructured{secrets},
		ClusterRbacAssessmentReports: []unstructured.Unstructured{rbacReport},
	})
	imgs := map[string]ImageSummary{}
	for _, i := range res.Images {
		imgs[i.Image] = i
	}
	nginx := imgs["nginx:latest"]
	if !nginx.Scanned || nginx.Source != "trivy-operator" || nginx.Counts.Critical != 1 || nginx.Counts.High != 7 || nginx.Workloads[0].Name != "web-latest" {
		t.Errorf("real nginx report mapped to its Deployment by container image: %+v", nginx)
	}
	api := imgs["example/api:2"]
	want := VulnCounts{Critical: 2, High: 1, Medium: 1, FixableCritical: 1, FixableHigh: 1}
	if api.Counts != want || len(api.Workloads) != 1 {
		t.Errorf("newest report wins, deduped: %+v", api)
	}
	if api.TopCVEs[0].ID != "CVE-1" || api.TopCVEs[1].ID != "CVE-2" {
		t.Errorf("fixable critical first: %+v", api.TopCVEs)
	}
	if res.Images[0].Image != "example/api:2" {
		t.Errorf("images sorted by fixable criticals: %+v", res.Images[0])
	}
	if res.TopCVEs[0].ID != "CVE-1" || res.TopCVEs[0].Fixed != "3.0.14" {
		t.Errorf("top CVEs: %+v", res.TopCVEs)
	}
	vf := find(res, "images.vulnerable")
	sevs := map[string]string{}
	for _, f := range vf {
		sevs[strings.Split(f.ID, "/")[1]] = f.Severity
	}
	if len(vf) != 2 || vf[0].Severity != High || !hasObj(vf[0], "Deployment", "api") {
		t.Errorf("image findings: %+v", vf)
	}
	es := findOne(t, res, "images.exposed-secret")
	if es.Severity != High || !hasObj(es, "Deployment", "api") || !strings.Contains(es.Title, "example/api:2") {
		t.Errorf("exposed secret: %+v", es)
	}
	ra := findOne(t, res, "rbac.trivy-assessment")
	if !hasObj(ra, "ClusterRole", "custom:viewer") || !strings.Contains(ra.Detail, "KSV-0041") || strings.Contains(ra.Detail, "KSV-0001") {
		t.Errorf("rbac assessment uses the annotation name and failing checks only: %+v", ra)
	}
	if res.Sources.Reports["vulnerabilityreports"] != 3 || !res.Sources.TrivyOperator {
		t.Errorf("sources: %+v", res.Sources)
	}
}

// ---- score & ordering -----------------------------------------------------

// TestScenarioFixture writes the analysis of a scenario with one of most
// findings for the Flutter widget tests:
//
//	SECURITY_FIXTURE_OUT=../frontend/test/security/fixtures/security-scenario.json go test ./internal/security -run Scenario
func TestScenarioFixture(t *testing.T) {
	out := os.Getenv("SECURITY_FIXTURE_OUT")
	if out == "" {
		t.Skip("SECURITY_FIXTURE_OUT not set")
	}
	in := rbacInput()
	in.Services = []corev1.Service{{ObjectMeta: meta("ci", "public", nil), Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeLoadBalancer, Selector: map[string]string{"app": "runner"}}}}
	res := Analyze(in)
	b, _ := json.MarshalIndent(res, "", "  ")
	if err := os.WriteFile(out, b, 0o644); err != nil {
		t.Fatal(err)
	}
}
