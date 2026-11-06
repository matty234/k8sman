package server

import (
	"encoding/json"
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"

	"github.com/matty234/k8sman/backend/internal/argowf"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/overview"
)

// argoWFModule is the Argo Workflows integration: argo-server status
// (/api/argowf/status), the argowf-* actions and failed Workflows in the
// health overview.
type argoWFModule struct {
	// h reaches argo-server (retry, memoized resubmit).
	h *argowf.Handler
}

func (m *argoWFModule) Name() string { return "argoworkflows" }

func (m *argoWFModule) Routes(r httpx.Router, d Deps) {
	m.h = argowf.Register(r, d.Mgr)
}

// OverviewInputs lists Workflows, only when the CRD is served.
func (m *argoWFModule) OverviewInputs(l *OverviewLists) {
	rt, err := l.Clients.Find(l.Ctx, "argoproj.io", "", "workflows")
	if err != nil {
		return
	}
	l.Go("workflows.argoproj.io", func() (func(*overview.Input), error) {
		items, err := listCached(l.Ctx, kcache.For(l.Clients), rt.GVR(), l.Namespace)
		if err != nil {
			return nil, err
		}
		wfs := make([]map[string]any, len(items))
		for i, it := range items {
			wfs[i] = it.Object
		}
		return func(in *overview.Input) { in.Workflows = wfs }, nil
	})
}

// Argo Workflows actions (see internal/argowf for how each maps onto what
// the argo CLI / argo-server do). CronWorkflow suspend/resume reuse the
// generic suspend/unsuspend actions: they are the same spec.suspend patch.
//
//   - argowf-stop / argowf-terminate / argowf-suspend / argowf-resume
//   - argowf-resubmit (memoized: through argo-server)
//   - argowf-retry (through argo-server only)
//   - argowf-submit: a Workflow from a CronWorkflow or a
//     (Cluster)WorkflowTemplate, with parameters for templates
func (m *argoWFModule) ActionTargets() map[string][]string {
	return map[string][]string{
		"argowf-stop":      {"argoproj.io/workflows"},
		"argowf-terminate": {"argoproj.io/workflows"},
		"argowf-suspend":   {"argoproj.io/workflows"},
		"argowf-resume":    {"argoproj.io/workflows"},
		"argowf-resubmit":  {"argoproj.io/workflows"},
		"argowf-retry":     {"argoproj.io/workflows"},
		"argowf-submit":    {"argoproj.io/cronworkflows", "argoproj.io/workflowtemplates", "argoproj.io/clusterworkflowtemplates"},
		// Core actions, extended to CronWorkflows.
		"suspend":   {"argoproj.io/cronworkflows"},
		"unsuspend": {"argoproj.io/cronworkflows"},
	}
}

// argoWFActionRequest holds the Argo Workflows fields of an action body.
type argoWFActionRequest struct {
	// argowf-submit (templates): parameters and an optional entrypoint.
	Parameters []argowf.Param `json:"parameters,omitempty"`
	Entrypoint string         `json:"entrypoint,omitempty"`
	// argowf-submit (ClusterWorkflowTemplate): where to create the Workflow.
	TargetNamespace string `json:"targetNamespace,omitempty"`
	// argowf-resubmit: reuse the outputs of nodes that succeeded.
	Memoized bool `json:"memoized,omitempty"`
	// argowf-retry: also re-run nodes that succeeded.
	RestartSuccessful bool `json:"restartSuccessful,omitempty"`
}

