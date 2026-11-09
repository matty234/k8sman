package server

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	authnv1 "k8s.io/api/authentication/v1"
	authnv1alpha1 "k8s.io/api/authentication/v1alpha1"
	authnv1beta1 "k8s.io/api/authentication/v1beta1"
	authzv1 "k8s.io/api/authorization/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/yaml"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/rbac"
)

// RBAC workspace ("Access"): effective permissions, who-can, can-I, and a
// guarded apply for Roles/ClusterRoles and their bindings. See API.md.
func (s *Server) rbacRoutes() {
	s.mux.HandleFunc("GET /api/rbac/subjects", s.handleRBACSubjects)
	s.mux.HandleFunc("GET /api/rbac/matrix", s.handleRBACMatrix)
	s.mux.HandleFunc("GET /api/rbac/role-matrix", s.handleRBACRoleMatrix)
	s.mux.HandleFunc("GET /api/rbac/who-can", s.handleRBACWhoCan)
	s.mux.HandleFunc("GET /api/rbac/self", s.handleRBACSelf)
	s.mux.HandleFunc("POST /api/rbac/check", s.handleRBACCheck)
	s.mux.HandleFunc("GET /api/rbac/resources", s.handleRBACResources)
	s.mux.HandleFunc("POST /api/rbac/apply", s.handleRBACApply)
}

// loadPolicy lists the four RBAC types (through the shared watch cache) and
// indexes them. Any list failing is an error: a partial policy would
// under-report permissions.
func loadPolicy(ctx context.Context, c *cluster.Clients) (*rbac.Policy, error) {
	kc := kcache.For(c)
	var (
		roles  []rbacv1.Role
		croles []rbacv1.ClusterRole
		rbs    []rbacv1.RoleBinding
		crbs   []rbacv1.ClusterRoleBinding
		mu     sync.Mutex
		first  error
		wg     sync.WaitGroup
	)
	run := func(f func() error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := f(); err != nil {
				mu.Lock()
				if first == nil {
					first = err
				}
				mu.Unlock()
			}
		}()
	}
	run(func() (err error) { roles, err = listTyped[rbacv1.Role](ctx, kc, gvrRoles, "", ""); return })
	run(func() (err error) {
		croles, err = listTyped[rbacv1.ClusterRole](ctx, kc, gvrClusterRoles, "", "")
		return
	})
	run(func() (err error) { rbs, err = listTyped[rbacv1.RoleBinding](ctx, kc, gvrRoleBindings, "", ""); return })
	run(func() (err error) {
		crbs, err = listTyped[rbacv1.ClusterRoleBinding](ctx, kc, gvrClusterRoleBindings, "", "")
		return
	})
	wg.Wait()
	if first != nil {
		return nil, first
	}
	return rbac.NewPolicy(roles, croles, rbs, crbs), nil
}

// rbacResources lists every served resource and subresource (preferred
// versions) for matrix rows and the role editor's pickers.
func rbacResources(c *cluster.Clients) ([]rbac.ResourceInfo, error) {
	// ServerPreferredResources drops subresources (pods/exec, …), so
	// take every resource list and keep each group's preferred version.
	groups, lists, err := c.Discovery.ServerGroupsAndResources()
	if err != nil && !discovery.IsGroupDiscoveryFailedError(err) {
		return nil, err
	}
	preferred := map[string]bool{}
	for _, g := range groups {
		preferred[g.PreferredVersion.GroupVersion] = true
	}
	var out []rbac.ResourceInfo
	for _, l := range lists {
		gv, perr := schema.ParseGroupVersion(l.GroupVersion)
		// The metrics adapters serve one pseudo-resource per metric
		// (thousands); rules naming them still get rows of their own.
		if perr != nil || !preferred[l.GroupVersion] || gv.Group == "custom.metrics.k8s.io" || gv.Group == "external.metrics.k8s.io" {
			continue
		}
		for _, r := range l.APIResources {
			out = append(out, rbac.ResourceInfo{Group: gv.Group, Version: gv.Version, Resource: r.Name, Kind: r.Kind, Namespaced: r.Namespaced, Verbs: r.Verbs})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Group != out[j].Group {
			return out[i].Group < out[j].Group
		}
		return out[i].Resource < out[j].Resource
	})
	return out, nil
}

func namespacedResource(res []rbac.ResourceInfo, group, resource string) bool {
	for _, r := range res {
		if r.Group == group && r.Resource == resource {
			return r.Namespaced
		}
	}
	for _, v := range rbac.VirtualResources {
		if v.Group == group && v.Resource == resource {
			return false
		}
	}
	return true
}

