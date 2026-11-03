package icons

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/metadata"
)

// Release is the part of a Helm v3 release record this package needs.
type Release struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Chart     struct {
		Metadata struct {
			Name string `json:"name"`
			Icon string `json:"icon"`
			Home string `json:"home"`
		} `json:"metadata"`
		// Files are non-template chart files; CRDs live under crds/.
		Files []struct {
			Name string `json:"name"`
			Data []byte `json:"data"` // base64 in JSON
		} `json:"files"`
	} `json:"chart"`
}

// maxRelease caps a decompressed release record.
const maxRelease = 32 << 20

// DecodeRelease decodes the "release" key of a helm.sh/release.v1 Secret
// (the bytes as client-go returns them, i.e. after the Secret's own base64):
// base64 → gzip → JSON. Helm skips gzip for tiny releases, so a plain JSON
// payload is accepted too.
func DecodeRelease(data []byte) (*Release, error) {
	raw, err := base64.StdEncoding.DecodeString(string(data))
	if err != nil {
		return nil, fmt.Errorf("helm release: %w", err)
	}
	if bytes.HasPrefix(raw, []byte{0x1f, 0x8b}) {
		zr, err := gzip.NewReader(bytes.NewReader(raw))
		if err != nil {
			return nil, fmt.Errorf("helm release: %w", err)
		}
		defer zr.Close()
		raw, err = io.ReadAll(io.LimitReader(zr, maxRelease))
		if err != nil {
			return nil, fmt.Errorf("helm release: %w", err)
		}
	}
	var r Release
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("helm release: %w", err)
	}
	return &r, nil
}

var crdGroupRe = regexp.MustCompile(`(?m)^\s{0,4}group:\s*["']?([a-z0-9][a-z0-9.-]*\.[a-z0-9-]+)["']?\s*$`)

// CRDGroups lists the API groups of the CRDs shipped in the chart's crds/
// directory.
func (r *Release) CRDGroups() []string {
	seen := map[string]bool{}
	var out []string
	for _, f := range r.Chart.Files {
		if !strings.HasPrefix(f.Name, "crds/") {
			continue
		}
		if !bytes.Contains(f.Data, []byte("CustomResourceDefinition")) {
			continue
		}
		for _, m := range crdGroupRe.FindAllSubmatch(f.Data, -1) {
			g := string(m[1])
			if !seen[g] {
				seen[g] = true
				out = append(out, g)
			}
		}
	}
	return out
}

type releaseKey struct{ namespace, name string }

// helmIndex maps CRD groups to the icon of the Helm release that installed
// (or operates) them, for one cluster.
type helmIndex struct {
	icons   map[releaseKey]string // release → chart icon URL
	byGroup map[string]releaseKey
	// how each group was attributed, for diagnostics.
	via map[string]string
}

var crdGVR = schema.GroupVersionResource{Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}

const (
	annRelease   = "meta.helm.sh/release-name"
	annReleaseNS = "meta.helm.sh/release-namespace"
)

