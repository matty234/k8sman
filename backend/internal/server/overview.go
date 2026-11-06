package server

import (
	"context"
	"net/http"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/overview"
)

func (s *Server) overviewRoutes() {
	s.mux.HandleFunc("GET /api/overview", s.handleOverview)
}

// handleOverview lists every relevant type once, in parallel, and returns the
// health analysis. Lists that fail (e.g. RBAC forbids nodes) are reported in
// `errors` instead of failing the whole request, unless pods cannot be listed.
func (s *Server) handleOverview(w http.ResponseWriter, r *http.Request) {
	scope, err := kube.ParseNamespaces(r.URL.Query())
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	ns := scope.String() // "" = all, "a" or a set "a,b" (see listScope)
	c := s.mgr.Clients()
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	in, errs := s.listForOverview(ctx, c, ns)
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

// listForOverview lists the core types, then whatever the enabled modules
// add (Argo CD Applications, Gateway API objects, alerts, …).
func (s *Server) listForOverview(ctx context.Context, c *cluster.Clients, ns string) (overview.Input, map[string]error) {
	l := &OverviewLists{Ctx: ctx, Clients: c, Namespace: ns, in: overview.Input{Now: time.Now()}, errs: map[string]error{}}
	in := &l.in
	// Lists go through the shared watch cache: the first poll costs one
	// LIST per type, later polls (every 10s while the page is open) none.
	kc := kcache.For(c)

	// Each core list writes its own field of the input.
	run := func(name string, f func() error) {
		l.Go(name, func() (func(*overview.Input), error) { return nil, f() })
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
	for _, m := range s.enabledModules() {
		if src, ok := m.(OverviewSource); ok {
			src.OverviewInputs(l)
		}
	}
	l.wg.Wait()
	return l.in, l.errs
}
