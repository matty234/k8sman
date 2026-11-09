package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/kubectl/pkg/drain"

	"github.com/matty234/k8sman/backend/internal/httpx"
)

// Node drain, with kubectl's own drain package (`kubectl drain`): DaemonSet
// pods are left alone, mirror (static) pods are skipped, and pods are evicted
// through the Eviction API, so PodDisruptionBudgets are honoured (blocked
// evictions retry until the timeout).
//
//   GET  /api/nodes/drain-plan?name=&deleteEmptyDirData=&force=
//   POST /api/nodes/drain?name=   {deleteEmptyDirData, force, gracePeriodSeconds, timeoutSeconds}

func (s *Server) drainRoutes() {
	s.mux.HandleFunc("GET /api/nodes/drain-plan", s.handleDrainPlan)
	s.mux.HandleFunc("POST /api/nodes/drain", s.handleDrain)
}

// DrainOptions are the choices `kubectl drain` offers that matter here.
type DrainOptions struct {
	// Evict pods using emptyDir volumes (their data is lost).
	DeleteEmptyDirData bool `json:"deleteEmptyDirData"`
	// Delete pods without a controller (they won't come back).
	Force bool `json:"force"`
	// -1 = each pod's own grace period.
	GracePeriodSeconds *int `json:"gracePeriodSeconds,omitempty"`
	// How long to keep evicting (and waiting) before giving up. 0 = 300.
	TimeoutSeconds int `json:"timeoutSeconds,omitempty"`
}

// DrainPlan is what a drain would do with the given options.
type DrainPlan struct {
	Node string `json:"node"`
	// Pods that will be evicted, as namespace/name.
	Evict []string `json:"evict"`
	// Things drain skips or accepts with a caveat (DaemonSet pods, emptyDir
	// data, unmanaged pods), as kubectl prints them.
	Warnings []string `json:"warnings"`
	// Reasons the drain would refuse to start (e.g. unmanaged pods without
	// force, emptyDir without deleteEmptyDirData), with the pods.
	Blockers []string `json:"blockers"`
}

// DrainResult reports a drain.
type DrainResult struct {
	Node    string   `json:"node"`
	Evicted []string `json:"evicted"`
	// Set when the drain stopped short (timeout, PDB, refusal). The node
	// stays cordoned, like kubectl.
	Error   string `json:"error,omitempty"`
	Context string `json:"context"`
}

func drainOptionsFromQuery(r *http.Request) DrainOptions {
	q := r.URL.Query()
	b := func(k string) bool { v, _ := strconv.ParseBool(q.Get(k)); return v }
	return DrainOptions{DeleteEmptyDirData: b("deleteEmptyDirData"), Force: b("force")}
}

func (s *Server) drainHelper(ctx context.Context, opts DrainOptions, out *bytes.Buffer) (*drain.Helper, error) {
	c := s.mgr.Clients()
	if c == nil {
		return nil, s.mgr.Err()
	}
	grace := -1
	if opts.GracePeriodSeconds != nil {
		grace = *opts.GracePeriodSeconds
	}
	timeout := time.Duration(opts.TimeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = 5 * time.Minute
	}
	return &drain.Helper{
		Ctx:                 ctx,
		Client:              c.Typed,
		Force:               opts.Force,
		GracePeriodSeconds:  grace,
		IgnoreAllDaemonSets: true,
		DeleteEmptyDirData:  opts.DeleteEmptyDirData,
		Timeout:             timeout,
		Out:                 out,
		ErrOut:              out,
	}, nil
}

func podNames(pods []corev1.Pod) []string {
	out := make([]string, 0, len(pods))
	for _, p := range pods {
		out = append(out, p.Namespace+"/"+p.Name)
	}
	sort.Strings(out)
	return out
}

func (s *Server) drainPlan(ctx context.Context, node string, opts DrainOptions) (DrainPlan, error) {
	var out bytes.Buffer
	h, err := s.drainHelper(ctx, opts, &out)
	if err != nil {
		return DrainPlan{}, err
	}
	plan := DrainPlan{Node: node, Evict: []string{}, Warnings: []string{}, Blockers: []string{}}
	list, errs := h.GetPodsForDeletion(node)
	if list == nil && len(errs) > 0 {
		return plan, errors.Join(errs...) // the pod list itself failed
	}
	plan.Evict = podNames(list.Pods())
	if w := list.Warnings(); w != "" {
		plan.Warnings = strings.Split(w, "; ")
		sort.Strings(plan.Warnings)
	}
	for _, e := range errs {
		plan.Blockers = append(plan.Blockers, e.Error())
	}
	sort.Strings(plan.Blockers)
	return plan, nil
}

func (s *Server) handleDrainPlan(w http.ResponseWriter, r *http.Request) {
	node := r.URL.Query().Get("name")
	if node == "" {
		writeErr(w, httpx.BadRequest("name is required"))
		return
	}
	plan, err := s.drainPlan(r.Context(), node, drainOptionsFromQuery(r))
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, plan)
}

func (s *Server) handleDrain(w http.ResponseWriter, r *http.Request) {
	if s.isReadOnly() {
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorBody{Error: s.readOnlyMessage(), Code: http.StatusForbidden})
		return
	}
	node := r.URL.Query().Get("name")
	if node == "" {
		writeErr(w, httpx.BadRequest("name is required"))
		return
	}
	var opts DrainOptions
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&opts); err != nil {
			writeErr(w, httpx.BadRequest("invalid body: %v", err))
			return
		}
	}
	c := s.mgr.Clients()
	if c == nil {
		writeErr(w, s.mgr.Err())
		return
	}
	ctx := r.Context()
	var out bytes.Buffer
	h, err := s.drainHelper(ctx, opts, &out)
	if err != nil {
		writeErr(w, err)
		return
	}
	var mu sync.Mutex
	res := DrainResult{Node: node, Evicted: []string{}, Context: c.Context}
	h.OnPodDeletionOrEvictionFinished = func(p *corev1.Pod, _ bool, err error) {
		if err == nil {
			mu.Lock()
			res.Evicted = append(res.Evicted, p.Namespace+"/"+p.Name)
			mu.Unlock()
		}
	}

	n, err := c.Typed.CoreV1().Nodes().Get(ctx, node, metav1.GetOptions{})
	if err != nil {
		writeErr(w, err)
		return
	}
	// Cordon first, so nothing new lands while pods are evicted.
	if err := drain.RunCordonOrUncordon(h, n, true); err != nil {
		writeErr(w, fmt.Errorf("cordon %s: %w", node, err))
		return
	}
	if err := drain.RunNodeDrain(h, node); err != nil {
		res.Error = err.Error()
	}
	sort.Strings(res.Evicted)
	httpx.WriteJSON(w, http.StatusOK, res)
}
