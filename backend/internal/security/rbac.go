package security

import (
	"fmt"
	"math"
	"slices"
	"sort"
	"strings"

	"github.com/matty234/k8sman/backend/internal/kube"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Risk is one dangerous capability granted by a rule, with its weight.
type Risk struct {
	Points int    `json:"points"`
	Reason string `json:"reason"`
}

// Subject is a binding subject, annotated with what we know about it.
type Subject struct {
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace,omitempty"`
	// Exists / Used are set for ServiceAccounts when known.
	Exists *bool `json:"exists,omitempty"`
	Used   *bool `json:"used,omitempty"`
}

// Grant is one binding of a role to subjects, ranked by risk.
type Grant struct {
	Binding     ObjectRef `json:"binding"`
	Role        ObjectRef `json:"role"`
	RoleMissing bool      `json:"roleMissing,omitempty"`
	// Scope is "cluster" for ClusterRoleBindings, else the namespace.
	Scope    string    `json:"scope"`
	Subjects []Subject `json:"subjects"`
	Score    int       `json:"score"`
	Reasons  []string  `json:"reasons"`
	// Unused: every subject is a ServiceAccount that no pod or workload uses.
	Unused bool `json:"unused"`
	System bool `json:"system"`
}

const maxPermissive = 60

var workloadResources = map[string]bool{
	"pods": true, "deployments": true, "statefulsets": true, "daemonsets": true, "replicasets": true,
	"jobs": true, "cronjobs": true, "replicationcontrollers": true,
}

var rbacResources = map[string]bool{"roles": true, "rolebindings": true, "clusterroles": true, "clusterrolebindings": true}

func has(list []string, v string) bool {
	for _, s := range list {
		if s == v || s == "*" {
			return true
		}
	}
	return false
}

func hasAny(list []string, vs ...string) bool {
	for _, v := range vs {
		if has(list, v) {
			return true
		}
	}
	return false
}

// hasResource matches "pods/exec" against "pods/exec", "pods/*" or "*".
func hasResource(list []string, r string) bool {
	if has(list, r) {
		return true
	}
	if i := strings.IndexByte(r, '/'); i > 0 {
		return has(list, r[:i]+"/*")
	}
	return false
}

func groupCovers(groups []string, g string) bool { return has(groups, g) }

// RuleRisks lists the dangerous capabilities one PolicyRule grants.
func RuleRisks(r rbacv1.PolicyRule) []Risk {
	if len(r.Resources) == 0 {
		return nil // nonResourceURLs only
	}
	v, res, g := r.Verbs, r.Resources, r.APIGroups
	allVerbs, allRes, allGroups := slices.Contains(v, "*"), slices.Contains(res, "*"), slices.Contains(g, "*")
	var out []Risk
	add := func(p int, reason string) { out = append(out, Risk{p, reason}) }

	switch {
	case allVerbs && allRes && allGroups:
		// Implies every other risk below; listing them all is noise.
		return []Risk{{100, "Full wildcard: every verb on every resource (cluster-admin equivalent)"}}
	case allVerbs && allRes:
		add(70, fmt.Sprintf("Every verb on every resource in %s", groupsText(g)))
	case allVerbs:
		add(20, fmt.Sprintf("Every verb (*) on %s", strings.Join(res, ", ")))
	}
	core := groupCovers(g, "")
	rbacGroup := groupCovers(g, "rbac.authorization.k8s.io")
	if rbacGroup && hasAny(v, "escalate", "bind") && (allRes || hasAny(res, "roles", "clusterroles")) {
		add(60, "Can escalate or bind any role (escalate/bind)")
	}
	if hasAny(v, "impersonate") && (allRes || hasAny(res, "users", "groups", "serviceaccounts", "userextras/*")) {
		add(60, "Can impersonate users, groups or ServiceAccounts")
	}
	if core && hasResource(res, "nodes/proxy") && hasAny(v, "get", "create") {
		add(60, "nodes/proxy: direct kubelet API access (exec into any pod on the node)")
	}
	if rbacGroup && hasAny(v, "create", "update", "patch") && (allRes || anyIn(res, rbacResources)) {
		add(50, "Can create or modify RBAC roles and bindings")
	}
	if core && hasResource(res, "secrets") && hasAny(v, "get", "list", "watch") {
		add(45, "Can read Secrets (including ServiceAccount tokens)")
	}
	if core && (hasResource(res, "pods/exec") || hasResource(res, "pods/attach")) && hasAny(v, "create", "get") {
		add(45, "Can exec or attach into pods (pods/exec, pods/attach)")
	}
	if core && hasResource(res, "serviceaccounts/token") && has(v, "create") {
		add(45, "Can mint ServiceAccount tokens (serviceaccounts/token create)")
	}
	if groupCovers(g, "certificates.k8s.io") && hasResource(res, "certificatesigningrequests/approval") && hasAny(v, "update", "patch") {
		add(45, "Can approve certificate signing requests")
	}
	if groupCovers(g, "admissionregistration.k8s.io") && hasAny(v, "create", "update", "patch") &&
		(allRes || hasAny(res, "mutatingwebhookconfigurations", "validatingwebhookconfigurations")) {
		add(40, "Can register admission webhooks (intercept every API request)")
	}
	if has(v, "create") && (allRes || anyIn(res, workloadResources)) && (core || groupCovers(g, "apps") || groupCovers(g, "batch")) {
		add(35, "Can create pods or workloads (run as any ServiceAccount in the namespace and mount its Secrets)")
	}
	return out
}

func anyIn(list []string, set map[string]bool) bool {
	for _, s := range list {
		if set[s] {
			return true
		}
	}
	return false
}

func groupsText(g []string) string {
	out := make([]string, len(g))
	for i, s := range g {
		if s == "" {
			s = "core"
		}
		out[i] = s
	}
	return strings.Join(out, ", ")
}

// RulesScore combines risks: the worst risk plus 15% of the others, capped
// at 100. Reasons are distinct, worst first.
func RulesScore(rules []rbacv1.PolicyRule) (int, []string) {
	best := map[string]int{}
	for _, r := range rules {
		for _, k := range RuleRisks(r) {
			if k.Points > best[k.Reason] {
				best[k.Reason] = k.Points
			}
		}
	}
	reasons := make([]string, 0, len(best))
	for r := range best {
		reasons = append(reasons, r)
	}
	sort.Slice(reasons, func(i, j int) bool {
		if best[reasons[i]] != best[reasons[j]] {
			return best[reasons[i]] > best[reasons[j]]
		}
		return reasons[i] < reasons[j]
	})
	if len(reasons) == 0 {
		return 0, []string{}
	}
	score := float64(best[reasons[0]])
	for _, r := range reasons[1:] {
		score += 0.15 * float64(best[r])
	}
	return int(math.Min(100, math.Round(score))), reasons
}

type roleInfo struct {
	ref        ObjectRef
	score      int
	reasons    []string
	system     bool
	aggregated bool
	bound      bool
}

func isSystemMeta(m metav1.ObjectMeta) bool {
	return strings.HasPrefix(m.Name, "system:") || m.Labels["kubernetes.io/bootstrapping"] == "rbac-defaults"
}

func aggregatesInto(m metav1.ObjectMeta) bool {
	for k, v := range m.Labels {
		if strings.HasPrefix(k, "rbac.authorization.k8s.io/aggregate-to-") && v == "true" {
			return true
		}
	}
	return false
}

func (a *analyzer) indexServiceAccounts() {
	a.saUsed = map[string]bool{}
	use := func(ns string, spec *corev1.PodSpec) {
		name := spec.ServiceAccountName
		if name == "" {
			name = spec.DeprecatedServiceAccount
		}
		if name == "" {
			name = "default"
		}
		a.saUsed[kube.Key(ns, name)] = true
	}
	for i := range a.in.Pods {
		p := &a.in.Pods[i]
		if p.Status.Phase != corev1.PodSucceeded && p.Status.Phase != corev1.PodFailed {
			use(p.Namespace, &p.Spec)
		}
	}
	for i := range a.in.Deployments {
		use(a.in.Deployments[i].Namespace, &a.in.Deployments[i].Spec.Template.Spec)
	}
	for i := range a.in.StatefulSets {
		use(a.in.StatefulSets[i].Namespace, &a.in.StatefulSets[i].Spec.Template.Spec)
	}
	for i := range a.in.DaemonSets {
		use(a.in.DaemonSets[i].Namespace, &a.in.DaemonSets[i].Spec.Template.Spec)
	}
	for i := range a.in.CronJobs {
		use(a.in.CronJobs[i].Namespace, &a.in.CronJobs[i].Spec.JobTemplate.Spec.Template.Spec)
	}
	a.saExists = map[string]bool{}
	a.saListed = map[string]bool{}
	if a.in.ServiceAccounts != nil {
		for _, sa := range a.in.ServiceAccounts {
			a.saExists[kube.Key(sa.Namespace, sa.Name)] = true
		}
	}
}

// podsListed: whether pods (and SAs) in ns were listed, so usage is known.
func (a *analyzer) podsListed(ns string) bool { return a.in.Namespace == "" || a.scope().Contains(ns) }

func (a *analyzer) saKnown(ns string) bool { return a.in.ServiceAccounts != nil && a.podsListed(ns) }

func (a *analyzer) indexRoles() {
	a.roles = map[string]*roleInfo{}
	for i := range a.in.ClusterRoles {
		cr := &a.in.ClusterRoles[i]
		s, r := RulesScore(cr.Rules)
		a.roles["ClusterRole//"+cr.Name] = &roleInfo{
			ref:   ObjectRef{Group: "rbac.authorization.k8s.io", Kind: "ClusterRole", Name: cr.Name},
			score: s, reasons: r, system: isSystemMeta(cr.ObjectMeta),
			aggregated: cr.AggregationRule != nil || aggregatesInto(cr.ObjectMeta),
		}
	}
	for i := range a.in.Roles {
		ro := &a.in.Roles[i]
		s, r := RulesScore(ro.Rules)
		a.roles["Role/"+ro.Namespace+"/"+ro.Name] = &roleInfo{
			ref:   ObjectRef{Group: "rbac.authorization.k8s.io", Kind: "Role", Name: ro.Name, Namespace: ro.Namespace},
			score: s, reasons: r, system: isSystemMeta(ro.ObjectMeta),
		}
	}
}

func (a *analyzer) roleFor(ref rbacv1.RoleRef, bindingNS string) (*roleInfo, bool) {
	k := "ClusterRole//" + ref.Name
	listed := a.in.ClusterRoles != nil
	if ref.Kind == "Role" {
		k = "Role/" + bindingNS + "/" + ref.Name
		listed = a.in.Roles != nil
	}
	return a.roles[k], listed
}

type bindingView struct {
	meta     metav1.ObjectMeta
	ref      ObjectRef
	roleRef  rbacv1.RoleRef
	subjects []rbacv1.Subject
	cluster  bool
}

func (a *analyzer) bindings() []bindingView {
	var out []bindingView
	for _, b := range a.in.ClusterRoleBindings {
		out = append(out, bindingView{meta: b.ObjectMeta, ref: ObjectRef{Group: "rbac.authorization.k8s.io", Kind: "ClusterRoleBinding", Name: b.Name}, roleRef: b.RoleRef, subjects: b.Subjects, cluster: true})
	}
	for _, b := range a.in.RoleBindings {
		out = append(out, bindingView{meta: b.ObjectMeta, ref: ObjectRef{Group: "rbac.authorization.k8s.io", Kind: "RoleBinding", Name: b.Name, Namespace: b.Namespace}, roleRef: b.RoleRef, subjects: b.Subjects})
	}
	return out
}

func subjectNS(s rbacv1.Subject, bindingNS string) string {
	if s.Kind == rbacv1.ServiceAccountKind && s.Namespace == "" {
		return bindingNS
	}
	return s.Namespace
}

// isSystemBinding: Kubernetes' own defaults and kube-system controllers.
func isSystemBinding(b bindingView, role *roleInfo) bool {
	if isSystemMeta(b.meta) || IsSystemNamespace(b.meta.Namespace) {
		return true
	}
	if len(b.subjects) == 0 {
		return role != nil && role.system
	}
	for _, s := range b.subjects {
		switch s.Kind {
		case rbacv1.ServiceAccountKind:
			if !IsSystemNamespace(subjectNS(s, b.meta.Namespace)) {
				return false
			}
		default:
			if !strings.HasPrefix(s.Name, "system:") {
				return false
			}
		}
	}
	return true
}

// bindingInScope: with a namespace set, RoleBindings in it and
// ClusterRoleBindings with a ServiceAccount subject in it.
func (a *analyzer) bindingInScope(b bindingView) bool {
	if a.in.Namespace == "" {
		return true
	}
	scope := a.scope()
	if !b.cluster {
		return slices.Contains(scope, b.meta.Namespace)
	}
	for _, s := range b.subjects {
		if s.Kind == rbacv1.ServiceAccountKind && s.Namespace != "" && slices.Contains(scope, s.Namespace) {
			return true
		}
	}
	return false
}

func boolp(b bool) *bool { return &b }

func (a *analyzer) rbac() {
	a.indexServiceAccounts()
	a.indexRoles()
	var grants []Grant
	for _, b := range a.bindings() {
		role, rolesListed := a.roleFor(b.roleRef, b.meta.Namespace)
		if role != nil {
			role.bound = true
		}
		if !a.bindingInScope(b) {
			continue
		}
		system := isSystemBinding(b, role)
		if system && !a.in.IncludeSystem {
			continue
		}
		scope := "cluster"
		if !b.cluster {
			scope = b.meta.Namespace
		}
		g := Grant{Binding: b.ref, Scope: scope, System: system, Subjects: []Subject{}, Reasons: []string{}}
		if role != nil {
			g.Role, g.Score, g.Reasons = role.ref, role.score, role.reasons
		} else {
			g.Role = ObjectRef{Group: "rbac.authorization.k8s.io", Kind: b.roleRef.Kind, Name: b.roleRef.Name}
			if b.roleRef.Kind == "Role" {
				g.Role.Namespace = b.meta.Namespace
			}
			g.RoleMissing = rolesListed
		}
		var missing []ObjectRef
		allSAUnused := len(b.subjects) > 0
		for _, s := range b.subjects {
			sub := Subject{Kind: s.Kind, Name: s.Name, Namespace: subjectNS(s, b.meta.Namespace)}
			if s.Kind == rbacv1.ServiceAccountKind {
				k := kube.Key(sub.Namespace, s.Name)
				if a.saKnown(sub.Namespace) {
					sub.Exists = boolp(a.saExists[k])
					if !a.saExists[k] {
						missing = append(missing, ObjectRef{Kind: "ServiceAccount", Name: s.Name, Namespace: sub.Namespace})
					}
				}
				if a.podsListed(sub.Namespace) {
					sub.Used = boolp(a.saUsed[k])
					if a.saUsed[k] {
						allSAUnused = false
					}
				} else {
					allSAUnused = false
				}
			} else {
				allSAUnused = false
			}
			g.Subjects = append(g.Subjects, sub)
		}
		g.Unused = allSAUnused
		if g.Score > 0 {
			grants = append(grants, g)
		}
		a.grantFindings(g, b, missing)
	}
	sort.SliceStable(grants, func(i, j int) bool {
		if grants[i].Score != grants[j].Score {
			return grants[i].Score > grants[j].Score
		}
		if (grants[i].Scope == "cluster") != (grants[j].Scope == "cluster") {
			return grants[i].Scope == "cluster"
		}
		if grants[i].Unused != grants[j].Unused {
			return grants[i].Unused
		}
		return refKey(grants[i].Binding) < refKey(grants[j].Binding)
	})
	if len(grants) > maxPermissive {
		grants = grants[:maxPermissive]
	}
	a.res.Permissive = grants
	a.unboundRoles()
}

func subjectsText(subs []Subject) string {
	parts := []string{}
	for _, s := range subs {
		switch s.Kind {
		case rbacv1.ServiceAccountKind:
			parts = append(parts, "ServiceAccount "+s.Namespace+"/"+s.Name)
		default:
			parts = append(parts, s.Kind+" "+s.Name)
		}
	}
	if len(parts) == 0 {
		return "no subjects"
	}
	return joinLimit(parts, 4)
}

// GrantSeverity maps a grant's score and scope to a severity ("" = none).
// Unused grants are raised one level: privilege nobody uses is pure risk.
func GrantSeverity(score int, cluster, unused bool) string {
	var s string
	switch {
	case score >= 90:
		s = map[bool]string{true: Critical, false: High}[cluster]
	case score >= 45:
		s = map[bool]string{true: High, false: Medium}[cluster]
	case score >= 30:
		s = map[bool]string{true: Medium, false: Low}[cluster]
	default:
		return ""
	}
	if unused && s != Critical {
		s = Severities[sevRank[s]-1]
	}
	return s
}

func (a *analyzer) grantFindings(g Grant, b bindingView, missing []ObjectRef) {
	ns := b.meta.Namespace
	objs := []ObjectRef{g.Binding}
	if !g.RoleMissing {
		objs = append(objs, g.Role)
	}
	for _, s := range g.Subjects {
		if s.Kind == rbacv1.ServiceAccountKind && (s.Exists == nil || *s.Exists) {
			objs = append(objs, ObjectRef{Kind: "ServiceAccount", Name: s.Name, Namespace: s.Namespace})
		}
	}
	where := "cluster-wide"
	if !b.cluster {
		where = "in namespace " + ns
	}
	// A binding whose ServiceAccounts are all missing is reported by the
	// missing-subject check instead.
	allMissing := len(missing) > 0 && len(missing) == len(b.subjects)
	if sev := GrantSeverity(g.Score, b.cluster, g.Unused); sev != "" && !allMissing {
		check, title := "rbac.permissive", fmt.Sprintf("%s %s grants %s %s", b.ref.Kind, b.ref.Name, firstReason(g.Reasons), where)
		remediation := "Replace wildcards with the specific verbs and resources needed, prefer namespaced Roles over ClusterRoleBindings, and keep secrets/exec/escalation rights for break-glass accounts."
		detail := fmt.Sprintf("%s → %s %s (risk %d/100). Grants: %s. Subjects: %s.", b.ref.Name, g.Role.Kind, g.Role.Name, g.Score, strings.Join(g.Reasons, "; "), subjectsText(g.Subjects))
		if g.Unused {
			check = "rbac.unused-privileged"
			title = fmt.Sprintf("Unused ServiceAccount holds %s %s (%s)", firstReason(g.Reasons), where, b.ref.Name)
			detail += " No pod or workload uses these ServiceAccounts, so the privilege serves nothing but anyone who can get a token for them inherits it."
			remediation = "Delete the binding (and the ServiceAccount) if it is no longer needed; otherwise scope it down."
		}
		a.add(Finding{ID: check + "/" + refKey(b.ref), Check: check, Severity: sev, Category: CatRBAC, Namespace: ns,
			Title: title, Detail: detail, Remediation: remediation, Objects: objs})
	}
	if len(missing) > 0 {
		sev := Low
		if g.Score >= 45 {
			sev = Medium
		}
		names := []string{}
		for _, m := range missing {
			names = append(names, m.Namespace+"/"+m.Name)
		}
		a.add(Finding{ID: "rbac.missing-subject/" + refKey(b.ref), Check: "rbac.missing-subject", Severity: sev, Category: CatRBAC, Namespace: ns,
			Title:       fmt.Sprintf("%s %s binds ServiceAccounts that don't exist", b.ref.Kind, b.ref.Name),
			Detail:      fmt.Sprintf("Missing: %s. Anyone who creates a ServiceAccount with that name silently inherits %s %s.", strings.Join(names, ", "), g.Role.Kind, g.Role.Name),
			Remediation: "Delete the stale binding, or remove the missing subjects from it.",
			Objects:     []ObjectRef{b.ref}})
	}
	if g.RoleMissing {
		a.add(Finding{ID: "rbac.missing-role/" + refKey(b.ref), Check: "rbac.missing-role", Severity: Low, Category: CatRBAC, Namespace: ns,
			Title:       fmt.Sprintf("%s %s refers to a missing %s %s", b.ref.Kind, b.ref.Name, g.Role.Kind, g.Role.Name),
			Detail:      fmt.Sprintf("The binding grants nothing today, but creating a %s named %s would immediately grant it to %s.", g.Role.Kind, g.Role.Name, subjectsText(g.Subjects)),
			Remediation: "Delete the binding if it is stale.",
			Objects:     []ObjectRef{b.ref}})
	}
}

var shortReasons = []struct{ prefix, short string }{
	{"Full wildcard", "cluster-admin-equivalent access"},
	{"Every verb on every resource", "wildcard access"},
	{"Every verb (*)", "wildcard verbs"},
	{"Can escalate", "escalate/bind rights"},
	{"Can impersonate", "impersonation rights"},
	{"nodes/proxy", "nodes/proxy access"},
	{"Can create or modify RBAC", "RBAC write access"},
	{"Can read Secrets", "read access to Secrets"},
	{"Can exec", "pods/exec access"},
	{"Can mint", "token-minting rights"},
	{"Can approve", "CSR approval rights"},
	{"Can register admission", "webhook registration rights"},
	{"Can create pods", "workload-creation rights"},
}

// ShortReason is a title-sized label for a risk reason.
func ShortReason(r string) string {
	for _, s := range shortReasons {
		if strings.HasPrefix(r, s.prefix) {
			return s.short
		}
	}
	return "permissions"
}

func firstReason(rs []string) string {
	if len(rs) == 0 {
		return "permissions"
	}
	return ShortReason(rs[0])
}

func (a *analyzer) unboundRoles() {
	var cluster []ObjectRef
	byNS := map[string][]ObjectRef{}
	keys := make([]string, 0, len(a.roles))
	for k := range a.roles {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		r := a.roles[k]
		if r.bound || r.system || r.aggregated {
			continue
		}
		if r.ref.Kind == "ClusterRole" {
			if a.in.Namespace == "" {
				cluster = append(cluster, r.ref)
			}
		} else if a.inScope(r.ref.Namespace) {
			byNS[r.ref.Namespace] = append(byNS[r.ref.Namespace], r.ref)
		}
	}
	// Only meaningful when bindings were listed.
	if a.in.RoleBindings == nil || a.in.ClusterRoleBindings == nil {
		return
	}
	if len(cluster) > 0 {
		a.add(Finding{ID: "rbac.unbound-role/cluster", Check: "rbac.unbound-role", Severity: Info, Category: CatRBAC,
			Title:       fmt.Sprintf("%s %s not bound by anything", kube.Plural(len(cluster), "ClusterRole", "ClusterRoles"), isAre(len(cluster))),
			Detail:      fmt.Sprintf("%s. Unbound roles grant nothing but clutter RBAC reviews; they may be left over from uninstalled software.", joinLimit(refNames(cluster), 6)),
			Remediation: "Delete roles that are no longer needed.",
			Objects:     cluster})
	}
	nss := make([]string, 0, len(byNS))
	for ns := range byNS {
		nss = append(nss, ns)
	}
	sort.Strings(nss)
	for _, ns := range nss {
		rs := byNS[ns]
		a.add(Finding{ID: "rbac.unbound-role/" + ns, Check: "rbac.unbound-role", Severity: Info, Category: CatRBAC, Namespace: ns,
			Title:       fmt.Sprintf("%s in %s %s not bound by anything", kube.Plural(len(rs), "Role", "Roles"), ns, isAre(len(rs))),
			Detail:      fmt.Sprintf("%s. Unbound roles grant nothing but clutter RBAC reviews.", joinLimit(refNames(rs), 6)),
			Remediation: "Delete roles that are no longer needed.",
			Objects:     rs})
	}
}
