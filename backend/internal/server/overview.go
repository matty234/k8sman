package server

import (
	"context"
	"fmt"
	"net/http"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/overview"
)

func (s *Server) overviewRoutes() {
	s.mux.HandleFunc("GET /api/overview", s.handleOverview)
}

// Soft deadline of /api/overview: the response goes out with whatever has
// completed by then (pods excepted), the rest is reported in `pending`.
const (
	overviewSoftWait = 1200 * time.Millisecond
	overviewMaxWait  = 10 * time.Second
	overviewHardWait = 20 * time.Second
)

// handleOverview lists every relevant type once, in parallel, and returns the
// health analysis. Lists that fail (e.g. RBAC forbids nodes) are reported in
// `errors` instead of failing the whole request, unless pods cannot be listed.
//
// It answers after the soft deadline (`wait`, default 1.2s, at most 10s)
// with what has completed, listing the sources still running in `pending`;
// those keep running (detached from the request, under the 20s limit) so
// that they fill the watch cache for the next poll. Pods are the exception:
// nothing renders without them, so they are waited for up to the limit.
func (s *Server) handleOverview(w http.ResponseWriter, r *http.Request) {
	l, _, ns, ok := softRequest(s, w, r, overviewSoftWait, overviewMaxWait, &s.overviewRuns,
		func(c *cluster.Clients, ns string) string { return fmt.Sprintf("%p|%s", c, ns) },
		s.startOverview)
	if !ok {
		return
	}
	res, errs := l.analyze()
	if err, bad := errs["pods"]; bad {
		writeErr(w, err)
		return
	}
	res.Namespace = ns
	res.Errors = errStrings(errs)
	httpx.WriteJSON(w, 200, res)
}

// analyze analyses what has completed so far.
func (l *OverviewLists) analyze() (*overview.Result, map[string]error) {
	in, errs := l.snapshot()
	return overview.Analyze(in), errs
}

// respond waits for every source up to wait, then (always) for pods, and
// analyses what has completed. ok is false when reqCtx ended first.
func (l *OverviewLists) respond(reqCtx context.Context, wait time.Duration) (*overview.Result, map[string]error, bool) {
	if !l.await(reqCtx, wait) {
		return nil, nil, false
	}
	res, errs := l.analyze()
	return res, errs, true
}

// startOverview starts listing the core types, then whatever the enabled
// modules add (Argo CD Applications, Gateway API objects, alerts, …). The
// sources run under their own context (20s), not the request's, so they
// survive a request that answered early.
func (s *Server) startOverview(c *cluster.Clients, ns string) *OverviewLists {
	ctx, cancel := context.WithTimeout(context.Background(), overviewHardWait)
	l := newOverviewLists(ctx, c, ns)
	// Lists go through the shared watch cache: the first poll costs one
	// LIST per type, later polls (every 10s while the page is open) none.
	kc := kcache.For(c)

	listInto(l.sourceRun, kc, "pods", gvrPods, ns, "", func(in *overview.Input, v []corev1.Pod) { in.Pods = v })
	listInto(l.sourceRun, kc, "deployments", gvrDeployments, ns, "", func(in *overview.Input, v []appsv1.Deployment) { in.Deployments = v })
	listInto(l.sourceRun, kc, "statefulsets", gvrStatefulSets, ns, "", func(in *overview.Input, v []appsv1.StatefulSet) { in.StatefulSets = v })
	listInto(l.sourceRun, kc, "daemonsets", gvrDaemonSets, ns, "", func(in *overview.Input, v []appsv1.DaemonSet) { in.DaemonSets = v })
	listInto(l.sourceRun, kc, "replicasets", gvrReplicaSets, ns, "", func(in *overview.Input, v []appsv1.ReplicaSet) { in.ReplicaSets = v })
	listInto(l.sourceRun, kc, "jobs", gvrJobs, ns, "", func(in *overview.Input, v []batchv1.Job) { in.Jobs = v })
	listInto(l.sourceRun, kc, "cronjobs", gvrCronJobs, ns, "", func(in *overview.Input, v []batchv1.CronJob) { in.CronJobs = v })
	listInto(l.sourceRun, kc, "nodes", gvrNodes, "", "", func(in *overview.Input, v []corev1.Node) { in.Nodes = v })
	listInto(l.sourceRun, kc, "persistentvolumeclaims", gvrPVCs, ns, "", func(in *overview.Input, v []corev1.PersistentVolumeClaim) { in.PVCs = v })
	listInto(l.sourceRun, kc, "events", gvrEvents, ns, "type=Warning", func(in *overview.Input, v []corev1.Event) { in.Events = v })
	for _, m := range s.enabledModules() {
		if src, ok := m.(OverviewSource); ok {
			src.OverviewInputs(l)
		}
	}
	l.sealed(cancel)
	return l
}

// overviewReuse is how long a finished run still answers requests, so the
// follow-up fetch right after one doesn't start every source again. Short,
// so the normal 10s poll sees fresh data.
const overviewReuse = time.Second

// overviewRuns shares the overview run in flight (or just finished) per
// context and namespace scope.
type overviewRuns = runRegistry[*OverviewLists]
