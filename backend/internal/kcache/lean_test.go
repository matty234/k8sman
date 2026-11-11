package kcache

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	metadatafake "k8s.io/client-go/metadata/fake"
	clienttesting "k8s.io/client-go/testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
)

// A lean Secrets stream lists Helm releases as metadata only (no value
// ever reaches the cache), the rest in full; the table's Keys and Size are
// right for full Secrets and Size is blank for releases. A full key never
// rides on the lean stream.
func TestLeanSecrets(t *testing.T) {
	opaque := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
		"metadata": map[string]any{"name": "app", "namespace": "ns", "uid": "u1", "resourceVersion": "5"},
		"data":     map[string]any{"user": "YWRtaW4=", "pass": "c2VjcmV0"}, // 5 + 6 bytes
	}}
	release := func(name, rv string) *metav1.PartialObjectMetadata {
		return &metav1.PartialObjectMetadata{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "ns", UID: types.UID("u-" + name), ResourceVersion: rv}}
	}
	selectors := make(chan string, 8)
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{SecretsGVR: "SecretList"})
	dyn.PrependReactor("list", "secrets", func(a clienttesting.Action) (bool, runtime.Object, error) {
		selectors <- a.(clienttesting.ListAction).GetListRestrictions().Fields.String()
		l := &unstructured.UnstructuredList{Items: []unstructured.Unstructured{*opaque.DeepCopy()}}
		l.SetResourceVersion("10")
		return true, l, nil
	})
	dyn.PrependWatchReactor("secrets", func(clienttesting.Action) (bool, watch.Interface, error) {
		return true, watch.NewFake(), nil
	})
	md := metadatafake.NewSimpleMetadataClient(metadatafake.NewTestScheme())
	mw := watch.NewFake()
	md.PrependReactor("list", "secrets", func(a clienttesting.Action) (bool, runtime.Object, error) {
		selectors <- a.(clienttesting.ListAction).GetListRestrictions().Fields.String()
		return true, &metav1.List{Items: []runtime.RawExtension{{Object: release("sh.helm.release.v1.web.v1", "7")}}}, nil
	})
	md.PrependWatchReactor("secrets", func(clienttesting.Action) (bool, watch.Interface, error) { return true, mw, nil })

	c := New(dyn)
	c.meta = md
	defer c.Close()
	sub := c.Subscribe(Key{GVR: SecretsGVR, Lean: true})
	defer sub.Close()
	next := func() Update {
		select {
		case <-sub.C():
			return sub.Next()
		case <-time.After(5 * time.Second):
			t.Fatal("timed out")
			return Update{}
		}
	}
	u := next()
	if u.Snapshot == nil || len(u.Snapshot.Items) != 2 {
		t.Fatalf("snapshot = %+v", u)
	}
	got := []string{<-selectors, <-selectors}
	if !(strings.Contains(strings.Join(got, " "), "type!=helm.sh/release.v1") && strings.Contains(strings.Join(got, " "), "type=helm.sh/release.v1")) {
		t.Fatalf("selectors = %v", got)
	}

	defs := columns.Defaults(cluster.ResourceType{Version: "v1", Resource: "secrets", Kind: "Secret", Namespaced: true}, nil)
	cols := columns.NewEvaluator(defs)
	cells := map[string]map[string]any{} // object name → column name → cell
	for _, it := range u.Snapshot.Items {
		row, errs := cols.Row(columns.PrivateCopy(it.Object))
		cells[it.GetName()] = map[string]any{}
		for i, e := range errs {
			if e != nil {
				t.Fatal(e)
			}
			cells[it.GetName()][defs[i].Name] = row[i]
		}
	}
	if c := cells["app"]; c["Keys"] != 2 || c["Size"] != 11 {
		t.Fatalf("opaque cells = %v", c)
	}
	if c := cells["sh.helm.release.v1.web.v1"]; c["Type"] != "helm.sh/release.v1" || c["Keys"] != 1 || c["Size"] != nil {
		t.Fatalf("release cells = %v", c)
	}

	// A release revision arriving on the watch is a stand-in too.
	mw.Add(release("sh.helm.release.v1.web.v2", "8"))
	u = next()
	if len(u.Events) != 1 || u.Events[0].Object.Object["data"].(map[string]any)["release"] != nil {
		t.Fatalf("event = %+v", u.Events)
	}

	// The inspector's full watch of one Secret must not be served from it.
	if s, _ := c.acquire(Key{GVR: SecretsGVR, FieldSelector: "metadata.name=app"}); s.key.Lean {
		t.Fatal("full key answered by the lean stream")
	}
}

// BenchmarkSecretsList is what a Secrets table costs the backend per LIST
// of 400 Secrets, 100 of them Helm releases (synthetic payloads of
// 100 KB-1 MB): decoding the upstream JSON and rendering the default
// columns, full and lean. upstream-B is the bytes the API server sends.
func BenchmarkSecretsList(b *testing.B) {
	var full, opaque, releases []byte
	{
		var all, rest, meta []any
		for i := range 400 {
			md := map[string]any{"name": fmt.Sprintf("s-%03d", i), "namespace": "ns", "uid": fmt.Sprintf("u%d", i), "resourceVersion": "1", "creationTimestamp": "2026-11-01T00:00:00Z"}
			obj := map[string]any{"apiVersion": "v1", "kind": "Secret", "metadata": md}
			if i%4 == 0 {
				size := 100_000 + (i*7919)%900_000
				obj["type"] = helmReleaseType
				obj["data"] = map[string]any{helmReleaseKey: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{byte(i)}, size))}
				meta = append(meta, map[string]any{"apiVersion": "meta.k8s.io/v1", "kind": "PartialObjectMetadata", "metadata": md})
			} else {
				obj["type"] = "Opaque"
				obj["data"] = map[string]any{"user": "YWRtaW4=", "pass": base64.StdEncoding.EncodeToString(make([]byte, 64))}
				rest = append(rest, obj)
			}
			all = append(all, obj)
		}
		enc := func(kind string, items []any) []byte {
			out, _ := json.Marshal(map[string]any{"apiVersion": "v1", "kind": kind, "metadata": map[string]any{"resourceVersion": "1"}, "items": items})
			return out
		}
		full, opaque, releases = enc("SecretList", all), enc("SecretList", rest), enc("PartialObjectMetadataList", meta)
	}
	cols := columns.NewEvaluator(columns.Defaults(cluster.ResourceType{Version: "v1", Resource: "secrets", Kind: "Secret", Namespaced: true}, nil))
	table := func(l *unstructured.UnstructuredList) {
		for i := range l.Items {
			cols.Row(columns.PrivateCopy(l.Items[i].Object))
		}
	}
	b.Run("full", func(b *testing.B) {
		for b.Loop() {
			l := &unstructured.UnstructuredList{}
			if err := l.UnmarshalJSON(full); err != nil {
				b.Fatal(err)
			}
			table(l)
		}
		b.ReportMetric(float64(len(full)), "upstream-B")
	})
	b.Run("lean", func(b *testing.B) {
		for b.Loop() {
			l := &unstructured.UnstructuredList{}
			var ml metav1.PartialObjectMetadataList
			if err := l.UnmarshalJSON(opaque); err != nil {
				b.Fatal(err)
			}
			if err := json.Unmarshal(releases, &ml); err != nil {
				b.Fatal(err)
			}
			for i := range ml.Items {
				l.Items = append(l.Items, *helmStub(&ml.Items[i]))
			}
			table(l)
		}
		b.ReportMetric(float64(len(opaque)+len(releases)), "upstream-B")
	})
}
