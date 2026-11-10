package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"reflect"
	"regexp"
	"runtime"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
)

type fakeLogs struct {
	mu   sync.Mutex
	open map[string]*io.PipeWriter
	n    int
}

func (f *fakeLogs) Open(ctx context.Context, ns, pod string, o *corev1.PodLogOptions) (io.ReadCloser, error) {
	pr, pw := io.Pipe()
	f.mu.Lock()
	defer f.mu.Unlock()
	f.open[pod] = pw
	f.n++
	return pr, nil
}

func (f *fakeLogs) write(pod string, lines ...string) {
	f.mu.Lock()
	pw := f.open[pod]
	f.mu.Unlock()
	for _, l := range lines {
		fmt.Fprintln(pw, l)
	}
}

func runningPod(name string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec:       corev1.PodSpec{Containers: []corev1.Container{{Name: "app"}}},
		Status: corev1.PodStatus{ContainerStatuses: []corev1.ContainerStatus{
			{Name: "app", State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{}}}}},
	}
}

func TestAggregateMergesByTimestampAndCleansUp(t *testing.T) {
	aggReorderWindow, aggFlushEvery = 60*time.Millisecond, 10*time.Millisecond
	base := runtime.NumGoroutine()
	// Default container: annotation, then "main", then the first.
	dp := &corev1.Pod{Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "wait"}, {Name: "main"}}}}
	if got := (&aggregator{}).containersFor(dp); !reflect.DeepEqual(got, []string{"main"}) {
		t.Errorf("default container = %v, want [main]", got)
	}
	f := &fakeLogs{open: map[string]*io.PipeWriter{}}
	var mu sync.Mutex
	var lines, events []string
	a := &aggregator{tail: 10, follow: true, opener: f, emit: func(v any) error {
		mu.Lock()
		defer mu.Unlock()
		switch v := v.(type) {
		case []AggLine:
			for _, l := range v {
				lines = append(lines, l.Pod+":"+l.Line)
			}
		case AggEvent:
			events = append(events, v.Event+" "+v.Pod)
		}
		return nil
	}}
	ctx, cancel := context.WithCancel(context.Background())
	pods := make(chan []*corev1.Pod, 1)
	done := make(chan struct{})
	go func() { a.run(ctx, pods); close(done) }()
	pods <- []*corev1.Pod{runningPod("a"), runningPod("b")}
	waitFor(t, func() bool { f.mu.Lock(); defer f.mu.Unlock(); return f.n == 2 })

	// a's lines arrive first but b's are interleaved by timestamp.
	f.write("a", "2024-01-01T00:00:01Z one", "2024-01-01T00:00:03Z three")
	f.write("b", "2024-01-01T00:00:02Z two", "2024-01-01T00:00:04Z four")
	waitFor(t, func() bool { mu.Lock(); defer mu.Unlock(); return len(lines) == 4 })
	mu.Lock()
	if want := []string{"a:one", "b:two", "a:three", "b:four"}; !reflect.DeepEqual(lines, want) {
		t.Errorf("order = %v, want %v", lines, want)
	}
	mu.Unlock()

	pods <- []*corev1.Pod{runningPod("a")} // b deleted
	waitFor(t, func() bool { mu.Lock(); defer mu.Unlock(); return len(events) == 3 })
	mu.Lock()
	if want := []string{"added a", "added b", "removed b"}; !reflect.DeepEqual(events, want) {
		t.Errorf("events = %v, want %v", events, want)
	}
	mu.Unlock()

	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("run did not return after cancel")
	}
	waitFor(t, func() bool { return runtime.NumGoroutine() <= base })
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if cond() {
			return
		}
		time.Sleep(15 * time.Millisecond)
	}
	t.Fatal("condition not reached")
}

func TestAggregateQueryRegexAndUnion(t *testing.T) {
	scope := func(q url.Values) (kube.Namespaces, error) { return kube.ParseNamespaces(q) }
	if _, err := parseAggQuery(url.Values{"podRegex": {"web-("}}, scope); !errors.Is(err, httpx.ErrBadRequest) {
		t.Errorf("bad regex: err = %v, want a bad request", err)
	}
	aq, err := parseAggQuery(url.Values{"podRegex": {"^web-"}, "namespaces": {"default,demo"}, "selector": {"app=web", "app=api"}}, scope)
	if err != nil || len(aq.selectors) != 2 || len(aq.scope) != 2 {
		t.Fatalf("parse = %+v, %v", aq, err)
	}

	obj := func(ns, name string) *unstructured.Unstructured {
		p := runningPod(name)
		p.Namespace = ns
		m, _ := k8sruntime.DefaultUnstructuredConverter.ToUnstructured(p)
		return &unstructured.Unstructured{Object: m}
	}
	ps := newPodSet(2, aq.podRe)
	// The set stays unpublished until both selectors have reported.
	if ps.apply(0, kcache.Update{Snapshot: &kcache.Snapshot{Items: []*unstructured.Unstructured{
		obj("default", "web-1"), obj("demo", "web-1"), obj("default", "api-1")}}}) {
		t.Fatal("published before every watch reported")
	}
	// web-1 in default matches both selectors: it must appear once.
	if !ps.apply(1, kcache.Update{Snapshot: &kcache.Snapshot{Items: []*unstructured.Unstructured{
		obj("default", "web-1"), obj("demo", "web-2")}}}) {
		t.Fatal("not published")
	}
	var got []string
	for _, p := range <-ps.out {
		got = append(got, podID(p))
	}
	sort.Strings(got)
	if want := []string{"default/web-1", "demo/web-1", "demo/web-2"}; !reflect.DeepEqual(got, want) {
		t.Errorf("pods = %v, want %v", got, want)
	}

	a := &aggregator{containerRe: regexp.MustCompile("^(app|side)")}
	p := runningPod("web-1")
	p.Spec.Containers = append(p.Spec.Containers, corev1.Container{Name: "side"}, corev1.Container{Name: "init"})
	if got := a.containersFor(p); !reflect.DeepEqual(got, []string{"app", "side"}) {
		t.Errorf("containers = %v", got)
	}
}
