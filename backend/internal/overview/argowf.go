package overview

import (
	"fmt"
	"sort"
	"time"

	"github.com/matty234/k8sman/backend/internal/kube"
)

// WorkflowFailWindow is how far back failed Argo Workflows are reported.
const WorkflowFailWindow = 24 * time.Hour

// argoWorkflows reports Argo Workflows that failed (Failed/Error) within
// WorkflowFailWindow. Runs of the same CronWorkflow or WorkflowTemplate
// are reported once, as the latest failure with a count: critical while
// that origin's latest finished run is a failure, a warning once a later
// run succeeded.
func (a *analyzer) argoWorkflows() {
	if a.in.Workflows == nil {
		return
	}
	type run struct {
		wf       map[string]any
		finished time.Time
		failed   bool
	}
	type origin struct {
		owner *Owner
		runs  []run
	}
	origins := map[string]*origin{}
	var keys []string
	for _, wf := range a.in.Workflows {
		phase := kube.Str(wf, "status", "phase")
		finished := parseTS(kube.Str(wf, "status", "finishedAt"))
		if finished.IsZero() || (phase != "Failed" && phase != "Error" && phase != "Succeeded") {
			continue
		}
		ns := kube.Str(wf, "metadata", "namespace")
		key, owner := "wf/"+ns+"/"+kube.Str(wf, "metadata", "name"), (*Owner)(nil)
		labels := obj(wf, "metadata", "labels")
		if c, _ := labels["workflows.argoproj.io/cron-workflow"].(string); c != "" {
			key, owner = "cron/"+ns+"/"+c, &Owner{Group: "argoproj.io", Kind: "CronWorkflow", Name: c}
		} else if t := kube.Str(wf, "spec", "workflowTemplateRef", "name"); t != "" {
			kind := "WorkflowTemplate"
			if cs, _ := obj(wf, "spec", "workflowTemplateRef")["clusterScope"].(bool); cs {
				kind = "ClusterWorkflowTemplate"
			}
			key, owner = kind+"/"+ns+"/"+t, &Owner{Group: "argoproj.io", Kind: kind, Name: t}
		}
		o := origins[key]
		if o == nil {
			o = &origin{owner: owner}
			origins[key] = o
			keys = append(keys, key)
		}
		o.runs = append(o.runs, run{wf: wf, finished: finished, failed: phase != "Succeeded"})
	}
	sort.Strings(keys)
	for _, k := range keys {
		o := origins[k]
		sort.Slice(o.runs, func(i, j int) bool { return o.runs[i].finished.After(o.runs[j].finished) })
		var latestFail *run
		recent := 0
		for i := range o.runs {
			r := &o.runs[i]
			if r.failed && a.now.Sub(r.finished) <= WorkflowFailWindow {
				recent++
				if latestFail == nil {
					latestFail = r
				}
			}
		}
		if latestFail == nil {
			continue
		}
		wf := latestFail.wf
		sev := Critical
		if !o.runs[0].failed {
			sev = Warning // a later run succeeded
		}
		msg := kube.Str(wf, "status", "message")
		if msg == "" {
			msg = failedNodeMessage(wf)
		}
		if recent > 1 {
			msg = fmt.Sprintf("%d failed runs in 24h; latest: %s", recent, nonEmpty(msg, kube.Str(wf, "status", "phase")))
		}
		if sev == Warning {
			msg += " (a later run succeeded)"
		}
		a.add(Issue{
			Severity:  sev,
			Category:  "workflowFailed",
			Kind:      "Workflow",
			Group:     "argoproj.io",
			Namespace: kube.Str(wf, "metadata", "namespace"),
			Name:      kube.Str(wf, "metadata", "name"),
			Reason:    kube.Str(wf, "status", "phase"),
			Message:   msg,
			Owner:     o.owner,
			since:     latestFail.finished,
		})
	}
}

// failedNodeMessage is "<step>: <message>" for the first failed pod step.
func failedNodeMessage(wf map[string]any) string {
	nodes := obj(wf, "status", "nodes")
	ids := make([]string, 0, len(nodes))
	for id := range nodes {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var best map[string]any
	for _, id := range ids {
		n, _ := nodes[id].(map[string]any)
		if n == nil || n["type"] != "Pod" || (n["phase"] != "Failed" && n["phase"] != "Error") {
			continue
		}
		if best == nil || kube.Str(n, "finishedAt") < kube.Str(best, "finishedAt") {
			best = n
		}
	}
	if best == nil {
		return ""
	}
	return kube.Str(best, "displayName") + ": " + nonEmpty(kube.Str(best, "message"), "failed")
}
