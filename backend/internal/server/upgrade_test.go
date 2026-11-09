package server

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/version"
	"k8s.io/client-go/discovery/cached/memory"
	fakediscovery "k8s.io/client-go/discovery/fake"
	"k8s.io/client-go/kubernetes/fake"
	metadatafake "k8s.io/client-go/metadata/fake"

	"github.com/matty234/k8sman/backend/internal/cluster"
	upg "github.com/matty234/k8sman/backend/internal/upgrade"
)

// A removed API is found from all three places it shows up — discovery
// serving it, a live object's managedFields / last-applied annotation, and
// the latest revision of a Helm release — against the embedded table, and
// only the latest Helm revision is read.
func TestUpgradeRemovedAPIs(t *testing.T) {
	ctx := context.Background()
	helmSecret := func(rev int, manifest string) (*corev1.Secret, *metav1.PartialObjectMetadata) {
		rel, _ := json.Marshal(map[string]any{
			"name": "demo", "namespace": "default", "version": rev, "manifest": manifest,
			"chart": map[string]any{"metadata": map[string]any{"name": "demo", "version": "1.0.0"}},
		})
		var gz bytes.Buffer
		zw := gzip.NewWriter(&gz)
		_, _ = zw.Write(rel)
		_ = zw.Close()
		name := "sh.helm.release.v1.demo.v" + string(rune('0'+rev))
		labels := map[string]string{"owner": "helm", "name": "demo", "version": string(rune('0' + rev))}
		meta := metav1.ObjectMeta{Name: name, Namespace: "default", Labels: labels}
		return &corev1.Secret{ObjectMeta: meta, Type: "helm.sh/release.v1", Data: map[string][]byte{"release": []byte(base64.StdEncoding.EncodeToString(gz.Bytes()))}},
			&metav1.PartialObjectMetadata{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Secret"}, ObjectMeta: meta}
	}
	oldSec, oldMeta := helmSecret(2, "apiVersion: batch/v1beta1\nkind: CronJob\nmetadata:\n  name: old-job\n")
	newSec, newMeta := helmSecret(3, strings.Join([]string{
		"apiVersion: flowcontrol.apiserver.k8s.io/v1beta3\nkind: FlowSchema\nmetadata:\n  name: demo-fs\n",
		"apiVersion: policy/v1beta1\nkind: PodDisruptionBudget\nmetadata:\n  name: demo-pdb\n",
		"apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: demo\n",
	}, "---\n"))

	fs := func(name string, mf []metav1.ManagedFieldsEntry, lastApplied string) *metav1.PartialObjectMetadata {
		o := &metav1.PartialObjectMetadata{TypeMeta: metav1.TypeMeta{APIVersion: "flowcontrol.apiserver.k8s.io/v1", Kind: "FlowSchema"},
			ObjectMeta: metav1.ObjectMeta{Name: name, ManagedFields: mf}}
		if lastApplied != "" {
			o.Annotations = map[string]string{corev1.LastAppliedConfigAnnotation: lastApplied}
		}
		return o
	}
	scheme := metadatafake.NewTestScheme()
	_ = metav1.AddMetaToScheme(scheme)
	md := metadatafake.NewSimpleMetadataClient(scheme, []runtime.Object{
		fs("example", []metav1.ManagedFieldsEntry{{Manager: "example-operator", APIVersion: "flowcontrol.apiserver.k8s.io/v1beta3"}}, ""),
		fs("demo", nil, `{"apiVersion":"flowcontrol.apiserver.k8s.io/v1beta3","kind":"FlowSchema"}`),
		fs("current", []metav1.ManagedFieldsEntry{{Manager: "kube-apiserver", APIVersion: "flowcontrol.apiserver.k8s.io/v1"}}, ""),
		oldMeta, newMeta,
	}...)

	cs := fake.NewSimpleClientset(oldSec, newSec)
	fd := cs.Discovery().(*fakediscovery.FakeDiscovery)
	fd.FakedServerVersion = &version.Info{GitVersion: "v1.31.2"}
	cs.Resources = []*metav1.APIResourceList{
		{GroupVersion: "flowcontrol.apiserver.k8s.io/v1", APIResources: []metav1.APIResource{{Name: "flowschemas", Kind: "FlowSchema"}}},
		{GroupVersion: "flowcontrol.apiserver.k8s.io/v1beta3", APIResources: []metav1.APIResource{{Name: "flowschemas", Kind: "FlowSchema"}}},
		{GroupVersion: "v1", APIResources: []metav1.APIResource{{Name: "secrets", Kind: "Secret", Namespaced: true}}},
	}
	c := &cluster.Clients{Context: "demo", Typed: cs, Metadata: md, Discovery: memory.NewMemCacheClient(cs.Discovery())}

	disc, err := discoverAPIs(c)
	if err != nil {
		t.Fatal(err)
	}
	cur, _ := upg.ParseVersion(disc.version)
	uses, err := scanAPIUses(ctx, c, disc, cur, nil)
	if err != nil {
		t.Fatal(err)
	}
	rels, err := latestHelmReleases(ctx, c, nil)
	if err != nil || len(rels) != 1 || rels[0].Revision != 3 {
		t.Fatalf("helm releases = %+v, %v; want only revision 3", rels, err)
	}
	reqs := parseDeprecatedMetric([]byte(`# TYPE apiserver_requested_deprecated_apis gauge
apiserver_requested_deprecated_apis{group="flowcontrol.apiserver.k8s.io",removed_release="1.32",resource="flowschemas",subresource="",version="v1beta3"} 1
`))

	res := upg.Analyze(upg.Input{ServerVersion: disc.version, Served: disc.served, APIUses: uses, Helm: rels, Deprecated: reqs}, upg.V(32))
	got := map[string]upg.Finding{}
	for _, f := range res.Findings {
		if f.Check == upg.CheckAPIs {
			got[f.ID] = f
		}
	}
	want := map[string]string{
		"apis/served/flowcontrol.apiserver.k8s.io/v1beta3":                upg.Info,
		"apis/object/FlowSchema/example":                                  upg.Warning, // managedFields
		"apis/object/FlowSchema/demo":                                     upg.Blocker, // last-applied
		"apis/helm/default/demo":                                          upg.Blocker,
		"apis/requested/flowcontrol.apiserver.k8s.io/v1beta3/flowschemas": upg.Blocker,
	}
	for id, sev := range want {
		if got[id].Severity != sev {
			t.Errorf("%s: severity %q, want %q", id, got[id].Severity, sev)
		}
	}
	if len(got) != len(want) {
		t.Errorf("findings %v, want exactly %v", got, want)
	}
	h := got["apis/helm/default/demo"]
	if !strings.Contains(h.Detail, "demo-fs") || !strings.Contains(h.Detail, "demo-pdb") || strings.Contains(h.Detail, "old-job") || strings.Contains(h.Detail, "Deployment") {
		t.Errorf("helm detail = %q", h.Detail)
	}
	if res.Counts[upg.Blocker] != 3 {
		t.Errorf("blockers = %d, want 3", res.Counts[upg.Blocker])
	}
}
