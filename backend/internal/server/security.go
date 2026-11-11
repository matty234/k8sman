package server

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	rbacv1 "k8s.io/api/rbac/v1"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kapi"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/security"
)

func (s *Server) securityRoutes() {
	sc := security.NewScanner()
	s.mux.HandleFunc("GET /api/security", func(w http.ResponseWriter, r *http.Request) { s.handleSecurity(w, r, sc) })
	s.mux.HandleFunc("GET /api/security/object", func(w http.ResponseWriter, r *http.Request) { s.handleSecurityObject(w, r, sc) })
	s.mux.HandleFunc("GET /api/security/scanner", func(w http.ResponseWriter, r *http.Request) { s.handleScannerStatus(w, r, sc) })
	s.mux.HandleFunc("POST /api/security/scan", func(w http.ResponseWriter, r *http.Request) { handleScan(w, r, sc) })
}

// Soft deadline of /api/security, as for /api/overview: the response goes
// out with the categories whose lists have completed by then (pods
// excepted), the rest named in `pending`.
const (
	securitySoftWait = 1200 * time.Millisecond
	securityMaxWait  = 10 * time.Second
	securityHardWait = 30 * time.Second
	securityReuse    = time.Second
)

// securityLists is one run of the security lists (see sourceRun).
type securityLists = sourceRun[security.Input]

// handleSecurity lists every relevant type once, in parallel, and returns
// the security analysis. Lists that fail (e.g. RBAC forbids them) are
// reported in `errors`, unless pods cannot be listed.
//
// It answers after the soft deadline (`wait`, default 1.2s, at most 10s)
// with the categories whose lists have completed, naming the others in
// `pending`; their lists keep running (detached from the request, under the
// 30s limit) so the next poll finds them done. Pods are always waited for.
// One run is shared per context and scope: includeSystem is applied at
// analysis time.
func (s *Server) handleSecurity(w http.ResponseWriter, r *http.Request, sc *security.Scanner) {
	q := r.URL.Query()
	// With an allowlist, RBAC is read in the allowed namespaces too: a
	// tenant may not list Roles cluster-wide.
	rbacOf := func(ns string) string {
		if len(s.allowedNamespaces()) > 0 {
			return ns
		}
		return ""
	}
	l, c, ns, ok := softRequest(s, w, r, securitySoftWait, securityMaxWait, &s.securityRuns,
		func(c *cluster.Clients, ns string) string { return fmt.Sprintf("%p|%s|%s", c, ns, rbacOf(ns)) },
		func(c *cluster.Clients, ns string) *securityLists { return startSecurity(c, ns, rbacOf(ns)) })
	if !ok {
		return
	}
	in, pending, errs := l.snap()
	if err, ok := errs["pods"]; ok {
		writeErr(w, err)
		return
	}
	in.Now = time.Now()
	in.Namespace = ns
	in.IncludeSystem = q.Get("includeSystem") == "true"
	in.Pending = security.PendingCategories(pending)
	res := security.Analyze(in)
	// Fill in images scanned on demand with the local trivy CLI.
	for i := range res.Images {
		img := &res.Images[i]
		if img.Scanned {
			continue
		}
		if cr := sc.Cached(img.Image); cr != nil {
			img.Scanned, img.Source, img.ScannedAt, img.Counts = true, "trivy-cli", cr.ScannedAt, cr.Counts
			n := min(len(cr.Vulnerabilities), 5)
			img.TopCVEs = cr.Vulnerabilities[:n]
		}
	}
	// Ignore rules are applied here, to this request's own result, not in
	// the shared run: editing them takes effect on the next fetch.
	security.ApplyIgnores(res, s.settings.SecurityIgnores(c.Context))
	res.Errors = errStrings(errs)
	httpx.WriteJSON(w, 200, res)
}

