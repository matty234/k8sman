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
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
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
	scope, err := kube.ParseNamespaces(r.URL.Query())
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	wait := overviewSoftWait
	if v := r.URL.Query().Get("wait"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d < 0 {
			writeErr(w, httpx.BadRequest("wait: want a duration such as 1s"))
			return
		}
		wait = min(d, overviewMaxWait)
	}
	ns := scope.String() // "" = all, "a" or a set "a,b" (see listScope)

	c := s.mgr.Clients()
	l := s.overviewRuns.get(fmt.Sprintf("%p|%s", c, ns), func() *OverviewLists { return s.startOverview(c, ns) })
	res, errs, ok := l.respond(r.Context(), wait)
	if !ok {
		return
	}
	if err, bad := errs["pods"]; bad {
		writeErr(w, err)
		return
	}
	res.Namespace = ns
	if len(errs) > 0 {
		res.Errors = map[string]string{}
		for k, e := range errs {
			res.Errors[k] = e.Error()
		}
	}
	httpx.WriteJSON(w, 200, res)
}

// respond waits for every source up to wait, then (always) for pods, and
// analyses what has completed. ok is false when reqCtx ended first.
func (l *OverviewLists) respond(reqCtx context.Context, wait time.Duration) (*overview.Result, map[string]error, bool) {
	all := make(chan struct{})
	go func() {
		l.wg.Wait()
		close(all)
	}()
	soft := time.NewTimer(wait)
	defer soft.Stop()
	select {
	case <-all:
	case <-soft.C:
	case <-reqCtx.Done():
		return nil, nil, false
	}
	select {
	case <-l.podsDone:
	case <-reqCtx.Done():
		return nil, nil, false
	}
	in, errs := l.snapshot()
	return overview.Analyze(in), errs, true
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

	listInto(l, kc, "pods", gvrPods, ns, "", func(in *overview.Input, v []corev1.Pod) { in.Pods = v })
	listInto(l, kc, "deployments", gvrDeployments, ns, "", func(in *overview.Input, v []appsv1.Deployment) { in.Deployments = v })
	listInto(l, kc, "statefulsets", gvrStatefulSets, ns, "", func(in *overview.Input, v []appsv1.StatefulSet) { in.StatefulSets = v })
	listInto(l, kc, "daemonsets", gvrDaemonSets, ns, "", func(in *overview.Input, v []appsv1.DaemonSet) { in.DaemonSets = v })
	listInto(l, kc, "replicasets", gvrReplicaSets, ns, "", func(in *overview.Input, v []appsv1.ReplicaSet) { in.ReplicaSets = v })
	listInto(l, kc, "jobs", gvrJobs, ns, "", func(in *overview.Input, v []batchv1.Job) { in.Jobs = v })
	listInto(l, kc, "cronjobs", gvrCronJobs, ns, "", func(in *overview.Input, v []batchv1.CronJob) { in.CronJobs = v })
	listInto(l, kc, "nodes", gvrNodes, "", "", func(in *overview.Input, v []corev1.Node) { in.Nodes = v })
	listInto(l, kc, "persistentvolumeclaims", gvrPVCs, ns, "", func(in *overview.Input, v []corev1.PersistentVolumeClaim) { in.PVCs = v })
	listInto(l, kc, "events", gvrEvents, ns, "type=Warning", func(in *overview.Input, v []corev1.Event) { in.Events = v })
	for _, m := range s.enabledModules() {
		if src, ok := m.(OverviewSource); ok {
			src.OverviewInputs(l)
		}
	}
	go func() {
		l.wg.Wait()
		l.mu.Lock()
		l.finished = time.Now()
		l.mu.Unlock()
		cancel()
	}()
	return l
}

// overviewReuse is how long a finished run still answers requests, so the
// follow-up fetch right after one doesn't start every source again. Short,
// so the normal 10s poll sees fresh data.
const overviewReuse = time.Second

// overviewRuns holds the overview run in flight (or just finished) per
// context and namespace scope; requests attach to it instead of starting
// the same slow sources again.
type overviewRuns struct {
	mu sync.Mutex
	m  map[string]*overviewRun
}

// overviewRun is one key's run; ready closes once start has returned, so
// start runs outside the map lock (a slow first start only holds up
// requests for the same key).
type overviewRun struct {
	ready chan struct{}
	l     *OverviewLists
}

// get returns the run for key, calling start (once per key, so only one
// request starts it) when there is none or the last one is over.
func (o *overviewRuns) get(key string, start func() *OverviewLists) *OverviewLists {
	o.mu.Lock()
	if o.m == nil {
		o.m = map[string]*overviewRun{}
	}
	for k, r := range o.m {
		select {
		case <-r.ready:
			if r.l.expired() {
				delete(o.m, k)
			}
		default: // still starting
		}
	}
	if r := o.m[key]; r != nil {
		o.mu.Unlock()
		<-r.ready
		return r.l
	}
	r := &overviewRun{ready: make(chan struct{})}
	o.m[key] = r
	o.mu.Unlock()
	r.l = start()
	close(r.ready)
	return r.l
}

// expired: finished more than overviewReuse ago, or past the hard limit
// (a source that ignores its context never finishes).
func (l *OverviewLists) expired() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.finished.IsZero() {
		return time.Since(l.finished) > overviewReuse
	}
	return time.Since(l.started) > overviewHardWait+time.Second
}

// listInto lists one core type and stores it with set, under the lock.
func listInto[T any](l *OverviewLists, kc *kcache.Cache, name string, gvr schema.GroupVersionResource, ns, fieldSelector string, set func(in *overview.Input, v []T)) {
	l.Go(name, func() (func(*overview.Input), error) {
		items, err := listTyped[T](l.Ctx, kc, gvr, ns, fieldSelector)
		if err != nil {
			return nil, err
		}
		return func(in *overview.Input) { set(in, items) }, nil
	})
}
