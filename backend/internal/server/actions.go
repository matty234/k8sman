package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
)

// ActionRequest is the body of POST /api/actions/{action}. Target comes from
// the usual group/version/resource/namespace/name query params.
type ActionRequest struct {
	// scale
	Replicas *int64 `json:"replicas,omitempty"`
	// rollback: target revision (0 = previous)
	Revision int64 `json:"revision,omitempty"`
	// delete
	GracePeriodSeconds *int64 `json:"gracePeriodSeconds,omitempty"`
	Propagation        string `json:"propagation,omitempty"` // Background|Foreground|Orphan
	// Run admission/validation without persisting.
	DryRun bool `json:"dryRun,omitempty"`
	// Module actions decode their own fields from the same body (see
	// ActionCall.Body).
}

// ActionResult is returned by every action.
type ActionResult struct {
	Message string `json:"message"`
	DryRun  bool   `json:"dryRun"`
	Context string `json:"context"`
	// Created names any object the action created (e.g. a Job from trigger).
	Created *ObjectRefJSON `json:"created,omitempty"`
	// Preview is a dry run's change (plugin patch actions).
	Preview *ActionPreview `json:"preview,omitempty"`
}

// ObjectRefJSON identifies an object created by an action.
type ObjectRefJSON struct {
	Group     string `json:"group"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace,omitempty"`
}

// Which core actions apply to which group/resource. "*" = any type that
// supports the delete verb. Exposed at GET /api/actions so the UI can render
// buttons. Modules add their own (see ActionSource).
var actionTargets = map[string][]string{
	"scale":     {"apps/deployments", "apps/statefulsets", "apps/replicasets", "*scale"},
	"restart":   {"apps/deployments", "apps/statefulsets", "apps/daemonsets"},
	"pause":     {"apps/deployments"},
	"resume":    {"apps/deployments"},
	"rollback":  {"apps/deployments"},
	"suspend":   {"batch/cronjobs", "batch/jobs"},
	"unsuspend": {"batch/cronjobs", "batch/jobs"},
	"trigger":   {"batch/cronjobs"},
	"cordon":    {"/nodes"},
	"uncordon":  {"/nodes"},
	"delete":    {"*"},
	// Clears metadata.finalizers of an object that is already terminating.
	"finalize": {"*patch"},
}

func (s *Server) actionRoutes() {
	s.mux.HandleFunc("GET /api/actions", s.handleListActions)
	s.mux.HandleFunc("POST /api/actions/{action}", s.handleAction)
}

// handleListActions returns the actions available for a resource type.
func (s *Server) handleListActions(w http.ResponseWriter, r *http.Request) {
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"actions": s.availableActions(c, rq.Type), "readOnly": s.isReadOnly()})
}

// allActionTargets is actionTargets plus the enabled modules' actions, and
// which module runs each module action.
func (s *Server) allActionTargets() (map[string][]string, map[string]ActionSource) {
	targets := make(map[string][]string, len(actionTargets))
	for a, t := range actionTargets {
		targets[a] = t
	}
	owners := map[string]ActionSource{}
	for _, m := range s.enabledModules() {
		src, ok := m.(ActionSource)
		if !ok {
			continue
		}
		for a, t := range src.ActionTargets() {
			if _, core := actionTargets[a]; !core {
				owners[a] = src
			}
			targets[a] = append(slices.Clone(targets[a]), t...)
		}
	}
	return targets, owners
}

