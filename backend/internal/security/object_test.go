package security

import (
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// A Pod's findings are its Deployment's; its images carry every CVE of the
// report for its own ReplicaSet; ignore rules move findings aside.
func TestAnalyzeObject(t *testing.T) {
	spec := hardenedSpec()
	spec.Containers[0].SecurityContext.Privileged = ptr(true)
	labels := map[string]string{"app": "web"}
	rs := appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Namespace: "default", Name: "web-1", OwnerReferences: ownedBy("apps/v1", "Deployment", "web")}}
	pod := corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: "default", Name: "web-1-abc", OwnerReferences: ownedBy("apps/v1", "ReplicaSet", "web-1")},
		Spec: spec, Status: corev1.PodStatus{Phase: corev1.PodRunning}}
	report := vulnReport("default", "replicaset-web-1-app", "web-1", "app", "example/app", "1.0", "2026-11-03T00:00:00Z",
		vuln("CVE-2024-0002", "HIGH", "libc", "", 7),
		vuln("CVE-2024-0001", "CRITICAL", "openssl", "3.0.14", 9.8),
	)
	in := Input{
		Now: now, Namespace: "default",
		Deployments: []appsv1.Deployment{deployment("default", "web", labels, spec)},
		ReplicaSets: []appsv1.ReplicaSet{rs}, Pods: []corev1.Pod{pod},
		TrivyOperator: true, VulnerabilityReports: []unstructured.Unstructured{report},
	}
	res := AnalyzeObject(in, ObjectRef{Kind: "Pod", Name: "web-1-abc", Namespace: "default"}, nil)
	if res.Target.Kind != "Deployment" || res.Target.Name != "web" {
		t.Fatalf("target: %+v", res.Target)
	}
	var baseline *Finding
	for i, f := range res.Findings {
		if f.Check == "images.vulnerable" {
			t.Errorf("image findings are left to the images: %+v", f)
		}
		if f.Check == "workloads.pss-baseline" {
			baseline = &res.Findings[i]
		}
	}
	if baseline == nil || baseline.Severity != Critical {
		t.Fatalf("privileged pod fails baseline: %+v", res.Findings)
	}
	if len(res.Images) != 1 {
		t.Fatalf("images: %+v", res.Images)
	}
	img := res.Images[0]
	if !img.Scanned || img.Counts.Critical != 1 || img.Counts.High != 1 || img.CVEs[0].ID != "CVE-2024-0001" || img.Report == nil || img.Report.Name != "replicaset-web-1-app" {
		t.Errorf("image: %+v", img)
	}

	res = AnalyzeObject(in, ObjectRef{Group: "apps", Kind: "Deployment", Name: "web", Namespace: "default"},
		[]IgnoreRule{{Check: "workloads.pss-baseline", Kind: "Deployment", Name: "web", Namespace: "default"}})
	if len(res.Ignored) != 1 || res.Ignored[0].Check != "workloads.pss-baseline" || !res.Images[0].Scanned {
		t.Errorf("deployment: ignored %+v, images %+v", res.Ignored, res.Images)
	}
}