func rbacCtx(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), 30*time.Second)
}

func (s *Server) handleRBACResources(w http.ResponseWriter, r *http.Request) {
	res, err := rbacResources(s.mgr.Clients())
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"resources": res, "virtual": rbac.VirtualResources})
}

func (s *Server) handleRBACSubjects(w http.ResponseWriter, r *http.Request) {
	c := s.mgr.Clients()
	ctx, cancel := rbacCtx(r)
	defer cancel()
	p, err := loadPolicy(ctx, c)
	if err != nil {
		writeErr(w, err)
		return
	}
	var sas []rbac.Subject
	out := map[string]any{}
	if list, err := listTyped[corev1.ServiceAccount](ctx, kcache.For(c), gvrServiceAccounts, "", ""); err == nil {
		sas = make([]rbac.Subject, len(list))
		for i, sa := range list {
			sas[i] = rbac.Subject{Kind: rbacv1.ServiceAccountKind, Name: sa.Name, Namespace: sa.Namespace}
		}
	} else {
		out["serviceAccountsError"] = err.Error()
	}
	list := p.Subjects(sas)
	out["serviceAccounts"], out["users"], out["groups"] = list.ServiceAccounts, list.Users, list.Groups
	httpx.WriteJSON(w, http.StatusOK, out)
}

// subjectFromQuery reads kind/name/subjectNamespace (+ groups for users).
func subjectFromQuery(q map[string][]string) (rbac.Subject, []string, error) {
	get := func(k string) string {
		if v := q[k]; len(v) > 0 {
			return v[0]
		}
		return ""
	}
	sub := rbac.Subject{Kind: get("kind"), Name: get("name"), Namespace: get("subjectNamespace")}
	switch sub.Kind {
	case rbacv1.UserKind, rbacv1.GroupKind:
		sub.Namespace = ""
	case rbacv1.ServiceAccountKind:
		if sub.Namespace == "" {
			return sub, nil, httpx.BadRequest("subjectNamespace is required for a ServiceAccount")
		}
	default:
		return sub, nil, httpx.BadRequest("kind must be User, Group or ServiceAccount")
	}
	if sub.Name == "" {
		return sub, nil, httpx.BadRequest("name is required")
	}
	var groups []string
	for _, g := range strings.Split(get("groups"), ",") {
		if g = strings.TrimSpace(g); g != "" {
			groups = append(groups, g)
		}
	}
	return sub, groups, nil
}

func (s *Server) handleRBACMatrix(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	sub, groups, err := subjectFromQuery(q)
	if err != nil {
		writeErr(w, err)
		return
	}
	c := s.mgr.Clients()
	ctx, cancel := rbacCtx(r)
	defer cancel()
	p, err := loadPolicy(ctx, c)
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := rbacResources(c)
	if err != nil {
		writeErr(w, err)
		return
	}
	m := p.MatrixFor(rbac.IdentityFor(sub, groups), q.Get("namespace"), res)
	m.Subject = &sub
	httpx.WriteJSON(w, http.StatusOK, m)
}

func (s *Server) handleRBACRoleMatrix(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	kind, name, ns := q.Get("kind"), q.Get("name"), q.Get("namespace")
	if (kind != "Role" && kind != "ClusterRole") || name == "" || (kind == "Role" && ns == "") {
		writeErr(w, httpx.BadRequest("kind (Role|ClusterRole), name and, for a Role, namespace are required"))
		return
	}
	c := s.mgr.Clients()
	ctx, cancel := rbacCtx(r)
	defer cancel()
	p, err := loadPolicy(ctx, c)
	if err != nil {
		writeErr(w, err)
		return
	}
	res, err := rbacResources(c)
	if err != nil {
		writeErr(w, err)
		return
	}
	if kind == "ClusterRole" {
		ns = ""
	}
	m, ok := p.RoleMatrix(kind, name, ns, res)
	if !ok {
		writeErr(w, apierrors.NewNotFound(schema.GroupResource{Group: rbac.Group, Resource: strings.ToLower(kind) + "s"}, name))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, m)
}

func requestFromQuery(q map[string][]string) rbac.Request {
	get := func(k string) string {
		if v := q[k]; len(v) > 0 {
			return strings.TrimSpace(v[0])
		}
		return ""
	}
	req := rbac.Request{Verb: get("verb"), Group: get("group"), Resource: get("resource"), Subresource: get("subresource"),
		Name: get("resourceName"), Namespace: get("namespace"), Path: get("path")}
	if res, sub, ok := strings.Cut(req.Resource, "/"); ok && req.Subresource == "" {
		req.Resource, req.Subresource = res, sub
	}
	return req
}

