package kcache

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/runtime/serializer/protobuf"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/watch"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/kubernetes/scheme"
	metadatafake "k8s.io/client-go/metadata/fake"
	"k8s.io/client-go/rest"
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
// Secrets (100 of them Helm releases with 100 KB-1 MB payloads, random
// bytes as Helm's are gzipped) and 400 ConfigMaps (a quarter of them
// 50-500 KB). "full" decodes the upstream LIST and renders the default
// columns; "first-snapshot" is the metadata-first table's first SNAPSHOT
// (decode the metadata LIST, build stand-ins); "fill" is the rest (decode
// pages of fillPage, summarise, render), "fill-protobuf" the same from
// protobuf pages (proto.go; it checks the summaries are the JSON ones).
// upstream-B is the bytes the API server sends, gzip-B the same gzipped
// (as the API server compresses LISTs).
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
				payload := make([]byte, 100_000+(i*7919)%900_000)
				rand.NewChaCha8([32]byte{byte(i), byte(i >> 8)}).Read(payload)
				obj["data"] = map[string]any{"release": base64.StdEncoding.EncodeToString(payload)}
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
		var pages, protoPages [][]byte
		for i := 0; i < len(all); i += fillPage {
			p := enc(k.list, all[i:min(i+fillPage, len(all))])
			pages = append(pages, p)
			protoPages = append(protoPages, toProtobuf(b, p, newProtoList(k.gvr.GroupResource())))
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
		jsonFill := func(p []byte) []unstructured.Unstructured {
			l := &unstructured.UnstructuredList{}
			if err := l.UnmarshalJSON(p); err != nil {
				b.Fatal(err)
			}
			for i := range l.Items {
				l.Items[i].Object = sum(l.Items[i].Object)
			}
			return l.Items
		}
		protoFill := func(p []byte) []unstructured.Unstructured {
			l := newProtoList(k.gvr.GroupResource())
			if _, _, err := scheme.Codecs.UniversalDeserializer().Decode(p, nil, l); err != nil {
				b.Fatal(err)
			}
			objs := protoSummarisers[k.gvr.GroupResource()](l)
			items := make([]unstructured.Unstructured, len(objs))
			for i, o := range objs {
				o["apiVersion"], o["kind"] = "v1", k.kind
				items[i].Object = o
			}
			return items
		}
		for i := range pages {
			if j, p := jsonFill(pages[i]), protoFill(protoPages[i]); !reflect.DeepEqual(j, p) {
				b.Fatalf("protobuf summaries differ: %v\nvs %v", p[0].Object, j[0].Object)
			}
		}
		for _, f := range []struct {
			name  string
			pages [][]byte
			read  func([]byte) []unstructured.Unstructured
		}{{"fill", pages, jsonFill}, {"fill-protobuf", protoPages, protoFill}} {
			b.Run(k.name+"/"+f.name, func(b *testing.B) {
				for b.Loop() {
					for _, p := range f.pages {
						rows(f.read(p))
					}
				}
				reportBytes(b, f.pages...)
			})
		}
	}
}

// BenchmarkPodsList weighs protobuf for a full kind: 2,000 Pods from a
// LIST into the cache's unstructured objects, JSON against protobuf
// (typed decode, then DefaultUnstructuredConverter). Not adopted: see
// docs/PERFORMANCE.md.
func BenchmarkPodsList(b *testing.B) {
	pods := &corev1.PodList{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "PodList"}}
	for i := range 2000 {
		pods.Items = append(pods.Items, benchPod(i))
	}
	js, err := json.Marshal(pods)
	if err != nil {
		b.Fatal(err)
	}
	pb := toProtobuf(b, js, &corev1.PodList{})
	b.Run("json", func(b *testing.B) {
		for b.Loop() {
			l := &unstructured.UnstructuredList{}
			if err := l.UnmarshalJSON(js); err != nil {
				b.Fatal(err)
			}
			for i := range l.Items {
				trim(&l.Items[i])
			}
		}
		reportBytes(b, js)
	})
	b.Run("protobuf", func(b *testing.B) {
		for b.Loop() {
			l := &corev1.PodList{}
			if _, _, err := scheme.Codecs.UniversalDeserializer().Decode(pb, nil, l); err != nil {
				b.Fatal(err)
			}
			items := make([]unstructured.Unstructured, len(l.Items))
			for i := range l.Items {
				l.Items[i].ManagedFields = nil
				items[i].Object = typedMap(&l.Items[i])
				items[i].SetAPIVersion("v1")
				items[i].SetKind("Pod")
			}
		}
		reportBytes(b, pb)
	})
}

