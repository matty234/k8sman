// Package argowf supports Argo Workflows (argoproj.io Workflow,
// CronWorkflow, WorkflowTemplate, ClusterWorkflowTemplate).
//
// Most operations are done directly on the CRs, the same way the argo CLI
// and argo-server do them (both are thin wrappers over the kube API for
// these), so they need only kube RBAC:
//
//   - stop / terminate: merge-patch spec.shutdown = Stop | Terminate
//   - suspend: spec.suspend = true
//   - resume: clear spec.suspend and mark running Suspend nodes Succeeded
//     (util.ResumeWorkflow)
//   - resubmit: create a new Workflow from the old spec
//     (util.FormulateResubmitWorkflow, non-memoized)
//   - submit from a CronWorkflow / (Cluster)WorkflowTemplate
//     (common.ConvertCronWorkflowToWorkflow, NewWorkflowFromWorkflowTemplate)
//
// Retry (and memoized resubmit) rewrite node statuses and delete pods in
// ways that are not safe to re-implement, so they go through argo-server's
// API (see server.go) and are only offered when it is reachable and accepts
// our credentials.
package argowf

import (
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
)

// Group is the Argo API group (shared with Argo CD).
const Group = "argoproj.io"

// Labels and annotations Argo uses (workflow/common/common.go).
const (
	LabelCompleted               = "workflows.argoproj.io/completed"
	LabelPhase                   = "workflows.argoproj.io/phase"
	LabelCreator                 = "workflows.argoproj.io/creator"
	LabelCreatorEmail            = "workflows.argoproj.io/creator-email"
	LabelCreatorPreferredName    = "workflows.argoproj.io/creator-preferred-username"
	LabelArchivingStatus         = "workflows.argoproj.io/workflow-archiving-status"
	LabelResubmittedFrom         = "workflows.argoproj.io/resubmitted-from-workflow"
	LabelCronWorkflow            = "workflows.argoproj.io/cron-workflow"
	LabelWorkflowTemplate        = "workflows.argoproj.io/workflow-template"
	LabelClusterWorkflowTemplate = "workflows.argoproj.io/cluster-workflow-template"
	LabelControllerInstanceID    = "workflows.argoproj.io/controller-instanceid"
	AnnotationScheduledTime      = "workflows.argoproj.io/scheduled-time"
)

// Completed reports whether a workflow phase is final.
func Completed(phase string) bool {
	return phase == "Succeeded" || phase == "Failed" || phase == "Error"
}

// ShutdownPatch is the merge patch for stop (Stop) and terminate (Terminate).
func ShutdownPatch(wf map[string]any, strategy string) (map[string]any, error) {
	if strategy != "Stop" && strategy != "Terminate" {
		return nil, fmt.Errorf("unknown shutdown strategy %q", strategy)
	}
	if phase := str(wf, "status", "phase"); Completed(phase) {
		return nil, fmt.Errorf("cannot %s a completed workflow (%s)", strings.ToLower(strategy), phase)
	}
	return map[string]any{"spec": map[string]any{"shutdown": strategy}}, nil
}

// SuspendPatch is the merge patch that suspends a running workflow.
func SuspendPatch(wf map[string]any) (map[string]any, error) {
	if phase := str(wf, "status", "phase"); Completed(phase) {
		return nil, fmt.Errorf("cannot suspend a completed workflow (%s)", phase)
	}
	return map[string]any{"spec": map[string]any{"suspend": true}}, nil
}