func (s *Server) handleRBACWhoCan(w http.ResponseWriter, r *http.Request) {
	req := requestFromQuery(r.URL.Query())
	if req.Verb == "" || (req.Resource == "" && req.Path == "") {
		writeErr(w, httpx.BadRequest("verb and resource (or path) are required"))
		return
	}
	c := s.mgr.Clients()
	ctx, cancel := rbacCtx(r)
	defer cancel()
	p, err := loadPolicy(ctx, c)
	if err != nil {
		writeErr(w, err)
		return
	}
	res, _ := rbacResources(c)
	combined := req.Resource
	if req.Subresource != "" {
		combined += "/" + req.Subresource
	}
	httpx.WriteJSON(w, http.StatusOK, p.WhoCan(req, namespacedResource(res, req.Group, combined)))
}

// selfIdentity asks the API server who the current credentials are
// (SelfSubjectReview: v1 from Kubernetes 1.28, beta 1.27, alpha 1.26).
// Older servers: the client certificate's CN and O, when that's how we
// authenticate. Returns the identity and where it came from.
func selfIdentity(ctx context.Context, c *cluster.Clients) (*rbac.Identity, string, error) {
	from := func(u authnv1.UserInfo) *rbac.Identity {
		return &rbac.Identity{User: u.Username, Groups: append([]string{}, u.Groups...)}
	}
	ssr, err := c.Typed.AuthenticationV1().SelfSubjectReviews().Create(ctx, &authnv1.SelfSubjectReview{}, metav1.CreateOptions{})
	if err == nil {
		return from(ssr.Status.UserInfo), "SelfSubjectReview", nil
	}
	if b, berr := c.Typed.AuthenticationV1beta1().SelfSubjectReviews().Create(ctx, &authnv1beta1.SelfSubjectReview{}, metav1.CreateOptions{}); berr == nil {
		return from(b.Status.UserInfo), "SelfSubjectReview", nil
	}
	if a, aerr := c.Typed.AuthenticationV1alpha1().SelfSubjectReviews().Create(ctx, &authnv1alpha1.SelfSubjectReview{}, metav1.CreateOptions{}); aerr == nil {
		return from(a.Status.UserInfo), "SelfSubjectReview", nil
	}
	if id := certIdentity(c.RESTConfig); id != nil {
		return id, "client certificate", nil
	}
	return nil, "", err
}

