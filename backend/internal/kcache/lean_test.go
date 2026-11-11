package kcache

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"reflect"
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
	"github.com/matty234/k8sman/backend/internal/kapi"
)

// A lean stream of a heavy kind first lists metadata (stand-ins whose body
// cells are pending), then fills summaries from the full objects, then
// watches full objects, summarising each. No Secret value is ever cached,
// snapshot readers wait for the fill, and a full key (the inspector) never
// rides on it. Every heavy kind's summary renders its default columns as
// the full object does.
func TestLeanMetadataFirst(t *testing.T) {
	const value = "c2VjcmV0LXZhbHVl" // "secret-value"
	secret := func(name, rv string, data map[string]any) *unstructured.Unstructured {
		return &unstructured.Unstructured{Object: map[string]any{
			"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
			"metadata": map[string]any{"name": name, "namespace": "ns", "uid": "u-" + name, "resourceVersion": rv,
				"annotations": map[string]any{lastApplied: `{"data":{"pass":"` + value + `"}}`}},
			"data": data,
		}}
	}
	app := secret("app", "5", map[string]any{"user": "YWRtaW4=", "pass": value}) // 5 + 12 bytes
	release := secret("sh.helm.release.v1.web.v1", "7", map[string]any{"release": base64.StdEncoding.EncodeToString(make([]byte, 3000))})
	release.Object["type"] = "helm.sh/release.v1"

	fill := make(chan struct{})
	dyn := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{SecretsGVR: "SecretList"})
	dyn.PrependReactor("list", "secrets", func(clienttesting.Action) (bool, runtime.Object, error) {
		<-fill
		l := &unstructured.UnstructuredList{Items: []unstructured.Unstructured{*app.DeepCopy(), *release.DeepCopy()}}
		l.SetResourceVersion("10")
		return true, l, nil
	})
	fw := watch.NewFake()
	watchRV := make(chan string, 1)
	dyn.PrependWatchReactor("secrets", func(a clienttesting.Action) (bool, watch.Interface, error) {
		watchRV <- a.(clienttesting.WatchActionImpl).GetWatchRestrictions().ResourceVersion
		return true, fw, nil
	})
	md := metadatafake.NewSimpleMetadataClient(metadatafake.NewTestScheme())
	md.PrependReactor("list", "secrets", func(clienttesting.Action) (bool, runtime.Object, error) {
		var items []runtime.RawExtension
		for _, u := range []*unstructured.Unstructured{app, release} {
			items = append(items, runtime.RawExtension{Object: &metav1.PartialObjectMetadata{ObjectMeta: metav1.ObjectMeta{
				Name: u.GetName(), Namespace: "ns", UID: types.UID("u-" + u.GetName()), ResourceVersion: u.GetResourceVersion(), Annotations: u.GetAnnotations()}}})
		}
		return true, &metav1.List{Items: items}, nil
	})

	c := New(dyn)
	c.meta = md
	defer c.Close()
	key := Key{GVR: SecretsGVR, Lean: true}
	sub := c.Subscribe(key)
	defer sub.Close()
	next := func() Update {
		for {
			select {
			case <-sub.C():
				if u := sub.Next(); u.Snapshot != nil || len(u.Events) > 0 || u.Err != nil {
					return u
				}
			case <-time.After(5 * time.Second):
				t.Fatal("timed out")
				return Update{}
			}
		}
	}
	defs := columns.Defaults(cluster.ResourceType{Version: "v1", Resource: "secrets", Kind: "Secret", Namespaced: true}, nil)
	cols := columns.NewEvaluator(defs)
	cells := func(u *unstructured.Unstructured) map[string]any {
		row, errs := cols.Row(columns.PrivateCopy(u.Object))
		out := map[string]any{}
		for i, e := range errs {
			if e != nil {
				t.Fatal(e)
			}
			out[defs[i].Name] = row[i]
		}
		return out
	}
	noValues := func(objs ...*unstructured.Unstructured) {
		t.Helper()
		for _, u := range objs {
			if b, _ := json.Marshal(u.Object); bytes.Contains(b, []byte(value)) || bytes.Contains(b, []byte("YWRtaW4=")) {
				t.Fatalf("a Secret value is cached: %s", b)
			}
		}
	}

	// 1. The first snapshot is stand-ins: metadata only, the body cells
	// (all but plain metadata paths) pending. Snapshot readers wait.
	u := next()
	if u.Snapshot == nil || len(u.Snapshot.Items) != 2 {
		t.Fatalf("snapshot = %+v", u)
	}
	for _, it := range u.Snapshot.Items {
		if !Pending(it) {
			t.Fatalf("%s is not pending", it.GetName())
		}
	}
	noValues(u.Snapshot.Items...)
	var pending []string
	for _, d := range defs {
		if !columns.MetadataOnly(d) {
			pending = append(pending, d.Name)
		}
	}
	if strings.Join(pending, ",") != "Type,Keys,Size" {
		t.Fatalf("pending columns = %v", pending)
	}
	if _, ok := c.Cached(key); ok {
		t.Fatal("a snapshot reader was served stand-ins")
	}

	// 2. The fill replaces them with summaries; the watch starts from the
	// fill's version.
	close(fill)
	u = next()
	if len(u.Events) != 2 {
		t.Fatalf("fill events = %+v", u)
	}
	got := map[string]map[string]any{}
	for _, ev := range u.Events {
		if ev.Type != watch.Modified || Pending(ev.Object) {
			t.Fatalf("fill event = %v %v", ev.Type, ev.Object.Object)
		}
		got[ev.Object.GetName()] = cells(ev.Object)
	}
	if c := got["app"]; c["Type"] != "Opaque" || c["Keys"] != 2 || c["Size"] != 17 {
		t.Fatalf("app cells = %v", c)
	}
	if c := got["sh.helm.release.v1.web.v1"]; c["Type"] != "helm.sh/release.v1" || c["Size"] != 3000 {
		t.Fatalf("release cells = %v", c)
	}
	if rv := <-watchRV; rv != "10" {
		t.Fatalf("watch from %q, want the fill's version", rv)
	}
	snap, ok := c.Cached(key)
	if !ok || len(snap.Items) != 2 {
		t.Fatal("no snapshot after the fill")
	}
	noValues(snap.Items...)

	// 3. A watch event (a full object) updates the summary.
	fw.Modify(secret("app", "11", map[string]any{"user": "YWRtaW4=", "pass": value, "extra": "YQ=="}))
	u = next()
	if len(u.Events) != 1 || cells(u.Events[0].Object)["Keys"] != 3 || cells(u.Events[0].Object)["Size"] != 18 {
		t.Fatalf("watch event = %+v", u.Events)
	}
	noValues(u.Events[0].Object)

	// 4. The inspector's full watch of one Secret is never served from it.
	if s, _ := c.acquire(Key{GVR: SecretsGVR, Namespace: "ns", FieldSelector: "metadata.name=app"}); s.key.Lean {
		t.Fatal("full key answered by the lean stream")
	}

	// Every heavy kind has a summary that renders its default columns as
	// the full object does.
	full := map[string]map[string]any{
		"secrets": app.Object,
		"configmaps": {"apiVersion": "v1", "kind": "ConfigMap", "metadata": map[string]any{"name": "c"},
			"data": map[string]any{"a": "héllo"}, "binaryData": map[string]any{"b": "AAECAw=="}},
		"customresourcedefinitions": {"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition", "metadata": map[string]any{"name": "widgets.example.com"},
			"spec": map[string]any{"group": "example.com", "scope": "Namespaced", "names": map[string]any{"kind": "Widget", "plural": "widgets"},
				"versions": []any{map[string]any{"name": "v1", "served": true, "storage": true, "schema": map[string]any{"openAPIV3Schema": map[string]any{"type": "object"}}}}}},
	}
	for _, a := range kapi.MetadataFirst {
		sum, _, ok := heavy(a.GVR())
		obj := full[a.Resource]
		if !ok || obj == nil {
			t.Fatalf("%s: no summariser or fixture", a.Resource)
		}
		ev := columns.NewEvaluator(columns.Defaults(cluster.ResourceType{Group: a.Group, Version: a.Version(), Resource: a.Resource, Kind: a.Kind}, nil))
		want, _ := ev.Row(columns.PrivateCopy(runtime.DeepCopyJSON(obj)))
		s := sum(runtime.DeepCopyJSON(obj))
		have, _ := ev.Row(columns.PrivateCopy(runtime.DeepCopyJSON(s)))
		if !reflect.DeepEqual(want, have) {
			t.Fatalf("%s: summary cells %v, full %v", a.Resource, have, want)
		}
	}
}

