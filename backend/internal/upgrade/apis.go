package upgrade

import "strings"

// APIChange is one group/version/kind that Kubernetes deprecated and (when
// RemovedIn is set) stopped serving.
type APIChange struct {
	Group    string // "" for the core group
	Version  string
	Kind     string
	Resource string // plural, as served
	// DeprecatedIn is the release that deprecated it (zero when the guide
	// doesn't say); RemovedIn the first release that no longer serves it.
	DeprecatedIn Version
	RemovedIn    Version
	// Replacement is the apiVersion to move to ("" = none: the kind is gone).
	Replacement string
	// Note is what else changes with the move, from the guide (short).
	Note string
	// Ephemeral kinds are never stored (reviews) or are high-volume
	// (Events): live objects aren't scanned for them, manifests are.
	Ephemeral bool
}

// APIVersion is "group/version" ("version" for the core group).
func (a APIChange) APIVersion() string {
	if a.Group == "" {
		return a.Version
	}
	return a.Group + "/" + a.Version
}

// MigrationGuide is the page the table comes from.
const MigrationGuide = "https://kubernetes.io/docs/reference/using-api/deprecation-guide/"

// APIChanges is the deprecated API table, from the Kubernetes "Deprecated
// API Migration Guide" (MigrationGuide), covering the removals in 1.16
// through 1.32, as the guide stood in 2025 (it lists no further removals of
// beta or GA APIs after 1.32). Alpha APIs aren't covered: they can go in any
// release. Update this table when the guide gains a section.
var APIChanges = func() []APIChange {
	var out []APIChange
	add := func(dep, rem int, apiVersion, replacement, note string, kinds ...string) {
		group, version := splitAPIVersion(apiVersion)
		for _, kr := range kinds {
			kind, res, _ := strings.Cut(kr, ":")
			c := APIChange{Group: group, Version: version, Kind: kind, Resource: res, RemovedIn: V(rem), Replacement: replacement, Note: note}
			if dep > 0 {
				c.DeprecatedIn = V(dep)
			}
			c.Ephemeral = strings.HasSuffix(kind, "Review") || kind == "Event"
			out = append(out, c)
		}
	}
	// v1.32
	add(29, 32, "flowcontrol.apiserver.k8s.io/v1beta3", "flowcontrol.apiserver.k8s.io/v1", "",
		"FlowSchema:flowschemas", "PriorityLevelConfiguration:prioritylevelconfigurations")
	// v1.29
	add(26, 29, "flowcontrol.apiserver.k8s.io/v1beta2", "flowcontrol.apiserver.k8s.io/v1", "",
		"FlowSchema:flowschemas", "PriorityLevelConfiguration:prioritylevelconfigurations")
	// v1.27
	add(24, 27, "storage.k8s.io/v1beta1", "storage.k8s.io/v1", "", "CSIStorageCapacity:csistoragecapacities")
	// v1.26
	add(23, 26, "flowcontrol.apiserver.k8s.io/v1beta1", "flowcontrol.apiserver.k8s.io/v1", "",
		"FlowSchema:flowschemas", "PriorityLevelConfiguration:prioritylevelconfigurations")
	add(23, 26, "autoscaling/v2beta2", "autoscaling/v2", "targetAverageUtilization and friends moved under target", "HorizontalPodAutoscaler:horizontalpodautoscalers")
	// v1.25
	add(21, 25, "batch/v1beta1", "batch/v1", "", "CronJob:cronjobs")
	add(21, 25, "discovery.k8s.io/v1beta1", "discovery.k8s.io/v1", "topology became zone and hints", "EndpointSlice:endpointslices")
	add(19, 25, "events.k8s.io/v1beta1", "events.k8s.io/v1", "", "Event:events")
	add(22, 25, "autoscaling/v2beta1", "autoscaling/v2", "metric targets were restructured", "HorizontalPodAutoscaler:horizontalpodautoscalers")
	add(21, 25, "policy/v1beta1", "policy/v1", "an empty selector now matches every pod in the namespace", "PodDisruptionBudget:poddisruptionbudgets")
	add(21, 25, "policy/v1beta1", "", "PodSecurityPolicy is gone: use Pod Security Admission or a policy engine", "PodSecurityPolicy:podsecuritypolicies")
	add(20, 25, "node.k8s.io/v1beta1", "node.k8s.io/v1", "", "RuntimeClass:runtimeclasses")
	// v1.22
	add(16, 22, "admissionregistration.k8s.io/v1beta1", "admissionregistration.k8s.io/v1", "failurePolicy now defaults to Fail and sideEffects is required",
		"MutatingWebhookConfiguration:mutatingwebhookconfigurations", "ValidatingWebhookConfiguration:validatingwebhookconfigurations")
	add(16, 22, "apiextensions.k8s.io/v1beta1", "apiextensions.k8s.io/v1", "a structural schema is required", "CustomResourceDefinition:customresourcedefinitions")
	add(19, 22, "apiregistration.k8s.io/v1beta1", "apiregistration.k8s.io/v1", "", "APIService:apiservices")
	add(19, 22, "authentication.k8s.io/v1beta1", "authentication.k8s.io/v1", "", "TokenReview:tokenreviews")
	add(19, 22, "authorization.k8s.io/v1beta1", "authorization.k8s.io/v1", "",
		"SubjectAccessReview:subjectaccessreviews", "LocalSubjectAccessReview:localsubjectaccessreviews", "SelfSubjectAccessReview:selfsubjectaccessreviews")
	add(19, 22, "certificates.k8s.io/v1beta1", "certificates.k8s.io/v1", "signerName is required", "CertificateSigningRequest:certificatesigningrequests")
	add(19, 22, "coordination.k8s.io/v1beta1", "coordination.k8s.io/v1", "", "Lease:leases")
	add(19, 22, "extensions/v1beta1", "networking.k8s.io/v1", "backend.serviceName became backend.service.name; pathType is required", "Ingress:ingresses")
	add(19, 22, "networking.k8s.io/v1beta1", "networking.k8s.io/v1", "backend.serviceName became backend.service.name; pathType is required",
		"Ingress:ingresses", "IngressClass:ingressclasses")
	add(17, 22, "rbac.authorization.k8s.io/v1beta1", "rbac.authorization.k8s.io/v1", "",
		"ClusterRole:clusterroles", "ClusterRoleBinding:clusterrolebindings", "Role:roles", "RoleBinding:rolebindings")
	add(14, 22, "scheduling.k8s.io/v1beta1", "scheduling.k8s.io/v1", "", "PriorityClass:priorityclasses")
	add(19, 22, "storage.k8s.io/v1beta1", "storage.k8s.io/v1", "",
		"CSIDriver:csidrivers", "CSINode:csinodes", "StorageClass:storageclasses", "VolumeAttachment:volumeattachments")
	// v1.16
	add(9, 16, "extensions/v1beta1", "networking.k8s.io/v1", "", "NetworkPolicy:networkpolicies")
	add(9, 16, "extensions/v1beta1", "policy/v1beta1", "", "PodSecurityPolicy:podsecuritypolicies")
	add(9, 16, "extensions/v1beta1", "apps/v1", "spec.selector is required and immutable",
		"DaemonSet:daemonsets", "Deployment:deployments", "ReplicaSet:replicasets")
	add(9, 16, "apps/v1beta1", "apps/v1", "spec.selector is required and immutable",
		"Deployment:deployments", "StatefulSet:statefulsets", "ReplicaSet:replicasets")
	add(9, 16, "apps/v1beta2", "apps/v1", "spec.selector is required and immutable",
		"DaemonSet:daemonsets", "Deployment:deployments", "StatefulSet:statefulsets", "ReplicaSet:replicasets")
	return out
}()

func splitAPIVersion(apiVersion string) (group, version string) {
	if g, v, ok := strings.Cut(apiVersion, "/"); ok {
		return g, v
	}
	return "", apiVersion
}

// apiChangeKey is "apiVersion|Kind".
func apiChangeKey(apiVersion, kind string) string { return apiVersion + "|" + kind }

var apiChangeIndex = func() map[string]APIChange {
	m := make(map[string]APIChange, len(APIChanges))
	for _, c := range APIChanges {
		m[apiChangeKey(c.APIVersion(), c.Kind)] = c
	}
	return m
}()

// LookupAPI returns the table's entry for apiVersion and kind.
func LookupAPI(apiVersion, kind string) (APIChange, bool) {
	c, ok := apiChangeIndex[apiChangeKey(apiVersion, kind)]
	return c, ok
}

// RemovalsBetween are the entries removed after from, up to and including
// to: what an upgrade from from to to stops serving.
func RemovalsBetween(from, to Version) []APIChange {
	var out []APIChange
	for _, c := range APIChanges {
		if from.Before(c.RemovedIn) && c.RemovedIn.AtMost(to) {
			out = append(out, c)
		}
	}
	return out
}