// certIdentity is who a kubeconfig authenticates as when the server can't
// say: the impersonated user, else the client certificate's CN and O.
func certIdentity(cfg *rest.Config) *rbac.Identity {
	if cfg == nil {
		return nil
	}
	// A kubeconfig that impersonates (`as:`) acts as that user.
	if u := cfg.Impersonate.UserName; u != "" {
		groups := append([]string{}, cfg.Impersonate.Groups...)
		if strings.HasPrefix(u, "system:serviceaccount:") {
			if parts := strings.Split(u, ":"); len(parts) == 4 {
				groups = append(groups, "system:serviceaccounts", "system:serviceaccounts:"+parts[2])
			}
		}
		return &rbac.Identity{User: u, Groups: append(groups, "system:authenticated")}
	}
	data := cfg.CertData
	if len(data) == 0 && cfg.CertFile != "" {
		data, _ = os.ReadFile(cfg.CertFile)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil || cert.Subject.CommonName == "" {
		return nil
	}
	groups := append([]string{}, cert.Subject.Organization...)
	return &rbac.Identity{User: cert.Subject.CommonName, Groups: append(groups, "system:authenticated")}
}

// handleRBACSelf: what the app's own credentials may do in a namespace,
// from SelfSubjectRulesReview (no RBAC list permission needed), plus who
// the API server says we are.
func (s *Server) handleRBACSelf(w http.ResponseWriter, r *http.Request) {
	c := s.mgr.Clients()
	ctx, cancel := rbacCtx(r)
	defer cancel()
	ns := r.URL.Query().Get("namespace")
	evalNS := ns
	if evalNS == "" {
		evalNS = "default"
	}
	out := map[string]any{"context": c.Context, "namespace": ns, "evaluatedIn": evalNS, "readOnly": s.isReadOnly()}
	if id, source, err := selfIdentity(ctx, c); err == nil {
		out["identity"], out["identitySource"] = id, source
	} else {
		out["identityError"] = err.Error()
	}
	ssrr, err := c.Typed.AuthorizationV1().SelfSubjectRulesReviews().Create(ctx, &authzv1.SelfSubjectRulesReview{Spec: authzv1.SelfSubjectRulesReviewSpec{Namespace: evalNS}}, metav1.CreateOptions{})
	if err != nil {
		writeErr(w, err)
		return
	}
	var rules []rbacv1.PolicyRule
	for _, rr := range ssrr.Status.ResourceRules {
		rules = append(rules, rbacv1.PolicyRule{Verbs: rr.Verbs, APIGroups: rr.APIGroups, Resources: rr.Resources, ResourceNames: rr.ResourceNames})
	}
	for _, nr := range ssrr.Status.NonResourceRules {
		rules = append(rules, rbacv1.PolicyRule{Verbs: nr.Verbs, NonResourceURLs: nr.NonResourceURLs})
	}
	res, err := rbacResources(c)
	if err != nil {
		writeErr(w, err)
		return
	}
	m := rbac.RulesMatrix(rules, rbac.Ref{Kind: "SelfSubjectRulesReview", Name: evalNS}, ns, res)
	out["matrix"] = m
	out["incomplete"] = ssrr.Status.Incomplete
	if ssrr.Status.EvaluationError != "" {
		out["evaluationError"] = ssrr.Status.EvaluationError
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// CheckRequest is the body of POST /api/rbac/check.
type CheckRequest struct {
	// Subject nil = the current credentials (SelfSubjectAccessReview).
	Subject *rbac.Subject `json:"subject,omitempty"`
	Groups  []string      `json:"groups,omitempty"`
	Request rbac.Request  `json:"request"`
}

// handleRBACCheck asks the API server (SubjectAccessReview, or
// SelfSubjectAccessReview without a subject) and compares the answer with
// the local resolver. Reviews persist nothing, so this works read-only.
func (s *Server) handleRBACCheck(w http.ResponseWriter, r *http.Request) {
	var body CheckRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("invalid body: %v", err))
		return
	}
	req := body.Request
	if res, sub, ok := strings.Cut(req.Resource, "/"); ok && req.Subresource == "" {
		req.Resource, req.Subresource = res, sub
	}
	if req.Verb == "" || (req.Resource == "" && req.Path == "") {
		writeErr(w, httpx.BadRequest("request.verb and request.resource (or path) are required"))
		return
	}
	c := s.mgr.Clients()
	ctx, cancel := rbacCtx(r)
	defer cancel()
	res, _ := rbacResources(c)
	combined := req.Resource
	if req.Subresource != "" {
		combined += "/" + req.Subresource
	}
	namespaced := req.Path == "" && namespacedResource(res, req.Group, combined)
	if !namespaced {
		req.Namespace = ""
	}
	var ra *authzv1.ResourceAttributes
	var nra *authzv1.NonResourceAttributes
	if req.Path != "" {
		nra = &authzv1.NonResourceAttributes{Path: req.Path, Verb: req.Verb}
	} else {
		ra = &authzv1.ResourceAttributes{Namespace: req.Namespace, Verb: req.Verb, Group: req.Group, Resource: req.Resource, Subresource: req.Subresource, Name: req.Name}
	}
	var (
		id     *rbac.Identity
		status authzv1.SubjectAccessReviewStatus
		err    error
	)
	if body.Subject == nil {
		id, _, _ = selfIdentity(ctx, c)
		var out *authzv1.SelfSubjectAccessReview
		out, err = c.Typed.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx, &authzv1.SelfSubjectAccessReview{
			Spec: authzv1.SelfSubjectAccessReviewSpec{ResourceAttributes: ra, NonResourceAttributes: nra}}, metav1.CreateOptions{})
		if out != nil {
			status = out.Status
		}
	} else {
		ident := rbac.IdentityFor(*body.Subject, body.Groups)
		id = &ident
		var out *authzv1.SubjectAccessReview
		out, err = c.Typed.AuthorizationV1().SubjectAccessReviews().Create(ctx, &authzv1.SubjectAccessReview{
			Spec: authzv1.SubjectAccessReviewSpec{User: ident.User, Groups: ident.Groups, ResourceAttributes: ra, NonResourceAttributes: nra}}, metav1.CreateOptions{})
		if out != nil {
			status = out.Status
		}
	}
	if err != nil {
		writeErr(w, err)
		return
	}
	result := map[string]any{"request": req, "allowed": status.Allowed, "denied": status.Denied, "reason": status.Reason}
	if status.EvaluationError != "" {
		result["evaluationError"] = status.EvaluationError
	}
	if id != nil {
		result["identity"] = id
		if p, perr := loadPolicy(ctx, c); perr == nil {
			paths := p.Allowed(*id, req, namespaced)
			if paths == nil {
				paths = []rbac.Path{}
			}
			result["resolver"] = map[string]any{"allowed": len(paths) > 0, "paths": paths}
			result["agree"] = (len(paths) > 0) == status.Allowed
		} else {
			result["resolverError"] = perr.Error()
		}
	}
	httpx.WriteJSON(w, http.StatusOK, result)
}