// handleSecurityObject is the security of one Pod or workload, for the
// inspector's Security tab: ?namespace=&kind=&name= (group optional). It
// shares the namespace's security run with /api/security?namespace=, waits
// up to the soft deadline like it, and names what is still loading in
// `pending`.
func (s *Server) handleSecurityObject(w http.ResponseWriter, r *http.Request, sc *security.Scanner) {
	q := r.URL.Query()
	obj := security.ObjectRef{Group: q.Get("group"), Kind: q.Get("kind"), Name: q.Get("name"), Namespace: q.Get("namespace")}
	if obj.Namespace == "" || obj.Kind == "" || obj.Name == "" || q.Get("namespaces") != "" {
		writeErr(w, httpx.BadRequest("want namespace, kind and name"))
		return
	}
	if allowed := s.allowedNamespaces(); len(allowed) > 0 && !allowed.Contains(obj.Namespace) {
		httpx.WriteError(w, http.StatusForbidden, "Forbidden", "namespace "+obj.Namespace+" is outside this context's allowlist")
		return
	}
	rbacOf := func(ns string) string {
		if len(s.allowedNamespaces()) > 0 {
			return ns
		}
		return ""
	}
	l, c, _, ok := softRequest(s, w, r, securitySoftWait, securityMaxWait, &s.securityRuns,
		func(c *cluster.Clients, ns string) string { return fmt.Sprintf("%p|%s|%s", c, ns, rbacOf(ns)) },
		func(c *cluster.Clients, ns string) *securityLists { return startSecurity(c, ns, rbacOf(ns)) })
	if !ok {
		return
	}
	in, pending, errs := l.snap()
	if err, ok := errs["pods"]; ok {
		writeErr(w, err)
		return
	}
	in.Now = time.Now()
	in.Namespace = obj.Namespace
	// The object is shown wherever it lives, system namespaces included.
	in.IncludeSystem = true
	in.Pending = security.PendingCategories(pending)
	res := security.AnalyzeObject(in, obj, s.settings.SecurityIgnores(c.Context))
	// Images scanned on demand with the local trivy CLI.
	for i := range res.Images {
		img := &res.Images[i]
		if img.Scanned {
			continue
		}
		if cr := sc.Cached(img.Image); cr != nil {
			img.Scanned, img.Source, img.ScannedAt, img.Counts, img.CVEs = true, "trivy-cli", cr.ScannedAt, cr.Counts, cr.Vulnerabilities
		}
	}
	res.Errors = errStrings(errs)
	httpx.WriteJSON(w, 200, res)
}