// buildHelmIndex reads deployed Helm releases and attributes CRD groups to
// them, in order of confidence:
//  1. the CRD carries Helm ownership annotations (or helm.sh/chart +
//     app.kubernetes.io/instance labels);
//  2. the release's chart ships the CRD in its crds/ directory (Helm
//     doesn't label those);
//  3. a Helm-managed ClusterRole grants write access to the group — the
//     release that runs the group's controller (e.g. kube-prometheus-stack's
//     operator for monitoring.coreos.com, whose CRDs come from a subchart).
//
// Any step that lacks RBAC is skipped.
func buildHelmIndex(ctx context.Context, typed kubernetes.Interface, meta metadata.Interface) *helmIndex {
	idx := &helmIndex{icons: map[releaseKey]string{}, byGroup: map[string]releaseKey{}, via: map[string]string{}}
	byName := map[string][]releaseKey{} // release name → keys (for label-only CRDs)
	shipped := map[string]releaseKey{}
	cont := ""
	for page := 0; page < 10; page++ {
		list, err := typed.CoreV1().Secrets("").List(ctx, metav1.ListOptions{
			LabelSelector: "owner=helm,status=deployed",
			Limit:         50,
			Continue:      cont,
		})
		if err != nil {
			break
		}
		for _, s := range list.Items {
			if s.Type != "helm.sh/release.v1" {
				continue
			}
			rel, err := DecodeRelease(s.Data["release"])
			if err != nil {
				continue
			}
			k := releaseKey{s.Namespace, rel.Name}
			if k.name == "" {
				k.name = s.Labels["name"]
			}
			idx.icons[k] = strings.TrimSpace(rel.Chart.Metadata.Icon)
			byName[k.name] = append(byName[k.name], k)
			for _, g := range rel.CRDGroups() {
				// Gateway API etc. are often vendored into other charts.
				if _, dup := shipped[g]; !dup && !IsKubernetesGroup(g) {
					shipped[g] = k
				}
			}
		}
		cont = list.Continue
		if cont == "" {
			break
		}
	}
	if len(idx.icons) == 0 {
		return idx
	}

	// 1. Labelled/annotated CRDs (metadata only: CRD objects are large).
	var crds []metav1.PartialObjectMetadata
	if meta != nil {
		if list, err := meta.Resource(crdGVR).List(ctx, metav1.ListOptions{}); err == nil {
			crds = list.Items
		}
	}
	for _, c := range crds {
		_, group, ok := strings.Cut(c.Name, ".")
		if !ok || idx.byGroup[group] != (releaseKey{}) {
			continue
		}
		a, l := c.Annotations, c.Labels
		var k releaseKey
		switch {
		case a[annRelease] != "" && a[annReleaseNS] != "":
			k = releaseKey{a[annReleaseNS], a[annRelease]}
		case l["app.kubernetes.io/managed-by"] == "Helm" && l["app.kubernetes.io/instance"] != "" && len(byName[l["app.kubernetes.io/instance"]]) == 1:
			k = byName[l["app.kubernetes.io/instance"]][0]
		default:
			continue
		}
		if _, ok := idx.icons[k]; ok {
			idx.byGroup[group], idx.via[group] = k, "crd-annotations"
		}
	}
	// 2. CRDs shipped in a chart's crds/ directory.
	for g, k := range shipped {
		if _, done := idx.byGroup[g]; !done {
			idx.byGroup[g], idx.via[g] = k, "chart-crds"
		}
	}
	// 3. The release whose ClusterRole controls the group.
	if roles, err := typed.RbacV1().ClusterRoles().List(ctx, metav1.ListOptions{}); err == nil {
		best := map[string]int{}
		cand := map[string]releaseKey{}
		for _, cr := range roles.Items {
			a := cr.Annotations
			k := releaseKey{a[annReleaseNS], a[annRelease]}
			if k.name == "" || k.namespace == "" {
				continue
			}
			if _, ok := idx.icons[k]; !ok {
				continue
			}
			for _, rule := range cr.Rules {
				if !writes(rule.Verbs) {
					continue
				}
				for _, g := range rule.APIGroups {
					if g == "" || g == "*" || IsKubernetesGroup(g) || !strings.Contains(g, ".") {
						continue
					}
					if score := len(rule.Resources); score > best[g] {
						best[g], cand[g] = score, k
					}
				}
			}
		}
		for g, k := range cand {
			if _, done := idx.byGroup[g]; !done {
				idx.byGroup[g], idx.via[g] = k, "controller-clusterrole"
			}
		}
	}
	return idx
}

func writes(verbs []string) bool {
	for _, v := range verbs {
		switch v {
		case "*", "create", "update", "patch", "delete":
			return true
		}
	}
	return false
}

// iconFor returns the chart icon URL attributed to group, and the release.
func (h *helmIndex) iconFor(group string) (iconURL, release string) {
	k, ok := h.byGroup[group]
	if !ok {
		return "", ""
	}
	return h.icons[k], k.namespace + "/" + k.name
}