var rbacKinds = map[string]string{"Role": "roles", "ClusterRole": "clusterroles", "RoleBinding": "rolebindings", "ClusterRoleBinding": "clusterrolebindings"}

// handleRBACApply creates or replaces one RBAC object from a YAML body.
// Replacing needs metadata.resourceVersion (409 otherwise, so a stale
// editor can't overwrite). Returns the object before and after (volatile
// metadata stripped) so the UI can show a diff; ?dryRun=true persists
// nothing. Escalation checks happen in the API server: a user can't grant
// what they don't hold, and gets a 403 that says so.
func (s *Server) handleRBACApply(w http.ResponseWriter, r *http.Request) {
	if s.isReadOnly() {
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorBody{Error: s.readOnlyMessage(), Code: http.StatusForbidden})
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
	if err != nil {
		writeErr(w, httpx.BadRequest("read body: %v", err))
		return
	}
	js, err := yaml.YAMLToJSON(raw)
	if err != nil {
		writeErr(w, httpx.BadRequest("invalid YAML: %v", err))
		return
	}
	obj := &unstructured.Unstructured{}
	if err := obj.UnmarshalJSON(js); err != nil {
		writeErr(w, httpx.BadRequest("invalid object: %v", err))
		return
	}
	gv, _ := schema.ParseGroupVersion(obj.GetAPIVersion())
	resource, ok := rbacKinds[obj.GetKind()]
	if gv.Group != rbac.Group || !ok {
		writeErr(w, httpx.BadRequest("only %s Role, ClusterRole, RoleBinding and ClusterRoleBinding can be applied here", rbac.Group))
		return
	}
	namespaced := !strings.HasPrefix(obj.GetKind(), "Cluster")
	if obj.GetName() == "" || (namespaced && obj.GetNamespace() == "") {
		writeErr(w, httpx.BadRequest("metadata.name%s is required", map[bool]string{true: " and metadata.namespace", false: ""}[namespaced]))
		return
	}
	if !namespaced {
		obj.SetNamespace("")
	}
	c := s.mgr.Clients()
	ri := c.Dynamic.Resource(schema.GroupVersionResource{Group: rbac.Group, Version: gv.Version, Resource: resource})
	client := ri.Namespace(obj.GetNamespace())
	if !namespaced {
		client = ri.Namespace("")
	}
	dryRun := r.URL.Query().Get("dryRun") == "true"
	var dr []string
	if dryRun {
		dr = []string{metav1.DryRunAll}
	}
	before, err := client.Get(r.Context(), obj.GetName(), metav1.GetOptions{})
	created := false
	var after *unstructured.Unstructured
	switch {
	case apierrors.IsNotFound(err):
		before, created = nil, true
		obj.SetResourceVersion("")
		after, err = client.Create(r.Context(), obj, metav1.CreateOptions{FieldManager: fieldManager, DryRun: dr})
	case err != nil:
	case obj.GetResourceVersion() == "":
		err = apierrors.NewAlreadyExists(schema.GroupResource{Group: rbac.Group, Resource: resource}, obj.GetName())
	default:
		after, err = client.Update(r.Context(), obj, metav1.UpdateOptions{FieldManager: fieldManager, DryRun: dr})
	}
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"dryRun":          dryRun,
		"created":         created,
		"before":          cleanYAML(before),
		"after":           cleanYAML(after),
		"resourceVersion": after.GetResourceVersion(),
		"context":         c.Context,
	})
}

// cleanYAML renders an object for a diff, without server-managed noise.
func cleanYAML(u *unstructured.Unstructured) string {
	if u == nil {
		return ""
	}
	u = u.DeepCopy()
	u.SetManagedFields(nil)
	for _, f := range []string{"resourceVersion", "uid", "creationTimestamp", "generation"} {
		unstructured.RemoveNestedField(u.Object, "metadata", f)
	}
	if a := u.GetAnnotations(); a != nil {
		delete(a, "kubectl.kubernetes.io/last-applied-configuration")
		if len(a) == 0 {
			unstructured.RemoveNestedField(u.Object, "metadata", "annotations")
		} else {
			u.SetAnnotations(a)
		}
	}
	y, err := yaml.Marshal(u.Object)
	if err != nil {
		return fmt.Sprintf("# %v", err)
	}
	return string(y)
}