func (s *Server) availableActions(c *cluster.Clients, rt cluster.ResourceType) []string {
	gr := rt.Group + "/" + rt.Resource
	var out []string
	all, _ := s.allActionTargets()
	for action, targets := range all {
		for _, t := range targets {
			ok := t == gr ||
				(t == "*" && slices.Contains(rt.Verbs, "delete")) ||
				(t == "*patch" && slices.Contains(rt.Verbs, "patch")) ||
				(t == "*scale" && rt.Custom && hasScaleSubresource(c, rt)) ||
				t == "kind:"+rt.Group+"/"+rt.Kind
			if ok {
				out = append(out, action)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}

func hasScaleSubresource(c *cluster.Clients, rt cluster.ResourceType) bool {
	l, err := c.Discovery.ServerResourcesForGroupVersion(rt.GVR().GroupVersion().String())
	if err != nil {
		return false
	}
	for _, r := range l.APIResources {
		if r.Name == rt.Resource+"/scale" {
			return true
		}
	}
	return false
}

func (s *Server) handleAction(w http.ResponseWriter, r *http.Request) {
	if s.refuseReadOnly(w) {
		return
	}
	action := r.PathValue("action")
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	name := r.URL.Query().Get("name")
	if name == "" {
		writeErr(w, httpx.BadRequest("name is required"))
		return
	}
	var req ActionRequest
	var body []byte
	if r.ContentLength != 0 {
		if body, err = io.ReadAll(r.Body); err == nil {
			err = json.NewDecoder(bytes.NewReader(body)).Decode(&req)
		}
		if err != nil {
			writeErr(w, httpx.BadRequest("invalid body: %v", err))
			return
		}
	}
	allowed := false
	for _, a := range s.availableActions(c, rq.Type) {
		allowed = allowed || a == action
	}
	if !allowed {
		writeErr(w, httpx.BadRequest("action %q is not supported for %s", action, rq.Type.Resource))
		return
	}

	ctx := r.Context()
	ri := rq.client(c)
	var dry []string
	if req.DryRun {
		dry = []string{metav1.DryRunAll}
	}
	patchOpts := metav1.PatchOptions{FieldManager: fieldManager, DryRun: dry}
	merge := func(patch map[string]any, sub ...string) error {
		b, _ := json.Marshal(patch)
		_, err := ri.Patch(ctx, name, types.MergePatchType, b, patchOpts, sub...)
		return err
	}
	res := ActionResult{DryRun: req.DryRun, Context: c.Context}

	switch action {
	case "scale":
		if req.Replicas == nil || *req.Replicas < 0 {
			writeErr(w, httpx.BadRequest("replicas (>= 0) is required"))
			return
		}
		err = merge(map[string]any{"spec": map[string]any{"replicas": *req.Replicas}}, "scale")
		res.Message = fmt.Sprintf("Scaled %s to %d", name, *req.Replicas)
	case "restart":
		// Same mechanism as `kubectl rollout restart`.
		err = merge(map[string]any{"spec": map[string]any{"template": map[string]any{"metadata": map[string]any{
			"annotations": map[string]any{"kubectl.kubernetes.io/restartedAt": time.Now().Format(time.RFC3339)},
		}}}})
		res.Message = "Rollout restart triggered for " + name
	case "pause", "resume":
		err = merge(map[string]any{"spec": map[string]any{"paused": action == "pause"}})
		res.Message = fmt.Sprintf("Rollout %sd for %s", action, name)
	case "suspend", "unsuspend":
		err = merge(map[string]any{"spec": map[string]any{"suspend": action == "suspend"}})
		res.Message = fmt.Sprintf("%s %s", map[bool]string{true: "Suspended", false: "Resumed"}[action == "suspend"], name)
	case "cordon", "uncordon":
		err = merge(map[string]any{"spec": map[string]any{"unschedulable": action == "cordon"}})
		res.Message = fmt.Sprintf("Node %s %sed", name, action)
	case "trigger":
		var created string
		created, err = triggerCronJob(ctx, c, rq.Namespace, name, dry)
		res.Message = "Created Job " + created
		res.Created = &ObjectRefJSON{Group: "batch", Kind: "Job", Name: created, Namespace: rq.Namespace}
	case "rollback":
		var rev int64
		rev, err = rollbackDeployment(ctx, c, rq.Namespace, name, req.Revision, dry)
		res.Message = fmt.Sprintf("Rolled %s back to revision %d", name, rev)
	case "finalize":
		// Only for objects already being deleted: removing finalizers from a
		// live object would skip cleanup it never asked to skip.
		var obj *unstructured.Unstructured
		if obj, err = ri.Get(ctx, name, metav1.GetOptions{}); err == nil {
			if obj.GetDeletionTimestamp() == nil {
				writeErr(w, httpx.BadRequest("%s is not being deleted; delete it first", name))
				return
			}
			err = merge(map[string]any{"metadata": map[string]any{"finalizers": nil}})
		}
		res.Message = "Removed finalizers from " + name
	case "delete":
		opts := metav1.DeleteOptions{DryRun: dry, GracePeriodSeconds: req.GracePeriodSeconds}
		if req.Propagation != "" {
			p := metav1.DeletionPropagation(req.Propagation)
			opts.PropagationPolicy = &p
		}
		err = ri.Delete(ctx, name, opts)
		res.Message = "Deleted " + name
	default:
		// A module's action (allowed above, so its module is enabled).
		if _, owners := s.allActionTargets(); owners[action] != nil {
			res, err = owners[action].RunAction(ActionCall{
				Ctx: ctx, Clients: c, Action: action,
				Type: rq.Type, Namespace: rq.Namespace, Name: name, Resource: ri,
				DryRun: req.DryRun, DryRunOpt: dry, Body: body,
			})
		}
	}
	if err != nil {
		writeErr(w, err)
		return
	}
	if req.DryRun {
		res.Message = "Dry run OK: " + res.Message
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

// decodeActionBody decodes a module's fields from an action body (an empty
// body leaves v as is).
func decodeActionBody(b []byte, v any) error {
	if len(b) == 0 {
		return nil
	}
	if err := json.NewDecoder(bytes.NewReader(b)).Decode(v); err != nil {
		return httpx.BadRequest("invalid body: %v", err)
	}
	return nil
}

// triggerCronJob creates a Job from the CronJob's template (`kubectl create
// job --from=cronjob/x`).
func triggerCronJob(ctx context.Context, c *cluster.Clients, ns, name string, dry []string) (string, error) {
	cj, err := c.Typed.BatchV1().CronJobs(ns).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return "", err
	}
	suffix := strconv.FormatInt(time.Now().Unix()%1_000_000, 10)
	jobName := name + "-manual-" + suffix
	if len(jobName) > 63 {
		jobName = jobName[:63]
	}
	tmpl := cj.Spec.JobTemplate
	job := map[string]any{
		"apiVersion": "batch/v1",
		"kind":       "Job",
		"metadata": map[string]any{
			"name":        jobName,
			"namespace":   ns,
			"labels":      tmpl.Labels,
			"annotations": mergeMaps(tmpl.Annotations, map[string]string{"cronjob.kubernetes.io/instantiate": "manual"}),
			"ownerReferences": []any{map[string]any{
				"apiVersion": "batch/v1", "kind": "CronJob", "name": cj.Name, "uid": string(cj.UID), "controller": true,
			}},
		},
	}
	specJSON, _ := json.Marshal(tmpl.Spec)
	var spec map[string]any
	_ = json.Unmarshal(specJSON, &spec)
	job["spec"] = spec
	jobs := c.Dynamic.Resource(gvrJobs).Namespace(ns)
	_, err = jobs.Create(ctx, &unstructured.Unstructured{Object: job}, metav1.CreateOptions{FieldManager: fieldManager, DryRun: dry})
	return jobName, err
}

func mergeMaps(a, b map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

// rollbackDeployment mirrors `kubectl rollout undo [--to-revision]`: copy the
// target ReplicaSet's pod template back into the Deployment.
func rollbackDeployment(ctx context.Context, c *cluster.Clients, ns, name string, toRevision int64, dry []string) (int64, error) {
	d, err := c.Typed.AppsV1().Deployments(ns).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return 0, err
	}
	sel, err := metav1.LabelSelectorAsSelector(d.Spec.Selector)
	if err != nil {
		return 0, err
	}
	rss, err := c.Typed.AppsV1().ReplicaSets(ns).List(ctx, metav1.ListOptions{LabelSelector: sel.String()})
	if err != nil {
		return 0, err
	}
	current, _ := strconv.ParseInt(d.Annotations["deployment.kubernetes.io/revision"], 10, 64)
	type cand struct {
		rev int64
		idx int
	}
	var cands []cand
	for i, rs := range rss.Items {
		owned := false
		for _, o := range rs.OwnerReferences {
			owned = owned || o.UID == d.UID
		}
		rev, err := strconv.ParseInt(rs.Annotations["deployment.kubernetes.io/revision"], 10, 64)
		if owned && err == nil {
			cands = append(cands, cand{rev, i})
		}
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].rev > cands[j].rev })
	var target *cand
	for i := range cands {
		if (toRevision == 0 && cands[i].rev < current) || (toRevision != 0 && cands[i].rev == toRevision) {
			target = &cands[i]
			break
		}
	}
	if target == nil {
		if toRevision == 0 {
			return 0, httpx.BadRequest("no previous revision to roll back to")
		}
		return 0, httpx.BadRequest("revision %d not found", toRevision)
	}
	if target.rev == current {
		return 0, httpx.BadRequest("revision %d is already current", current)
	}
	tmpl := rss.Items[target.idx].Spec.Template.DeepCopy()
	delete(tmpl.Labels, "pod-template-hash")
	// JSON-patch replace (not merge) so fields added since that revision —
	// e.g. a restartedAt annotation or a new env var — are removed too.
	patch, _ := json.Marshal([]map[string]any{{"op": "replace", "path": "/spec/template", "value": tmpl}})
	_, err = c.Typed.AppsV1().Deployments(ns).Patch(ctx, name, types.JSONPatchType, patch,
		metav1.PatchOptions{FieldManager: fieldManager, DryRun: dry})
	return target.rev, err
}
