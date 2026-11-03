package server

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/cluster"
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
	writeJSON(w, 200, res)
}

func listForOverview(ctx context.Context, c *cluster.Clients, ns string) (overview.Input, map[string]error) {
	in := overview.Input{Now: time.Now()}
	// ResourceVersion "0" lets the apiserver answer from its watch cache.
	opts := metav1.ListOptions{ResourceVersion: "0"}
	core, apps, batch := c.Typed.CoreV1(), c.Typed.AppsV1(), c.Typed.BatchV1()

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
		l, err := core.Pods(ns).List(ctx, opts)
		if err == nil {
			in.Pods = l.Items
		}
		return err
	})
	run("deployments", func() error {
		l, err := apps.Deployments(ns).List(ctx, opts)
		if err == nil {
			in.Deployments = l.Items
		}
		return err
	})
	run("statefulsets", func() error {
		l, err := apps.StatefulSets(ns).List(ctx, opts)
		if err == nil {
			in.StatefulSets = l.Items
		}
		return err
	})
	run("daemonsets", func() error {
		l, err := apps.DaemonSets(ns).List(ctx, opts)
		if err == nil {
			in.DaemonSets = l.Items
		}
		return err
	})
	run("replicasets", func() error {
		l, err := apps.ReplicaSets(ns).List(ctx, opts)
		if err == nil {
			in.ReplicaSets = l.Items
		}
		return err
	})
	run("jobs", func() error {
		l, err := batch.Jobs(ns).List(ctx, opts)
		if err == nil {
			in.Jobs = l.Items
		}
		return err
	})
	run("cronjobs", func() error {
		l, err := batch.CronJobs(ns).List(ctx, opts)
		if err == nil {
			in.CronJobs = l.Items
		}
		return err
	})
	run("nodes", func() error {
		l, err := core.Nodes().List(ctx, opts)
		if err == nil {
			in.Nodes = l.Items
		}
		return err
	})
	run("persistentvolumeclaims", func() error {
		l, err := core.PersistentVolumeClaims(ns).List(ctx, opts)
		if err == nil {
			in.PVCs = l.Items
		}
		return err
	})
	run("events", func() error {
		l, err := core.Events(ns).List(ctx, metav1.ListOptions{ResourceVersion: "0", FieldSelector: "type=Warning"})
		if err == nil {
			in.Events = l.Items
		}
		return err
	})
	// Argo CD Applications, only when the CRD is served. Listed across all
	// namespaces (apps live in the Argo CD namespace) and filtered to those
	// in, or deploying to, the selected namespace.
	if rt, err := c.Find(ctx, "argoproj.io", "", "applications"); err == nil {
		run("applications.argoproj.io", func() error {
			l, err := c.Dynamic.Resource(rt.GVR()).List(ctx, opts)
			if err != nil {
				return err
			}
			apps := []map[string]any{}
			for _, it := range l.Items {
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
		l, err := c.Dynamic.Resource(gvr).Namespace(ns).List(ctx, metav1.ListOptions{ResourceVersion: "0"})
		if err != nil {
			return nil, err
		}
		for i := range l.Items {
			// Lists leave kind empty on items; the analysis needs it.
			l.Items[i].SetKind(t.Kind)
		}
		return l.Items, nil
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