// RunAction performs one argowf-* action.
func (m *argoWFModule) RunAction(a ActionCall) (ActionResult, error) {
	ctx, c, ri, action, name, dry := a.Ctx, a.Clients, a.Resource, a.Action, a.Name, a.DryRunOpt
	res := ActionResult{DryRun: a.DryRun, Context: c.Context}
	var req argoWFActionRequest
	if err := decodeActionBody(a.Body, &req); err != nil {
		return res, err
	}
	obj, err := ri.Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return res, err
	}
	patch := func(p map[string]any) error {
		b, _ := json.Marshal(p)
		_, err := ri.Patch(ctx, name, types.MergePatchType, b, metav1.PatchOptions{FieldManager: fieldManager, DryRun: dry})
		return err
	}
	create := func(ns string, wf map[string]any) (string, error) {
		wt, err := c.Find(ctx, argowf.Group, "", "workflows")
		if err != nil {
			return "", err
		}
		out, err := c.Dynamic.Resource(wt.GVR()).Namespace(ns).Create(ctx, &unstructured.Unstructured{Object: wf},
			metav1.CreateOptions{FieldManager: fieldManager, DryRun: dry})
		if err != nil {
			return "", err
		}
		res.Created = &ObjectRefJSON{Group: argowf.Group, Kind: "Workflow", Name: out.GetName(), Namespace: ns}
		return out.GetName(), nil
	}
	ns := a.Namespace

	switch action {
	case "argowf-stop", "argowf-terminate":
		strategy := map[string]string{"argowf-stop": "Stop", "argowf-terminate": "Terminate"}[action]
		p, err := argowf.ShutdownPatch(obj.Object, strategy)
		if err != nil {
			return res, httpx.BadRequest("%v", err)
		}
		res.Message = map[string]string{"Stop": "Stopping ", "Terminate": "Terminating "}[strategy] + name
		return res, patch(p)
	case "argowf-suspend":
		p, err := argowf.SuspendPatch(obj.Object)
		if err != nil {
			return res, httpx.BadRequest("%v", err)
		}
		res.Message = "Suspended " + name
		return res, patch(p)
	case "argowf-resume":
		p, err := argowf.ResumePatch(obj.Object, time.Now())
		if err != nil {
			return res, httpx.BadRequest("%v", err)
		}
		if p == nil {
			return res, httpx.BadRequest("%s is not suspended", name)
		}
		res.Message = "Resumed " + name
		return res, patch(p)
	case "argowf-resubmit":
		if req.Memoized {
			if a.DryRun {
				return res, httpx.BadRequest("dry run is not supported for a memoized resubmit")
			}
			created, err := m.h.ResubmitMemoized(ctx, c, ns, name)
			if err != nil {
				return res, err
			}
			res.Message = "Resubmitted " + name + " (memoized) as " + created
			if created != "" {
				res.Created = &ObjectRefJSON{Group: argowf.Group, Kind: "Workflow", Name: created, Namespace: ns}
			}
			return res, nil
		}
		created, err := create(ns, argowf.Resubmit(obj.Object))
		res.Message = "Resubmitted " + name + " as " + created
		return res, err
	case "argowf-retry":
		if a.DryRun {
			return res, httpx.BadRequest("dry run is not supported for retry")
		}
		if phase, _, _ := unstructured.NestedString(obj.Object, "status", "phase"); phase != "Failed" && phase != "Error" {
			return res, httpx.BadRequest("only Failed or Error workflows can be retried (this one is %s)", phase)
		}
		if err := m.h.Retry(ctx, c, ns, name, req.RestartSuccessful); err != nil {
			return res, err
		}
		res.Message = "Retrying " + name
		return res, nil
	case "argowf-submit":
		var wf map[string]any
		target := ns
		switch a.Type.Resource {
		case "cronworkflows":
			wf = argowf.FromCronWorkflow(obj.Object, time.Now())
		case "workflowtemplates", "clusterworkflowtemplates":
			cluster := a.Type.Resource == "clusterworkflowtemplates"
			if cluster {
				target = req.TargetNamespace
				if target == "" {
					return res, httpx.BadRequest("targetNamespace is required for a ClusterWorkflowTemplate")
				}
			}
			if err := argowf.ValidateParams(obj.Object, req.Parameters); err != nil {
				return res, httpx.BadRequest("%v", err)
			}
			wf = argowf.FromTemplate(obj.Object, cluster, target, req.Parameters, req.Entrypoint)
		default:
			return res, httpx.BadRequest("cannot submit from %s", a.Type.Resource)
		}
		created, err := create(target, wf)
		res.Message = fmt.Sprintf("Submitted %s from %s %s", created, a.Type.Kind, name)
		return res, err
	}
	return res, httpx.BadRequest("unknown action %q", action)
}