// startSecurity starts every list the analysis needs, under its own context
// (the hard limit), not the request's, so the lists survive a request that
// answered early.
func startSecurity(c *cluster.Clients, ns, rbacNS string) *securityLists {
	ctx, cancel := context.WithTimeout(context.Background(), securityHardWait)
	l := newSourceRun[security.Input](ctx, "pods", nil, securityHardWait, securityReuse)
	// Lists go through the shared watch cache (see listTyped).
	kc := kcache.For(c)

	listInto(l, kc, "pods", gvrPods, ns, "", func(in *security.Input, v []corev1.Pod) { in.Pods = v })
	l.Go("namespaces", func() (func(*security.Input), error) {
		var out []corev1.Namespace
		if ns != "" {
			// Each namespace of the scope from a warm namespaces watch when
			// there is one (no round trip), else a GET (listing every
			// namespace may be forbidden). A set skips the ones it can't read.
			set := kube.SplitNamespaces(ns)
			var firstErr error
			for _, name := range set {
				if snap, ok := kc.Cached(kcache.Key{GVR: gvrNamespaces, FieldSelector: "metadata.name=" + name}); ok && len(snap.Items) == 1 {
					var n corev1.Namespace
					if err := runtime.DefaultUnstructuredConverter.FromUnstructured(snap.Items[0].Object, &n); err != nil {
						return nil, err
					}
					out = append(out, n)
				} else if n, err := c.Typed.CoreV1().Namespaces().Get(ctx, name, metav1.GetOptions{}); err == nil {
					out = append(out, *n)
				} else if firstErr == nil {
					firstErr = err
				}
			}
			if len(out) == 0 && firstErr != nil {
				return nil, firstErr
			}
		} else {
			var err error
			if out, err = listTyped[corev1.Namespace](ctx, kc, gvrNamespaces, "", ""); err != nil {
				return nil, err
			}
		}
		return func(in *security.Input) { in.Namespaces = out }, nil
	})
	listInto(l, kc, "deployments", gvrDeployments, ns, "", func(in *security.Input, v []appsv1.Deployment) { in.Deployments = v })
	listInto(l, kc, "statefulsets", gvrStatefulSets, ns, "", func(in *security.Input, v []appsv1.StatefulSet) { in.StatefulSets = v })
	listInto(l, kc, "daemonsets", gvrDaemonSets, ns, "", func(in *security.Input, v []appsv1.DaemonSet) { in.DaemonSets = v })
	listInto(l, kc, "replicasets", gvrReplicaSets, ns, "", func(in *security.Input, v []appsv1.ReplicaSet) { in.ReplicaSets = v })
	listInto(l, kc, "jobs", gvrJobs, ns, "", func(in *security.Input, v []batchv1.Job) { in.Jobs = v })
	listInto(l, kc, "cronjobs", gvrCronJobs, ns, "", func(in *security.Input, v []batchv1.CronJob) { in.CronJobs = v })
	listInto(l, kc, "services", gvrServices, ns, "", func(in *security.Input, v []corev1.Service) { in.Services = v })
	listInto(l, kc, "serviceaccounts", gvrServiceAccounts, ns, "", func(in *security.Input, v []corev1.ServiceAccount) { in.ServiceAccounts = v })
	listInto(l, kc, "ingresses", gvrIngresses, ns, "", func(in *security.Input, v []networkingv1.Ingress) { in.Ingresses = v })
	listInto(l, kc, "networkpolicies", gvrNetworkPolicies, ns, "", func(in *security.Input, v []networkingv1.NetworkPolicy) { in.NetworkPolicies = v })
	// RBAC is listed cluster-wide: whether a role is bound, or a
	// ClusterRoleBinding names a ServiceAccount in ns, needs every binding.
	listInto(l, kc, "roles", gvrRoles, rbacNS, "", func(in *security.Input, v []rbacv1.Role) { in.Roles = v })
	listInto(l, kc, "rolebindings", gvrRoleBindings, rbacNS, "", func(in *security.Input, v []rbacv1.RoleBinding) { in.RoleBindings = v })
	listInto(l, kc, "clusterroles", gvrClusterRoles, "", "", func(in *security.Input, v []rbacv1.ClusterRole) { in.ClusterRoles = v })
	listInto(l, kc, "clusterrolebindings", gvrClusterRoleBindings, "", "", func(in *security.Input, v []rbacv1.ClusterRoleBinding) { in.ClusterRoleBindings = v })

	dyn := func(name string, gvr schema.GroupVersionResource, namespaced bool, set func(in *security.Input, v []unstructured.Unstructured)) {
		l.Go(name, func() (func(*security.Input), error) {
			lns := ""
			if namespaced {
				lns = ns
			}
			items, err := listCached(ctx, kc, gvr, lns)
			if err != nil {
				return nil, err
			}
			out := make([]unstructured.Unstructured, len(items))
			for i, it := range items {
				out[i] = *it // shares the object map: read only
			}
			return func(in *security.Input) { set(in, out) }, nil
		})
	}
	// Optional CRDs: skipped gracefully when not installed.
	if v, res := kapi.GatewayAPI.Served(c.Discovery); v != "" {
		if res["gateways"] {
			dyn("gateways", kapi.GatewayAPI.GVR(v, "gateways"), true,
				func(in *security.Input, v []unstructured.Unstructured) { in.Gateways = v })
		}
		if res["httproutes"] {
			dyn("httproutes", kapi.GatewayAPI.GVR(v, "httproutes"), true,
				func(in *security.Input, v []unstructured.Unstructured) { in.HTTPRoutes = v })
		}
	}
	if tv, res := kapi.Trivy.Served(c.Discovery); res["vulnerabilityreports"] {
		l.Set(func(in *security.Input) { in.TrivyOperator = true })
		gvr := func(r string) schema.GroupVersionResource { return kapi.Trivy.GVR(tv, r) }
		dyn("vulnerabilityreports", gvr("vulnerabilityreports"), true, func(in *security.Input, v []unstructured.Unstructured) { in.VulnerabilityReports = v })
		if res["configauditreports"] {
			dyn("configauditreports", gvr("configauditreports"), true, func(in *security.Input, v []unstructured.Unstructured) { in.ConfigAuditReports = v })
		}
		if res["exposedsecretreports"] {
			dyn("exposedsecretreports", gvr("exposedsecretreports"), true, func(in *security.Input, v []unstructured.Unstructured) { in.ExposedSecretReports = v })
		}
		if res["rbacassessmentreports"] {
			dyn("rbacassessmentreports", gvr("rbacassessmentreports"), true, func(in *security.Input, v []unstructured.Unstructured) { in.RbacAssessmentReports = v })
		}
		if res["clusterrbacassessmentreports"] && ns == "" {
			dyn("clusterrbacassessmentreports", gvr("clusterrbacassessmentreports"), false, func(in *security.Input, v []unstructured.Unstructured) { in.ClusterRbacAssessmentReports = v })
		}
	}
	l.sealed(cancel)
	return l
}

