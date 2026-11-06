package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"

	"github.com/matty234/k8sman/backend/internal/argoapi"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/overview"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
)

// argoCDModule is the Argo CD integration: the Argo CD API endpoints
// (/api/argocd/*: auth and per-resource diffs), the argocd-* actions and
// Application health in the overview.
type argoCDModule struct{}

func (m *argoCDModule) Name() string { return "argocd" }

func (m *argoCDModule) Routes(r httpx.Router, d Deps) {
	argoapi.Register(r, d.Mgr, d.Settings)
}

// OverviewInputs lists Applications, only when the CRD is served. They are
// listed across all namespaces (apps live in the Argo CD namespace) and
// filtered to those in, or deploying to, the selected namespace.
func (m *argoCDModule) OverviewInputs(l *OverviewLists) {
	rt, err := l.Clients.Find(l.Ctx, "argoproj.io", "", "applications")
	if err != nil {
		return
	}
	scope := kube.SplitNamespaces(l.Namespace)
	l.Go("applications.argoproj.io", func() (func(*overview.Input), error) {
		items, err := listCached(l.Ctx, kcache.For(l.Clients), rt.GVR(), "")
		if err != nil {
			return nil, err
		}
		apps := []map[string]any{}
		for _, it := range items {
			dest, _, _ := unstructured.NestedString(it.Object, "spec", "destination", "namespace")
			if scope.All() || slices.Contains(scope, it.GetNamespace()) || slices.Contains(scope, dest) {
				apps = append(apps, it.Object)
			}
		}
		return func(in *overview.Input) { in.ArgoApps = apps }, nil
	})
}

func (m *argoCDModule) ActionTargets() map[string][]string {
	return map[string][]string{
		"argocd-refresh":   {"argoproj.io/applications"},
		"argocd-sync":      {"argoproj.io/applications"},
		"argocd-terminate": {"argoproj.io/applications"},
	}
}

func (m *argoCDModule) RunAction(a ActionCall) (ActionResult, error) {
	res := ActionResult{DryRun: a.DryRun, Context: a.Clients.Context}
	var req argoActionRequest
	if err := decodeActionBody(a.Body, &req); err != nil {
		return res, err
	}
	opts := metav1.PatchOptions{FieldManager: fieldManager, DryRun: a.DryRunOpt}
	var err error
	res.Message, err = runArgoAction(a.Ctx, a.Resource, a.Action, a.Name, req, opts)
	return res, err
}

// Argo CD actions work directly on the Application CR, the same way the Argo
// CD API server does (it writes to the CR and the application controller does
// the rest), so they need no Argo CD API server, token or SSO: only kube RBAC
// to patch applications.argoproj.io.
//
//   - argocd-refresh: annotate argocd.argoproj.io/refresh=normal|hard. The
//     controller compares against git again (hard also drops the repo-server
//     manifest cache) and removes the annotation.
//   - argocd-sync: set .operation.sync, as util/argo.SetAppOperation does.
//   - argocd-terminate: set status.operationState.phase=Terminating, exactly
//     what the API server's TerminateOperation does (Applications have no
//     status subresource, so it is an ordinary update of the object).

const (
	argoRefreshAnnotation = "argocd.argoproj.io/refresh"
	argoInitiator         = "k8sman"
)

var argoAppsGR = schema.GroupResource{Group: "argoproj.io", Resource: "applications"}

// argoActionRequest holds the Argo CD fields of an action body.
type argoActionRequest struct {
	// argocd-refresh: hard refresh (also invalidates the manifest cache).
	Hard bool `json:"hard,omitempty"`
	// argocd-sync options. SyncDryRun is Argo's dry run (the controller runs
	// the sync with kubectl --dry-run); ActionRequest.DryRun is a kube API
	// dry run of the patch itself.
	Prune          bool     `json:"prune,omitempty"`
	SyncDryRun     bool     `json:"syncDryRun,omitempty"`
	TargetRevision string   `json:"targetRevision,omitempty"`
	SyncOptions    []string `json:"syncOptions,omitempty"`
	// Force starts a sync even though an operation is pending or running
	// (replacing it). Not Argo's "force" apply option.
	Force bool `json:"force,omitempty"`
}

// argoRefreshPatch is the merge patch for argocd-refresh.
func argoRefreshPatch(hard bool) map[string]any {
	mode := "normal"
	if hard {
		mode = "hard"
	}
	return map[string]any{"metadata": map[string]any{"annotations": map[string]any{argoRefreshAnnotation: mode}}}
}

// argoOperationInProgress reports whether app has a pending or running
// operation, and a description of it.
func argoOperationInProgress(app map[string]any) (bool, string) {
	phase, _, _ := unstructured.NestedString(app, "status", "operationState", "phase")
	if phase == "Running" || phase == "Terminating" {
		return true, "an operation is " + phase
	}
	if op, ok := app["operation"]; ok && op != nil {
		return true, "an operation is pending"
	}
	return false, ""
}

