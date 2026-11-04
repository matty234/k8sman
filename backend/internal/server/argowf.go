package server

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"

	"github.com/matty234/k8sman/backend/internal/argowf"
	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
)

// Argo Workflows actions (see internal/argowf for how each maps onto what
// the argo CLI / argo-server do). CronWorkflow suspend/resume reuse the
// generic suspend/unsuspend actions: they are the same spec.suspend patch.
//
//   - argowf-stop / argowf-terminate / argowf-suspend / argowf-resume
//   - argowf-resubmit (memoized: through argo-server)
//   - argowf-retry (through argo-server only)
//   - argowf-submit: a Workflow from a CronWorkflow or a
//     (Cluster)WorkflowTemplate, with parameters for templates
var argoWFActionTargets = map[string][]string{
	"argowf-stop":      {"argoproj.io/workflows"},
	"argowf-terminate": {"argoproj.io/workflows"},
	"argowf-suspend":   {"argoproj.io/workflows"},
	"argowf-resume":    {"argoproj.io/workflows"},
	"argowf-resubmit":  {"argoproj.io/workflows"},
	"argowf-retry":     {"argoproj.io/workflows"},
	"argowf-submit":    {"argoproj.io/cronworkflows", "argoproj.io/workflowtemplates", "argoproj.io/clusterworkflowtemplates"},
}

func init() {
	for a, t := range argoWFActionTargets {
		actionTargets[a] = t
	}
	actionTargets["suspend"] = append(actionTargets["suspend"], "argoproj.io/cronworkflows")
	actionTargets["unsuspend"] = append(actionTargets["unsuspend"], "argoproj.io/cronworkflows")
}

// argoWFActionRequest holds the Argo Workflows fields of ActionRequest.
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

// runArgoWFAction performs one argowf-* action.
func (s *Server) runArgoWFAction(ctx context.Context, c *cluster.Clients, rq resourceQuery, ri dynamic.ResourceInterface, action, name string, req ActionRequest, dry []string) (ActionResult, error) {
	res := ActionResult{DryRun: req.DryRun, Context: c.Context}
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
	ns := rq.Namespace

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
			if req.DryRun {
				return res, httpx.BadRequest("dry run is not supported for a memoized resubmit")
			}
			created, err := s.argowf.ResubmitMemoized(ctx, c, ns, name)
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
		if req.DryRun {
			return res, httpx.BadRequest("dry run is not supported for retry")
		}
		if phase, _, _ := unstructured.NestedString(obj.Object, "status", "phase"); phase != "Failed" && phase != "Error" {
			return res, httpx.BadRequest("only Failed or Error workflows can be retried (this one is %s)", phase)
		}
		if err := s.argowf.Retry(ctx, c, ns, name, req.RestartSuccessful); err != nil {
			return res, err
		}
		res.Message = "Retrying " + name
		return res, nil
	case "argowf-submit":
		var wf map[string]any
		target := ns
		switch rq.Type.Resource {
		case "cronworkflows":
			wf = argowf.FromCronWorkflow(obj.Object, time.Now())
		case "workflowtemplates", "clusterworkflowtemplates":
			cluster := rq.Type.Resource == "clusterworkflowtemplates"
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
			return res, httpx.BadRequest("cannot submit from %s", rq.Type.Resource)
		}
		created, err := create(target, wf)
		res.Message = fmt.Sprintf("Submitted %s from %s %s", created, rq.Type.Kind, name)
		return res, err
	}
	return res, httpx.BadRequest("unknown action %q", action)
}
