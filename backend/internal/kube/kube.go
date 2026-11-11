// Package kube holds small helpers for reading Kubernetes objects and
// describing them, shared by the analysers (internal/overview,
// internal/security).
package kube

import (
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// Str returns the string at path in an unstructured object, or "" when it
// is missing or not a string.
func Str(m map[string]any, path ...string) string {
	s, _, _ := unstructured.NestedString(m, path...)
	return s
}

// Group returns the API group of an apiVersion ("apps/v1" → "apps",
// "v1" → "").
func Group(apiVersion string) string {
	if i := strings.IndexByte(apiVersion, '/'); i >= 0 {
		return apiVersion[:i]
	}
	return ""
}

// Key is the "<namespace>/<name>" key of an object.
func Key(ns, name string) string { return ns + "/" + name }

// ControllerOf returns the controller owner reference, else the first one,
// else nil.
func ControllerOf(refs []metav1.OwnerReference) *metav1.OwnerReference {
	for i := range refs {
		if refs[i].Controller != nil && *refs[i].Controller {
			return &refs[i]
		}
	}
	if len(refs) > 0 {
		return &refs[0]
	}
	return nil
}

// PodDeployment names the Deployment a pod's ReplicaSet would belong to: a
// Deployment's ReplicaSet is <deployment>-<pod-template-hash>, and its pods
// carry the hash. ok is false unless the pod's controller is a ReplicaSet
// named that way; callers check that the Deployment exists. It lets the
// analysers resolve owners without listing ReplicaSets, whose old revisions
// can run to tens of MB.
func PodDeployment(p *corev1.Pod) (rs, deployment string, ok bool) {
	c := ControllerOf(p.OwnerReferences)
	hash := p.Labels["pod-template-hash"]
	if c == nil || c.Kind != "ReplicaSet" || hash == "" {
		return "", "", false
	}
	deployment, ok = strings.CutSuffix(c.Name, "-"+hash)
	return c.Name, deployment, ok && deployment != ""
}

// Plural formats a count with the singular or plural noun: "1 pod", "2 pods".
func Plural(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%d %s", n, many)
}