// ResumePatch mirrors util.ResumeWorkflow: clear spec.suspend and mark every
// running Suspend node Succeeded (outputs supplied by the user fall back to
// their defaults). The resourceVersion makes it a compare-and-swap. It
// returns nil when there is nothing to resume.
func ResumePatch(wf map[string]any, now time.Time) (map[string]any, error) {
	if v, _, _ := unstructured.NestedString(wf, "status", "offloadNodeStatusVersion"); v != "" {
		return nil, fmt.Errorf("node status is offloaded to the persistence database; resume it with the argo CLI or UI")
	}
	patch := map[string]any{}
	if s, _, _ := unstructured.NestedBool(wf, "spec", "suspend"); s {
		patch["spec"] = map[string]any{"suspend": nil}
	}
	nodes, _, _ := unstructured.NestedMap(wf, "status", "nodes")
	nodePatch := map[string]any{}
	for _, id := range slices.Sorted(maps.Keys(nodes)) {
		n, _ := nodes[id].(map[string]any)
		if str(n, "type") != "Suspend" || str(n, "phase") != "Running" {
			continue
		}
		np := map[string]any{"phase": "Succeeded", "finishedAt": now.UTC().Format(time.RFC3339)}
		if params, ok, _ := unstructured.NestedSlice(n, "outputs", "parameters"); ok {
			out := make([]any, 0, len(params))
			for _, p := range params {
				pm, _ := p.(map[string]any)
				if pm == nil {
					out = append(out, p)
					continue
				}
				pm = maps.Clone(pm)
				if vf, _ := pm["valueFrom"].(map[string]any); vf != nil && vf["supplied"] != nil && pm["value"] == nil {
					def, ok := vf["default"]
					if !ok || def == nil {
						return nil, fmt.Errorf("output parameter %q of %s must be supplied and has no default; resume it with the argo CLI or UI", pm["name"], str(n, "displayName"))
					}
					pm["value"] = def
				}
				out = append(out, pm)
			}
			np["outputs"] = map[string]any{"parameters": out}
		}
		nodePatch[id] = np
	}
	if len(nodePatch) > 0 {
		patch["status"] = map[string]any{"nodes": nodePatch}
	}
	if len(patch) == 0 {
		return nil, nil
	}
	patch["metadata"] = map[string]any{"resourceVersion": str(wf, "metadata", "resourceVersion")}
	return patch, nil
}

// Suspended reports whether a workflow is suspended: spec.suspend, or a
// running Suspend node (an approval step).
func Suspended(wf map[string]any) bool {
	if s, _, _ := unstructured.NestedBool(wf, "spec", "suspend"); s {
		return true
	}
	nodes, _, _ := unstructured.NestedMap(wf, "status", "nodes")
	for _, v := range nodes {
		n, _ := v.(map[string]any)
		if str(n, "type") == "Suspend" && str(n, "phase") == "Running" {
			return true
		}
	}
	return false
}

// Resubmit mirrors util.FormulateResubmitWorkflow without memoization: a
// new Workflow with the same spec (and so the same parameters), a
// generateName, the user's labels and annotations, and a label naming the
// original. Status, owner references and Argo's bookkeeping labels are
// dropped.
func Resubmit(wf map[string]any) map[string]any {
	name := str(wf, "metadata", "name")
	gen := str(wf, "metadata", "generateName")
	if gen == "" {
		gen = name + "-"
	}
	spec := deepCopy(obj(wf, "spec"))
	if v, ok := spec["activeDeadlineSeconds"]; ok && toInt(v) == 0 {
		// It was terminated: drop the zero deadline.
		delete(spec, "activeDeadlineSeconds")
	}
	delete(spec, "shutdown")
	labels := map[string]any{}
	for k, v := range obj(wf, "metadata", "labels") {
		switch k {
		case LabelCreator, LabelCreatorEmail, LabelCreatorPreferredName, LabelPhase, LabelCompleted, LabelArchivingStatus:
		default:
			labels[k] = v
		}
	}
	labels[LabelResubmittedFrom] = name
	annotations := map[string]any{}
	for k, v := range obj(wf, "metadata", "annotations") {
		if k != "kubectl.kubernetes.io/last-applied-configuration" {
			annotations[k] = v
		}
	}
	meta := map[string]any{"generateName": gen, "labels": labels}
	if ns := str(wf, "metadata", "namespace"); ns != "" {
		meta["namespace"] = ns
	}
	if len(annotations) > 0 {
		meta["annotations"] = annotations
	}
	return map[string]any{
		"apiVersion": cmpOr(str(wf, "apiVersion"), Group+"/v1alpha1"),
		"kind":       "Workflow",
		"metadata":   meta,
		"spec":       spec,
	}
}

