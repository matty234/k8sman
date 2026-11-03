package argoapi

import (
	"encoding/json"
	"sort"
	"strings"

	"sigs.k8s.io/yaml"
)

// managedResource is one item of Argo CD's
// GET /api/v1/applications/{name}/managed-resources (a ResourceDiff). The
// states are JSON documents encoded as strings ("null" when absent).
type managedResource struct {
	Group               string `json:"group"`
	Kind                string `json:"kind"`
	Namespace           string `json:"namespace"`
	Name                string `json:"name"`
	TargetState         string `json:"targetState"`
	LiveState           string `json:"liveState"`
	NormalizedLiveState string `json:"normalizedLiveState"`
	PredictedLiveState  string `json:"predictedLiveState"`
	Hook                bool   `json:"hook"`
	Modified            bool   `json:"modified"`
}

// ResourceDiff is one resource in the GET /api/argocd/diff response.
type ResourceDiff struct {
	Group     string `json:"group"`
	Kind      string `json:"kind"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name"`
	// Status is OutOfSync when Argo marks the resource modified.
	Status          string `json:"status"`
	Hook            bool   `json:"hook"`
	RequiresPruning bool   `json:"requiresPruning"`
	// Target and Live are cleaned YAML. Nil target = will be pruned; nil
	// live = will be created.
	Target *string `json:"target"`
	Live   *string `json:"live"`
}

// DiffResponse is the GET /api/argocd/diff payload.
type DiffResponse struct {
	Resources []ResourceDiff `json:"resources"`
	Server    *Server        `json:"server"`
	Auth      string         `json:"auth"`
}

// noisyMetadata are fields that differ on every live object and that Argo
// CD's diff ignores anyway.
var noisyMetadata = []string{"managedFields", "resourceVersion", "uid", "generation", "creationTimestamp", "selfLink"}

// noisyAnnotations are controller-written annotations Argo ignores.
var noisyAnnotations = []string{
	"kubectl.kubernetes.io/last-applied-configuration",
	"deployment.kubernetes.io/revision",
}

// parseState decodes one of Argo's JSON-string states; nil when absent.
func parseState(s string) map[string]any {
	s = strings.TrimSpace(s)
	if s == "" || s == "null" {
		return nil
	}
	var obj map[string]any
	if json.Unmarshal([]byte(s), &obj) != nil {
		return nil
	}
	return obj
}

// clean drops the noise from obj in place.
func clean(obj map[string]any) {
	delete(obj, "status")
	md, _ := obj["metadata"].(map[string]any)
	if md == nil {
		return
	}
	for _, k := range noisyMetadata {
		delete(md, k)
	}
	if ann, ok := md["annotations"].(map[string]any); ok {
		for _, k := range noisyAnnotations {
			delete(ann, k)
		}
		if len(ann) == 0 {
			delete(md, "annotations")
		}
	}
}

// toYAML cleans obj and renders it (keys sorted). Nil stays nil.
func toYAML(obj map[string]any) *string {
	if obj == nil {
		return nil
	}
	clean(obj)
	b, err := yaml.Marshal(obj)
	if err != nil {
		return nil
	}
	s := string(b)
	return &s
}

// convert turns Argo's managed resources into cleaned YAML pairs. Like the
// Argo CD UI, it compares normalizedLiveState with predictedLiveState when
// Argo computed a prediction (that is the diff Argo itself shows: ignored
// differences and normalisations applied), and liveState with targetState
// otherwise.
//
// Argo doesn't set "modified" on a resource it would prune, so a null target
// with a live object means "to be pruned", but only when the comparison
// produced targets at all: when it failed (ComparisonError, repo-server
// down) every target is null.
func convert(items []managedResource) []ResourceDiff {
	compared := false
	for _, it := range items {
		if parseState(it.TargetState) != nil || parseState(it.PredictedLiveState) != nil {
			compared = true
			break
		}
	}
	out := make([]ResourceDiff, 0, len(items))
	for _, it := range items {
		var target, live map[string]any
		if predicted := parseState(it.PredictedLiveState); predicted != nil {
			target, live = predicted, parseState(it.NormalizedLiveState)
		} else {
			target, live = parseState(it.TargetState), parseState(it.LiveState)
		}
		r := ResourceDiff{
			Group: it.Group, Kind: it.Kind, Namespace: it.Namespace, Name: it.Name,
			Status: "Synced", Hook: it.Hook,
			Target: toYAML(target), Live: toYAML(live),
		}
		r.RequiresPruning = compared && r.Target == nil && r.Live != nil && !it.Hook
		if it.Modified || r.RequiresPruning {
			r.Status = "OutOfSync"
		}
		out = append(out, r)
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if (a.Status == "OutOfSync") != (b.Status == "OutOfSync") {
			return a.Status == "OutOfSync"
		}
		return a.Kind+"/"+a.Namespace+"/"+a.Name < b.Kind+"/"+b.Namespace+"/"+b.Name
	})
	return out
}