// benchPod is a Deployment's pod with two containers, as a cluster has.
func benchPod(i int) corev1.Pod {
	ts := metav1.NewTime(time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC))
	ctr := func(name string) corev1.Container {
		var env []corev1.EnvVar
		for j := range 8 {
			env = append(env, corev1.EnvVar{Name: fmt.Sprintf("SETTING_%d", j), Value: fmt.Sprintf("value-%d-%d", i, j)})
		}
		return corev1.Container{Name: name, Image: "registry.example.com/team/" + name + ":v1.2.3", Args: []string{"--port=8080", "--log-level=info"},
			Env: env, Ports: []corev1.ContainerPort{{Name: "http", ContainerPort: 8080, Protocol: corev1.ProtocolTCP}},
			Resources: corev1.ResourceRequirements{Requests: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("100m"), corev1.ResourceMemory: resource.MustParse("128Mi")},
				Limits: corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("256Mi")}},
			VolumeMounts:           []corev1.VolumeMount{{Name: "config", MountPath: "/etc/app"}, {Name: "kube-api-access", MountPath: "/var/run/secrets/kubernetes.io/serviceaccount", ReadOnly: true}},
			ReadinessProbe:         &corev1.Probe{ProbeHandler: corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{Path: "/healthz", Port: intstr.FromString("http")}}, PeriodSeconds: 10},
			TerminationMessagePath: "/dev/termination-log", TerminationMessagePolicy: corev1.TerminationMessageReadFile, ImagePullPolicy: corev1.PullIfNotPresent}
	}
	cond := func(t corev1.PodConditionType) corev1.PodCondition {
		return corev1.PodCondition{Type: t, Status: corev1.ConditionTrue, LastTransitionTime: ts}
	}
	cs := func(name string) corev1.ContainerStatus {
		return corev1.ContainerStatus{Name: name, Ready: true, Image: "registry.example.com/team/" + name + ":v1.2.3", ImageID: "registry.example.com/team/" + name + "@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			ContainerID: fmt.Sprintf("containerd://%064d", i), State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{StartedAt: ts}}}
	}
	return corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: fmt.Sprintf("web-7d9c8b6f5-%05d", i), Namespace: fmt.Sprintf("team-%d", i%20), UID: types.UID(fmt.Sprintf("uid-%d", i)),
			ResourceVersion: "12345", CreationTimestamp: ts, GenerateName: "web-7d9c8b6f5-",
			Labels:          map[string]string{"app": "web", "pod-template-hash": "7d9c8b6f5", "app.kubernetes.io/part-of": "shop"},
			Annotations:     map[string]string{"prometheus.io/scrape": "true", "kubectl.kubernetes.io/restartedAt": "2026-11-01T00:00:00Z"},
			OwnerReferences: []metav1.OwnerReference{{APIVersion: "apps/v1", Kind: "ReplicaSet", Name: "web-7d9c8b6f5", UID: "rs-uid"}},
			ManagedFields: []metav1.ManagedFieldsEntry{{Manager: "kube-controller-manager", Operation: metav1.ManagedFieldsOperationUpdate, APIVersion: "v1", Time: &ts, FieldsType: "FieldsV1",
				FieldsV1: &metav1.FieldsV1{Raw: []byte(`{"f:metadata":{"f:generateName":{},"f:labels":{".":{},"f:app":{},"f:pod-template-hash":{}},"f:ownerReferences":{".":{},"k:{\"uid\":\"rs-uid\"}":{}}},"f:spec":{"f:containers":{"k:{\"name\":\"app\"}":{".":{},"f:args":{},"f:env":{},"f:image":{},"f:name":{},"f:ports":{},"f:resources":{}}}}}`)}}},
		},
		Spec: corev1.PodSpec{Containers: []corev1.Container{ctr("app"), ctr("sidecar")}, NodeName: fmt.Sprintf("node-%d", i%30), ServiceAccountName: "web",
			Volumes: []corev1.Volume{{Name: "config", VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{LocalObjectReference: corev1.LocalObjectReference{Name: "web-config"}}}},
				{Name: "kube-api-access", VolumeSource: corev1.VolumeSource{Projected: &corev1.ProjectedVolumeSource{Sources: []corev1.VolumeProjection{
					{ServiceAccountToken: &corev1.ServiceAccountTokenProjection{Path: "token"}},
					{ConfigMap: &corev1.ConfigMapProjection{LocalObjectReference: corev1.LocalObjectReference{Name: "kube-root-ca.crt"}, Items: []corev1.KeyToPath{{Key: "ca.crt", Path: "ca.crt"}}}}}}}}},
			Tolerations:   []corev1.Toleration{{Key: "node.kubernetes.io/not-ready", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoExecute}},
			RestartPolicy: corev1.RestartPolicyAlways, DNSPolicy: corev1.DNSClusterFirst, SchedulerName: "default-scheduler"},
		Status: corev1.PodStatus{Phase: corev1.PodRunning, PodIP: fmt.Sprintf("10.1.%d.%d", i/250, i%250), HostIP: "10.0.0.1", StartTime: &ts, QOSClass: corev1.PodQOSBurstable,
			Conditions:        []corev1.PodCondition{cond(corev1.PodInitialized), cond(corev1.PodReady), cond(corev1.ContainersReady), cond(corev1.PodScheduled)},
			ContainerStatuses: []corev1.ContainerStatus{cs("app"), cs("sidecar")}},
	}
}

