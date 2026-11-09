package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

func drainFixture() *fake.Clientset {
	ctrl := true
	owner := func(kind, name string) []metav1.OwnerReference {
		return []metav1.OwnerReference{{APIVersion: "apps/v1", Kind: kind, Name: name, Controller: &ctrl}}
	}
	pod := func(name string, owners []metav1.OwnerReference, vols ...corev1.Volume) *corev1.Pod {
		return &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "demo", OwnerReferences: owners},
			Spec:       corev1.PodSpec{NodeName: "worker-1", Volumes: vols},
			Status:     corev1.PodStatus{Phase: corev1.PodRunning},
		}
	}
	cs := fake.NewSimpleClientset(
		&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "worker-1"}},
		&appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: "agent", Namespace: "demo"}},
		pod("web-abc", owner("ReplicaSet", "web-6f")),
		pod("agent-xyz", owner("DaemonSet", "agent")),
		pod("cache-1", owner("ReplicaSet", "cache-7c"), corev1.Volume{Name: "tmp", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}}),
		pod("bare", nil),
	)
	// What a real API server has and the fake lacks: the Eviction API in
	// discovery, and evictions that remove the pod.
	cs.Resources = []*metav1.APIResourceList{
		{GroupVersion: "v1", APIResources: []metav1.APIResource{{Name: "pods"}, {Name: "pods/eviction", Group: "policy", Version: "v1", Kind: "Eviction"}}},
		{GroupVersion: "policy/v1", APIResources: []metav1.APIResource{{Name: "poddisruptionbudgets"}}},
	}
	cs.PrependReactor("create", "pods", func(a k8stesting.Action) (bool, runtime.Object, error) {
		if a.GetSubresource() != "eviction" {
			return false, nil, nil
		}
		ev := a.(k8stesting.CreateAction).GetObject().(*policyv1.Eviction)
		return true, nil, cs.Tracker().Delete(corev1.SchemeGroupVersion.WithResource("pods"), ev.Namespace, ev.Name)
	})
	return cs
}

func drainServer(cs *fake.Clientset, readOnly bool) *Server {
	s := &Server{mgr: cluster.NewStatic(&cluster.Clients{Context: "kind-dev", Typed: cs}), mux: http.NewServeMux(), readOnly: readOnly}
	s.drainRoutes()
	return s
}

func TestDrainCordonsAndEvicts(t *testing.T) {
	cs := drainFixture()
	s := drainServer(cs, false)
	w := httptest.NewRecorder()
	s.mux.ServeHTTP(w, httptest.NewRequest("POST", "/api/nodes/drain?name=worker-1",
		strings.NewReader(`{"deleteEmptyDirData":true,"force":true,"timeoutSeconds":20}`)))
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	var res DrainResult
	_ = json.Unmarshal(w.Body.Bytes(), &res)
	if res.Error != "" || strings.Join(res.Evicted, ",") != "demo/bare,demo/cache-1,demo/web-abc" || res.Context != "kind-dev" {
		t.Errorf("result: %+v", res)
	}
	n, _ := cs.CoreV1().Nodes().Get(context.Background(), "worker-1", metav1.GetOptions{})
	if !n.Spec.Unschedulable {
		t.Error("node not cordoned")
	}
	left, _ := cs.CoreV1().Pods("demo").List(context.Background(), metav1.ListOptions{})
	var names []string
	for _, p := range left.Items {
		names = append(names, p.Name)
	}
	if strings.Join(names, ",") != "agent-xyz" {
		t.Errorf("pods left: %v (only the DaemonSet pod should stay)", names)
	}
}
