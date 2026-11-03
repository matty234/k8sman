package server

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/bargrove/k8sman/backend/internal/cluster"
	"github.com/bargrove/k8sman/backend/internal/overview"
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
	wg.Wait()
	return in, errs
}