// OperatorStatus describes the in-cluster Trivy Operator.
type OperatorStatus struct {
	Installed bool `json:"installed"`
	// Reports lists which report CRDs are served.
	Reports []string `json:"reports"`
	// HasReports is true once at least one VulnerabilityReport exists;
	// Scanning is installed-but-none-yet (the first scans take minutes).
	HasReports bool   `json:"hasReports"`
	Scanning   bool   `json:"scanning"`
	Error      string `json:"error,omitempty"`
}

func (s *Server) handleScannerStatus(w http.ResponseWriter, r *http.Request, sc *security.Scanner) {
	c := s.mgr.Clients()
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	op := OperatorStatus{Reports: []string{}}
	if tv, res := kapi.Trivy.Served(c.Discovery); res["vulnerabilityreports"] {
		op.Installed = true
		for _, k := range []string{"vulnerabilityreports", "configauditreports", "exposedsecretreports", "rbacassessmentreports", "clusterrbacassessmentreports"} {
			if res[k] {
				op.Reports = append(op.Reports, k)
			}
		}
		l, err := c.Dynamic.Resource(kapi.Trivy.GVR(tv, "vulnerabilityreports")).
			List(ctx, metav1.ListOptions{Limit: 1})
		if err != nil {
			op.Error = err.Error()
		} else {
			op.HasReports = len(l.Items) > 0
			op.Scanning = !op.HasReports
		}
	}
	httpx.WriteJSON(w, 200, map[string]any{
		"operator":    op,
		"trivy":       sc.Status(ctx),
		"installHint": security.InstallHint,
	})
}

func handleScan(w http.ResponseWriter, r *http.Request, sc *security.Scanner) {
	type scanBody struct {
		Image string `json:"image"`
		Force bool   `json:"force"`
	}
	body, ok := httpx.DecodeJSON[scanBody](w, r, 1<<16)
	if !ok {
		return
	}
	res, err := sc.Scan(r.Context(), body.Image, body.Force)
	switch {
	case errors.Is(err, security.ErrBadImage):
		writeErr(w, httpx.BadRequest("%v: %q", err, body.Image))
	case errors.Is(err, security.ErrNoTrivy):
		httpx.WriteError(w, http.StatusServiceUnavailable, "ScannerUnavailable", err.Error())
	case err != nil:
		httpx.WriteError(w, http.StatusBadGateway, "ScanFailed", err.Error())
	default:
		httpx.WriteJSON(w, 200, res)
	}
}
