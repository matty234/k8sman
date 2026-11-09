package server

import (
	"context"
	"encoding/json"
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
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/security"
)

const (
	trivyGV   = "aquasecurity.github.io/v1alpha1"
	gatewayGr = "gateway.networking.k8s.io"
)

func (s *Server) securityRoutes() {
	sc := security.NewScanner()
	s.mux.HandleFunc("GET /api/security", func(w http.ResponseWriter, r *http.Request) { s.handleSecurity(w, r, sc) })
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
	scope, err := s.parseScope(q)
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	wait, err := parseSoftWait(r, securitySoftWait, securityMaxWait)
	if err != nil {
		writeErr(w, err)
		return
	}
	ns := scope.String() // "" = all, "a" or a set "a,b" (see listScope)
	c := s.mgr.Clients()

	// With an allowlist, RBAC is read in the allowed namespaces too: a
	// tenant may not list Roles cluster-wide.
	rbacNS := ""
	if len(s.allowedNamespaces()) > 0 {
		rbacNS = ns
	}
	l := s.securityRuns.get(fmt.Sprintf("%p|%s|%s", c, ns, rbacNS), func() *securityLists { return startSecurity(c, ns, rbacNS) })
	if !l.await(r.Context(), wait) {
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
	if s.settings != nil {
		security.ApplyIgnores(res, s.settings.SecurityIgnores(c.Context))
	}
	if len(errs) > 0 {
		res.Errors = map[string]string{}
		for k, e := range errs {
			res.Errors[k] = e.Error()
		}
	}
	httpx.WriteJSON(w, 200, res)
}

// servedResources returns the resources served for group/version, or nil.
func servedResources(c *cluster.Clients, gv string) map[string]bool {
	l, err := c.Discovery.ServerResourcesForGroupVersion(gv)
	if err != nil || l == nil {
		return nil
	}
	out := map[string]bool{}
	for _, r := range l.APIResources {
		out[r.Name] = true
	}
	return out
}

func gatewayVersion(c *cluster.Clients) (string, map[string]bool) {
	for _, v := range []string{"v1", "v1beta1"} {
		if res := servedResources(c, gatewayGr+"/"+v); res != nil {
			return v, res
		}
	}
	return "", nil
}

// securityList lists one core type into the input with set.
func securityList[T any](l *securityLists, kc *kcache.Cache, name string, gvr schema.GroupVersionResource, ns string, set func(in *security.Input, v []T)) {
	l.Go(name, func() (func(*security.Input), error) {
		items, err := listTyped[T](l.Ctx, kc, gvr, ns, "")
		if err != nil {
			return nil, err
		}
		return func(in *security.Input) { set(in, items) }, nil
	})
}

// startSecurity starts every list the analysis needs, under its own context
// (the hard limit), not the request's, so the lists survive a request that
// answered early.
func startSecurity(c *cluster.Clients, ns, rbacNS string) *securityLists {
	ctx, cancel := context.WithTimeout(context.Background(), securityHardWait)
	l := newSourceRun[security.Input](ctx, "pods", nil, securityHardWait, securityReuse)
	// Lists go through the shared watch cache (see listTyped).
	kc := kcache.For(c)

	securityList(l, kc, "pods", gvrPods, ns, func(in *security.Input, v []corev1.Pod) { in.Pods = v })
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
	securityList(l, kc, "deployments", gvrDeployments, ns, func(in *security.Input, v []appsv1.Deployment) { in.Deployments = v })
	securityList(l, kc, "statefulsets", gvrStatefulSets, ns, func(in *security.Input, v []appsv1.StatefulSet) { in.StatefulSets = v })
	securityList(l, kc, "daemonsets", gvrDaemonSets, ns, func(in *security.Input, v []appsv1.DaemonSet) { in.DaemonSets = v })
	securityList(l, kc, "replicasets", gvrReplicaSets, ns, func(in *security.Input, v []appsv1.ReplicaSet) { in.ReplicaSets = v })
	securityList(l, kc, "jobs", gvrJobs, ns, func(in *security.Input, v []batchv1.Job) { in.Jobs = v })
	securityList(l, kc, "cronjobs", gvrCronJobs, ns, func(in *security.Input, v []batchv1.CronJob) { in.CronJobs = v })
	securityList(l, kc, "services", gvrServices, ns, func(in *security.Input, v []corev1.Service) { in.Services = v })
	securityList(l, kc, "serviceaccounts", gvrServiceAccounts, ns, func(in *security.Input, v []corev1.ServiceAccount) { in.ServiceAccounts = v })
	securityList(l, kc, "ingresses", gvrIngresses, ns, func(in *security.Input, v []networkingv1.Ingress) { in.Ingresses = v })
	securityList(l, kc, "networkpolicies", gvrNetworkPolicies, ns, func(in *security.Input, v []networkingv1.NetworkPolicy) { in.NetworkPolicies = v })
	// RBAC is listed cluster-wide: whether a role is bound, or a
	// ClusterRoleBinding names a ServiceAccount in ns, needs every binding.
	securityList(l, kc, "roles", gvrRoles, rbacNS, func(in *security.Input, v []rbacv1.Role) { in.Roles = v })
	securityList(l, kc, "rolebindings", gvrRoleBindings, rbacNS, func(in *security.Input, v []rbacv1.RoleBinding) { in.RoleBindings = v })
	securityList(l, kc, "clusterroles", gvrClusterRoles, "", func(in *security.Input, v []rbacv1.ClusterRole) { in.ClusterRoles = v })
	securityList(l, kc, "clusterrolebindings", gvrClusterRoleBindings, "", func(in *security.Input, v []rbacv1.ClusterRoleBinding) { in.ClusterRoleBindings = v })

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
	if v, res := gatewayVersion(c); v != "" {
		if res["gateways"] {
			dyn("gateways", schema.GroupVersionResource{Group: gatewayGr, Version: v, Resource: "gateways"}, true,
				func(in *security.Input, v []unstructured.Unstructured) { in.Gateways = v })
		}
		if res["httproutes"] {
			dyn("httproutes", schema.GroupVersionResource{Group: gatewayGr, Version: v, Resource: "httproutes"}, true,
				func(in *security.Input, v []unstructured.Unstructured) { in.HTTPRoutes = v })
		}
	}
	if res := servedResources(c, trivyGV); res["vulnerabilityreports"] {
		l.Set(func(in *security.Input) { in.TrivyOperator = true })
		gvr := func(r string) schema.GroupVersionResource {
			return schema.GroupVersionResource{Group: "aquasecurity.github.io", Version: "v1alpha1", Resource: r}
		}
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
	if res := servedResources(c, trivyGV); res["vulnerabilityreports"] {
		op.Installed = true
		for _, k := range []string{"vulnerabilityreports", "configauditreports", "exposedsecretreports", "rbacassessmentreports", "clusterrbacassessmentreports"} {
			if res[k] {
				op.Reports = append(op.Reports, k)
			}
		}
		l, err := c.Dynamic.Resource(schema.GroupVersionResource{Group: "aquasecurity.github.io", Version: "v1alpha1", Resource: "vulnerabilityreports"}).
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
	var body struct {
		Image string `json:"image"`
		Force bool   `json:"force"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("invalid body: %v", err))
		return
	}
	res, err := sc.Scan(r.Context(), body.Image, body.Force)
	switch {
	case errors.Is(err, security.ErrBadImage):
		writeErr(w, httpx.BadRequest("%v: %q", err, body.Image))
	case errors.Is(err, security.ErrNoTrivy):
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorBody{Error: err.Error(), Code: http.StatusServiceUnavailable, Reason: "ScannerUnavailable"})
	case err != nil:
		httpx.WriteJSON(w, http.StatusBadGateway, httpx.ErrorBody{Error: err.Error(), Code: http.StatusBadGateway, Reason: "ScanFailed"})
	default:
		httpx.WriteJSON(w, 200, res)
	}
}