// FromCronWorkflow mirrors common.ConvertCronWorkflowToWorkflow (what
// `argo submit --from cronwf/NAME` creates): the cron's workflowSpec and
// workflowMetadata, the cron-workflow label, the scheduled-time annotation
// and a controller reference to the CronWorkflow, so the run shows up in
// its history like a scheduled one.
func FromCronWorkflow(cron map[string]any, now time.Time) map[string]any {
	name := str(cron, "metadata", "name")
	labels := map[string]any{}
	if id := str(cron, "metadata", "labels", LabelControllerInstanceID); id != "" {
		labels[LabelControllerInstanceID] = id
	}
	labels[LabelCronWorkflow] = name
	annotations := map[string]any{AnnotationScheduledTime: now.UTC().Format(time.RFC3339)}
	for k, v := range obj(cron, "spec", "workflowMetadata", "labels") {
		labels[k] = v
	}
	for k, v := range obj(cron, "spec", "workflowMetadata", "annotations") {
		annotations[k] = v
	}
	apiVersion := cmpOr(str(cron, "apiVersion"), Group+"/v1alpha1")
	return map[string]any{
		"apiVersion": apiVersion,
		"kind":       "Workflow",
		"metadata": map[string]any{
			"generateName": name + "-",
			"namespace":    str(cron, "metadata", "namespace"),
			"labels":       labels,
			"annotations":  annotations,
			"ownerReferences": []any{map[string]any{
				"apiVersion": apiVersion, "kind": "CronWorkflow", "name": name,
				"uid": str(cron, "metadata", "uid"), "controller": true, "blockOwnerDeletion": true,
			}},
		},
		"spec": deepCopy(obj(cron, "spec", "workflowSpec")),
	}
}

// Param is one workflow argument.
type Param struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// FromTemplate mirrors common.NewWorkflowFromWorkflowTemplate plus the
// submit options argo-server applies: a Workflow that references the
// template, labelled with it, with the given parameters (and entrypoint,
// when set). template is the (Cluster)WorkflowTemplate object.
func FromTemplate(template map[string]any, cluster bool, namespace string, params []Param, entrypoint string) map[string]any {
	name := str(template, "metadata", "name")
	labels := map[string]any{}
	if id := str(template, "metadata", "labels", LabelControllerInstanceID); id != "" {
		labels[LabelControllerInstanceID] = id
	}
	ref := map[string]any{"name": name}
	if cluster {
		ref["clusterScope"] = true
		labels[LabelClusterWorkflowTemplate] = name
	} else {
		labels[LabelWorkflowTemplate] = name
	}
	spec := map[string]any{"workflowTemplateRef": ref}
	if len(params) > 0 {
		ps := make([]any, len(params))
		for i, p := range params {
			ps[i] = map[string]any{"name": p.Name, "value": p.Value}
		}
		spec["arguments"] = map[string]any{"parameters": ps}
	}
	if entrypoint != "" {
		spec["entrypoint"] = entrypoint
	}
	return map[string]any{
		"apiVersion": cmpOr(str(template, "apiVersion"), Group+"/v1alpha1"),
		"kind":       "Workflow",
		"metadata":   map[string]any{"generateName": name + "-", "namespace": namespace, "labels": labels},
		"spec":       spec,
	}
}

// ValidateParams checks submitted parameters against the template's
// spec.arguments.parameters: known names, enum membership.
func ValidateParams(template map[string]any, params []Param) error {
	decl, _, _ := unstructured.NestedSlice(template, "spec", "arguments", "parameters")
	known := map[string][]string{}
	for _, d := range decl {
		dm, _ := d.(map[string]any)
		var enum []string
		if e, ok := dm["enum"].([]any); ok {
			for _, v := range e {
				enum = append(enum, fmt.Sprint(v))
			}
		}
		known[str(dm, "name")] = enum
	}
	for _, p := range params {
		enum, ok := known[p.Name]
		if !ok {
			return fmt.Errorf("unknown parameter %q", p.Name)
		}
		if len(enum) > 0 && !slices.Contains(enum, p.Value) {
			return fmt.Errorf("parameter %q must be one of %s", p.Name, strings.Join(enum, ", "))
		}
	}
	return nil
}

// ---- small helpers -----------------------------------------------------------

func obj(m map[string]any, path ...string) map[string]any {
	v, _, _ := unstructured.NestedFieldNoCopy(m, path...)
	mm, _ := v.(map[string]any)
	return mm
}

func str(m map[string]any, path ...string) string {
	v, _, _ := unstructured.NestedFieldNoCopy(m, path...)
	s, _ := v.(string)
	return s
}

func toInt(v any) int64 {
	switch n := v.(type) {
	case int64:
		return n
	case int:
		return int64(n)
	case float64:
		return int64(n)
	case json.Number:
		i, _ := n.Int64()
		return i
	}
	return -1
}

func deepCopy(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return runtime.DeepCopyJSON(m)
}

func cmpOr(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
