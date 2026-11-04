package server

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/overview"
	"github.com/matty234/k8sman/backend/internal/prom"
)

func (s *Server) overviewRoutes() {
	s.mux.HandleFunc("GET /api/overview", s.handleOverview)
}

// handleOverview lists every relevant type once, in parallel, and returns the
// health analysis. Lists that fail (e.g. RBAC forbids nodes) are reported in
// `errors` instead of failing the whole request, unless pods cannot be listed.
func (s *Server) handleOverview(w http.ResponseWriter, r *http.Request) {
	ns := r.URL.Query().Get("namespace")
	c := s.mgr.Clients()
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	in, errs := listForOverview(ctx, c, ns)
	if err, ok := errs["pods"]; ok {
		writeErr(w, err)
		return
	}
	res := overview.Analyze(in)
	res.Namespace = ns
	if len(errs) > 0 {
		res.Errors = map[string]string{}
		for k, e := range errs {
			res.Errors[k] = e.Error()
		}
	}
	httpx.WriteJSON(w, 200, res)
}

func listForOverview(ctx context.Context, c *cluster.Clients, ns string) (overview.Input, map[string]error) {
	in := overview.Input{Now: time.Now()}
	// Lists go through the shared watch cache: the first poll costs one
	// LIST per type, later polls (every 10s while the page is open) none.
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
	run("nodes", func() error {
		var err error
		in.Nodes, err = listTyped[corev1.Node](ctx, kc, gvrNodes, "", "")
		return err
	})
	run("persistentvolumeclaims", func() error {
		var err error
		in.PVCs, err = listTyped[corev1.PersistentVolumeClaim](ctx, kc, gvrPVCs, ns, "")
		return err
	})
	run("events", func() error {
		var err error
		in.Events, err = listTyped[corev1.Event](ctx, kc, gvrEvents, ns, "type=Warning")
		return err
	})
	// Argo CD Applications, only when the CRD is served. Listed across all
	// namespaces (apps live in the Argo CD namespace) and filtered to those
	// in, or deploying to, the selected namespace.
	if rt, err := c.Find(ctx, "argoproj.io", "", "applications"); err == nil {
		run("applications.argoproj.io", func() error {
			items, err := listCached(ctx, kc, rt.GVR(), "")
			if err != nil {
				return err
			}
			apps := []map[string]any{}
			for _, it := range items {
				dest, _, _ := unstructured.NestedString(it.Object, "spec", "destination", "namespace")
				if ns == "" || it.GetNamespace() == ns || dest == ns {
					apps = append(apps, it.Object)
				}
			}
			mu.Lock()
			in.ArgoApps = apps
			mu.Unlock()
			return nil
		})
	}
	// Argo Workflows, only when the CRD is served.
	if rt, err := c.Find(ctx, "argoproj.io", "", "workflows"); err == nil {
		run("workflows.argoproj.io", func() error {
			items, err := listCached(ctx, kc, rt.GVR(), ns)
			if err != nil {
				return err
			}
			wfs := make([]map[string]any, len(items))
			for i, it := range items {
				wfs[i] = it.Object
			}
			mu.Lock()
			in.Workflows = wfs
			mu.Unlock()
			return nil
		})
	}
	listGatewayAPI(ctx, c, ns, &in, run, &mu)
	run("alerts", func() error {
		a, err := prom.ActiveAlerts(ctx, c)
		in.Alerts = overview.FilterAlertsByNamespace(a, ns)
		return err
	})
	wg.Wait()
	return in, errs
}

// listGatewayAPI lists Gateways and every served route kind, but only when
// the Gateway API CRDs are installed (otherwise the inputs stay nil and the
// analysis skips them).
func listGatewayAPI(ctx context.Context, c *cluster.Clients, ns string, in *overview.Input, run func(string, func() error), mu *sync.Mutex) {
	gw, err := c.Find(ctx, overview.GatewayGroup, "", "gateways")
	if err != nil {
		return
	}
	list := func(t cluster.ResourceType) ([]unstructured.Unstructured, error) {
		gvr := schema.GroupVersionResource{Group: t.Group, Version: t.Version, Resource: t.Resource}
		items, err := listCached(ctx, kcache.For(c), gvr, ns)
		if err != nil {
			return nil, err
		}
		out := make([]unstructured.Unstructured, len(items))
		for i, it := range items {
			out[i] = *it
			if it.GetKind() == "" {
				// Lists may leave kind empty on items; the analysis needs it.
				// Items are shared with the cache, so set it on a copy.
				out[i] = *it.DeepCopy()
				out[i].SetKind(t.Kind)
			}
		}
		return out, nil
	}
	in.Routes = []unstructured.Unstructured{}
	run("gateways", func() error {
		items, err := list(gw)
		if err == nil {
			mu.Lock()
			in.Gateways = items
			mu.Unlock()
		}
		return err
	})
	for _, res := range overview.GatewayRouteResources {
		t, err := c.Find(ctx, overview.GatewayGroup, "", res)
		if err != nil {
			continue
		}
		run(res, func() error {
			items, err := list(t)
			if err == nil {
				mu.Lock()
				in.Routes = append(in.Routes, items...)
				mu.Unlock()
			}
			return err
		})
	}
}