// BenchmarkLeanList is what a table of a heavy kind costs the backend: 400
// Secrets (100 of them Helm releases with 100 KB-1 MB payloads) and 400
// ConfigMaps (a quarter of them 50-500 KB). "full" decodes the upstream
// LIST and renders the default columns; "first-snapshot" is the
// metadata-first table's first SNAPSHOT (decode the metadata LIST, build
// stand-ins); "fill" is the rest (decode pages of fillPage, summarise,
// render). upstream-B is the bytes the API server sends.
func BenchmarkLeanList(b *testing.B) {
	type kind struct {
		name       string
		gvr        schema.GroupVersionResource
		kind, list string
		body       func(i int, obj map[string]any)
	}
	kinds := []kind{
		{"secrets", SecretsGVR, "Secret", "SecretList", func(i int, obj map[string]any) {
			if i%4 == 0 {
				obj["type"] = "helm.sh/release.v1"
				obj["data"] = map[string]any{"release": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{byte(i)}, 100_000+(i*7919)%900_000))}
			} else {
				obj["type"] = "Opaque"
				obj["data"] = map[string]any{"user": "YWRtaW4=", "pass": base64.StdEncoding.EncodeToString(make([]byte, 64))}
			}
		}},
		{"configmaps", kapi.ConfigMaps.GVR(), "ConfigMap", "ConfigMapList", func(i int, obj map[string]any) {
			n := 200
			if i%4 == 0 {
				n = 50_000 + (i*7919)%450_000
			}
			obj["data"] = map[string]any{"config.yaml": strings.Repeat("k: v\n", n/5)}
		}},
	}
	for _, k := range kinds {
		var all, meta []any
		for i := range 400 {
			md := map[string]any{"name": fmt.Sprintf("o-%03d", i), "namespace": "ns", "uid": fmt.Sprintf("u%d", i), "resourceVersion": "1", "creationTimestamp": "2026-11-01T00:00:00Z"}
			obj := map[string]any{"apiVersion": "v1", "kind": k.kind, "metadata": md}
			k.body(i, obj)
			all = append(all, obj)
			meta = append(meta, map[string]any{"apiVersion": "meta.k8s.io/v1", "kind": "PartialObjectMetadata", "metadata": md})
		}
		enc := func(kind string, items []any) []byte {
			out, _ := json.Marshal(map[string]any{"apiVersion": "v1", "kind": kind, "metadata": map[string]any{"resourceVersion": "1"}, "items": items})
			return out
		}
		full, metaList := enc(k.list, all), enc("PartialObjectMetadataList", meta)
		var pages [][]byte
		for i := 0; i < len(all); i += fillPage {
			pages = append(pages, enc(k.list, all[i:min(i+fillPage, len(all))]))
		}
		sum, _, _ := heavy(k.gvr)
		cols := columns.NewEvaluator(columns.Defaults(cluster.ResourceType{Version: "v1", Resource: k.name, Kind: k.kind, Namespaced: true}, nil))
		rows := func(items []unstructured.Unstructured) {
			for i := range items {
				cols.Row(columns.PrivateCopy(items[i].Object))
			}
		}
		b.Run(k.name+"/full", func(b *testing.B) {
			for b.Loop() {
				l := &unstructured.UnstructuredList{}
				if err := l.UnmarshalJSON(full); err != nil {
					b.Fatal(err)
				}
				rows(l.Items)
			}
			b.ReportMetric(float64(len(full)), "upstream-B")
		})
		b.Run(k.name+"/first-snapshot", func(b *testing.B) {
			for b.Loop() {
				var ml metav1.PartialObjectMetadataList
				if err := json.Unmarshal(metaList, &ml); err != nil {
					b.Fatal(err)
				}
				items := make([]unstructured.Unstructured, len(ml.Items))
				for i := range ml.Items {
					items[i] = *standIn(&ml.Items[i], "v1", k.kind)
				}
			}
			b.ReportMetric(float64(len(metaList)), "upstream-B")
		})
		b.Run(k.name+"/fill", func(b *testing.B) {
			n := 0
			for _, p := range pages {
				n += len(p)
			}
			for b.Loop() {
				for _, p := range pages {
					l := &unstructured.UnstructuredList{}
					if err := l.UnmarshalJSON(p); err != nil {
						b.Fatal(err)
					}
					for i := range l.Items {
						l.Items[i].Object = sum(l.Items[i].Object)
					}
					rows(l.Items)
				}
			}
			b.ReportMetric(float64(n), "upstream-B")
		})
	}
}