// toProtobuf re-encodes a JSON list as protobuf, by way of its typed list.
func toProtobuf(b *testing.B, js []byte, into runtime.Object) []byte {
	if err := json.Unmarshal(js, into); err != nil {
		b.Fatal(err)
	}
	var buf bytes.Buffer
	if err := protobuf.NewSerializer(scheme.Scheme, scheme.Scheme).Encode(into, &buf); err != nil {
		b.Fatal(err)
	}
	return buf.Bytes()
}

// reportBytes reports what the API server sends, raw and gzipped.
func reportBytes(b *testing.B, bodies ...[]byte) {
	raw, gz := 0, 0
	for _, body := range bodies {
		raw += len(body)
		var buf bytes.Buffer
		w := gzip.NewWriter(&buf)
		w.Write(body)
		w.Close()
		gz += buf.Len()
	}
	b.ReportMetric(float64(raw), "upstream-B")
	b.ReportMetric(float64(gz), "gzip-B")
}

// A protobuf fill against a server that answers JSON (as it does for a
// kind without protobuf) reads the JSON: same pages, same summaries.
func TestProtoFillFallsBackToJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Accept"), runtime.ContentTypeProtobuf) {
			t.Errorf("Accept = %q", r.Header.Get("Accept"))
		}
		name, cont := "a", "next"
		if r.URL.Query().Get("continue") == "next" {
			name, cont = "b", ""
		}
		w.Header().Set("Content-Type", runtime.ContentTypeJSON)
		fmt.Fprintf(w, `{"kind":"SecretList","apiVersion":"v1","metadata":{"resourceVersion":"7","continue":%q},
			"items":[{"metadata":{"name":%q,"namespace":"ns"},"type":"Opaque","data":{"pass":"c2VjcmV0"}}]}`, cont, name)
	}))
	defer srv.Close()
	c := New(nil)
	var err error
	if c.proto, err = NewProtoClient(&rest.Config{Host: srv.URL}, srv.Client()); err != nil {
		t.Fatal(err)
	}
	l, err := c.ListOnce(t.Context(), Key{GVR: SecretsGVR, Lean: true})
	if err != nil || len(l.Items) != 2 || l.GetResourceVersion() != "7" {
		t.Fatalf("list = %v, %v", l, err)
	}
	want := map[string]any{"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
		"metadata": map[string]any{"name": "b", "namespace": "ns", "creationTimestamp": nil}, "data": map[string]any{"pass": int64(6)}}
	if !reflect.DeepEqual(l.Items[1].Object, want) {
		t.Fatalf("summary = %v", l.Items[1].Object)
	}
}
