package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	rbacv1 "k8s.io/api/rbac/v1"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
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

// handleSecurity lists every relevant type once, in parallel, and returns
// the security analysis. Lists that fail (e.g. RBAC forbids them) are
// reported in `errors`, unless pods cannot be listed.
func (s *Server) handleSecurity(w http.ResponseWriter, r *http.Request, sc *security.Scanner) {
	q := r.URL.Query()
	ns := q.Get("namespace")
	c := s.mgr.Clients()
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	in, errs := listForSecurity(ctx, c, ns)
	if err, ok := errs["pods"]; ok {
		writeErr(w, err)
		return
	}
	in.IncludeSystem = q.Get("includeSystem") == "true"
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

func listForSecurity(ctx context.Context, c *cluster.Clients, ns string) (security.Input, map[string]error) {
	in := security.Input{Now: time.Now(), Namespace: ns}
	// Lists go through the shared watch cache (see listTyped).
	kc := kcache.For(c)

	var mu sync.Mutex
	errs := map[string]error{}
	var wg sync.WaitGroup
	run := func(name string, f func() error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := f(); err != nil {
				mu.Lock()
				errs[name] = fmt.Errorf("list %s: %w", name, err)
				mu.Unlock()
			}
		}()
	}
	run("pods", func() error {
		var err error
		in.Pods, err = listTyped[corev1.Pod](ctx, kc, gvrPods, ns, "")
		return err
	})
	run("namespaces", func() error {
		if ns != "" {
			n, err := c.Typed.CoreV1().Namespaces().Get(ctx, ns, metav1.GetOptions{})
			if err == nil {
				in.Namespaces = append(in.Namespaces, *n)
			}
			return err
		}
		var err error
		in.Namespaces, err = listTyped[corev1.Namespace](ctx, kc, gvrNamespaces, "", "")
		return err
	})
	run("deployments", func() error {
		var err error
		in.Deployments, err = listTyped[appsv1.Deployment](ctx, kc, gvrDeployments, ns, "")
		return err
	})
	run("statefulsets", func() error {
		var err error
		in.StatefulSets, err = listTyped[appsv1.StatefulSet](ctx, kc, gvrStatefulSets, ns, "")
		return err
	})
	run("daemonsets", func() error {
		var err error
		in.DaemonSets, err = listTyped[appsv1.DaemonSet](ctx, kc, gvrDaemonSets, ns, "")
		return err
	})
	run("replicasets", func() error {
		var err error
		in.ReplicaSets, err = listTyped[appsv1.ReplicaSet](ctx, kc, gvrReplicaSets, ns, "")
		return err
	})
	run("jobs", func() error {
		var err error
		in.Jobs, err = listTyped[batchv1.Job](ctx, kc, gvrJobs, ns, "")
		return err
	})
	run("cronjobs", func() error {
		var err error
		in.CronJobs, err = listTyped[batchv1.CronJob](ctx, kc, gvrCronJobs, ns, "")
		return err
	})
	run("services", func() error {
		var err error
		in.Services, err = listTyped[corev1.Service](ctx, kc, gvrServices, ns, "")
		return err
	})
	run("serviceaccounts", func() error {
		var err error
		in.ServiceAccounts, err = listTyped[corev1.ServiceAccount](ctx, kc, gvrServiceAccounts, ns, "")
		return err
	})
	run("ingresses", func() error {
		var err error
		in.Ingresses, err = listTyped[networkingv1.Ingress](ctx, kc, gvrIngresses, ns, "")
		return err
	})
	run("networkpolicies", func() error {
		var err error
		in.NetworkPolicies, err = listTyped[networkingv1.NetworkPolicy](ctx, kc, gvrNetworkPolicies, ns, "")
		return err
	})
	// RBAC is listed cluster-wide: whether a role is bound, or a
	// ClusterRoleBinding names a ServiceAccount in ns, needs every binding.
	run("roles", func() error {
		var err error
		in.Roles, err = listTyped[rbacv1.Role](ctx, kc, gvrRoles, "", "")
		return err
	})
	run("rolebindings", func() error {
		var err error
		in.RoleBindings, err = listTyped[rbacv1.RoleBinding](ctx, kc, gvrRoleBindings, "", "")
		return err
	})
	run("clusterroles", func() error {
		var err error
		in.ClusterRoles, err = listTyped[rbacv1.ClusterRole](ctx, kc, gvrClusterRoles, "", "")
		return err
	})
	run("clusterrolebindings", func() error {
		var err error
		in.ClusterRoleBindings, err = listTyped[rbacv1.ClusterRoleBinding](ctx, kc, gvrClusterRoleBindings, "", "")
		return err
	})

	dyn := func(name string, gvr schema.GroupVersionResource, namespaced bool, dst *[]unstructured.Unstructured) {
		run(name, func() error {
			lns := ""
			if namespaced {
				lns = ns
			}
			items, err := listCached(ctx, kc, gvr, lns)
			if err == nil {
				out := make([]unstructured.Unstructured, len(items))
				for i, it := range items {
					out[i] = *it // shares the object map: read only
				}
				mu.Lock()
				*dst = out
				mu.Unlock()
			}
			return err
		})
	}
	// Optional CRDs: skipped gracefully when not installed.
	if v, res := gatewayVersion(c); v != "" {
		if res["gateways"] {
			dyn("gateways", schema.GroupVersionResource{Group: gatewayGr, Version: v, Resource: "gateways"}, true, &in.Gateways)
		}
		if res["httproutes"] {
			dyn("httproutes", schema.GroupVersionResource{Group: gatewayGr, Version: v, Resource: "httproutes"}, true, &in.HTTPRoutes)
		}
	}
	if res := servedResources(c, trivyGV); res["vulnerabilityreports"] {
		in.TrivyOperator = true
		gvr := func(r string) schema.GroupVersionResource {
			return schema.GroupVersionResource{Group: "aquasecurity.github.io", Version: "v1alpha1", Resource: r}
		}
		dyn("vulnerabilityreports", gvr("vulnerabilityreports"), true, &in.VulnerabilityReports)
		if res["configauditreports"] {
			dyn("configauditreports", gvr("configauditreports"), true, &in.ConfigAuditReports)
		}
		if res["exposedsecretreports"] {
			dyn("exposedsecretreports", gvr("exposedsecretreports"), true, &in.ExposedSecretReports)
		}
		if res["rbacassessmentreports"] {
			dyn("rbacassessmentreports", gvr("rbacassessmentreports"), true, &in.RbacAssessmentReports)
		}
		if res["clusterrbacassessmentreports"] && ns == "" {
			dyn("clusterrbacassessmentreports", gvr("clusterrbacassessmentreports"), false, &in.ClusterRbacAssessmentReports)
		}
	}
	wg.Wait()
	return in, errs
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
		httpx.WriteJSON(w, http.StatusServiceUnavailable, apiError{Error: err.Error(), Code: http.StatusServiceUnavailable, Reason: "ScannerUnavailable"})
	case err != nil:
		httpx.WriteJSON(w, http.StatusBadGateway, apiError{Error: err.Error(), Code: http.StatusBadGateway, Reason: "ScanFailed"})
	default:
		httpx.WriteJSON(w, 200, res)
	}
}