// argoSyncPatch builds the merge patch that requests a sync, mirroring the
// Argo CD API server's Sync handler (without revision resolution, which the
// controller does itself). The resourceVersion makes it a compare-and-swap.
func argoSyncPatch(app map[string]any, req argoActionRequest) (map[string]any, error) {
	if busy, why := argoOperationInProgress(app); busy && !req.Force {
		return nil, fmt.Errorf("%w: %s (pass force to replace it)", errArgoBusy, why)
	}
	if ts, ok, _ := unstructured.NestedString(app, "metadata", "deletionTimestamp"); ok && ts != "" {
		return nil, httpx.BadRequest("application is being deleted")
	}
	spec, _, _ := unstructured.NestedMap(app, "spec")
	automated := false
	if a, ok, _ := unstructured.NestedFieldNoCopy(spec, "syncPolicy", "automated"); ok && a != nil {
		automated = true
		if enabled, ok, _ := unstructured.NestedBool(spec, "syncPolicy", "automated", "enabled"); ok && !enabled {
			automated = false
		}
	}
	sources, multi, _ := unstructured.NestedSlice(spec, "sources")
	multi = multi && len(sources) > 0

	sync := map[string]any{"prune": req.Prune}
	if req.SyncDryRun {
		sync["dryRun"] = true
	}
	if multi {
		if req.TargetRevision != "" {
			return nil, httpx.BadRequest("targetRevision is not supported for multi-source applications")
		}
		sync["sources"] = sources
	} else {
		source, _, _ := unstructured.NestedMap(spec, "source")
		target, _, _ := unstructured.NestedString(source, "targetRevision")
		if target == "" {
			target = "HEAD"
		}
		rev := target
		if req.TargetRevision != "" && req.TargetRevision != target {
			if automated && !req.SyncDryRun {
				return nil, httpx.BadRequest("cannot sync to %s: auto-sync is set to %s", req.TargetRevision, target)
			}
			rev = req.TargetRevision
		}
		sync["revision"] = rev
		if source != nil {
			sync["source"] = source
		}
	}
	syncOptions := req.SyncOptions
	if syncOptions == nil {
		if opts, ok, _ := unstructured.NestedStringSlice(spec, "syncPolicy", "syncOptions"); ok {
			syncOptions = opts
		}
	}
	if len(syncOptions) > 0 {
		sync["syncOptions"] = toAnySlice(syncOptions)
	}

	op := map[string]any{
		"initiatedBy": map[string]any{"username": argoInitiator},
		"sync":        sync,
	}
	if retry, ok, _ := unstructured.NestedMap(spec, "syncPolicy", "retry"); ok && retry != nil {
		op["retry"] = retry
	}
	rv, _, _ := unstructured.NestedString(app, "metadata", "resourceVersion")
	return map[string]any{
		"metadata":  map[string]any{"resourceVersion": rv},
		"operation": op,
		// SetAppOperation clears the previous operation state.
		"status": map[string]any{"operationState": nil},
	}, nil
}

// argoTerminatePatch marks the running operation as Terminating.
func argoTerminatePatch(app map[string]any) (map[string]any, error) {
	phase, _, _ := unstructured.NestedString(app, "status", "operationState", "phase")
	if app["operation"] == nil || phase == "" {
		return nil, httpx.BadRequest("no operation is in progress")
	}
	if phase != "Running" {
		return nil, httpx.BadRequest("the operation is %s, not Running", phase)
	}
	rv, _, _ := unstructured.NestedString(app, "metadata", "resourceVersion")
	return map[string]any{
		"metadata": map[string]any{"resourceVersion": rv},
		"status":   map[string]any{"operationState": map[string]any{"phase": "Terminating"}},
	}, nil
}

var errArgoBusy = errors.New("operation in progress")

func toAnySlice(s []string) []any {
	out := make([]any, len(s))
	for i, v := range s {
		out[i] = v
	}
	return out
}

// runArgoAction performs one argocd-* action and returns its message.
func runArgoAction(ctx context.Context, ri dynamic.ResourceInterface, action, name string, req argoActionRequest, opts metav1.PatchOptions) (string, error) {
	patch := func(p map[string]any) error {
		b, _ := json.Marshal(p)
		_, err := ri.Patch(ctx, name, types.MergePatchType, b, opts)
		return err
	}
	switch action {
	case "argocd-refresh":
		mode := map[bool]string{true: "Hard refresh", false: "Refresh"}[req.Hard]
		return fmt.Sprintf("%s requested for %s", mode, name), patch(argoRefreshPatch(req.Hard))
	}

	app, err := ri.Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return "", err
	}
	var p map[string]any
	var msg string
	switch action {
	case "argocd-sync":
		p, err = argoSyncPatch(app.Object, req)
		if errors.Is(err, errArgoBusy) {
			return "", apierrors.NewConflict(argoAppsGR, name, err)
		}
		msg = "Sync requested for " + name
		if req.SyncDryRun {
			msg = "Dry-run sync requested for " + name
		}
	case "argocd-terminate":
		p, err = argoTerminatePatch(app.Object)
		msg = "Terminating the running operation of " + name
	default:
		return "", httpx.BadRequest("unknown action %q", action)
	}
	if err != nil {
		return "", err
	}
	return msg, patch(p)
}
