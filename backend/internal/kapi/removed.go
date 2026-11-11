package kapi

// Removal is one apiVersion Kubernetes deprecated and stopped serving, for
// some or all of its kinds.
type Removal struct {
	// DeprecatedIn and RemovedIn are 1.x minor releases (DeprecatedIn 0 =
	// the guide doesn't say). RemovedIn is the first release that no longer
	// serves it.
	DeprecatedIn, RemovedIn int
	APIVersion              string
	// Replacement is the apiVersion to move to ("" = none: the kind is gone).
	Replacement string
	// Note is what else changes with the move (short).
	Note string
	// Kinds are "Kind:resource". Empty for alpha versions, which only the
	// security check's last-applied scan recognises (the upgrade check
	// covers beta and GA APIs).
	Kinds []string
}

// MigrationGuide is the page Removed comes from.
const MigrationGuide = "https://kubernetes.io/docs/reference/using-api/deprecation-guide/"

// Removed is the deprecated API table, from the Kubernetes "Deprecated API
// Migration Guide" (MigrationGuide), covering the removals in 1.16 through
// 1.32, as the guide stood in 2025 (it lists no further removals of beta or
// GA APIs after 1.32). Used by the upgrade readiness check
// (backend/internal/upgrade) and the security "deprecated API" practice
// (backend/internal/security). Add a row when the guide gains a section.
var Removed = []Removal{
	// v1.32
	{29, 32, "flowcontrol.apiserver.k8s.io/v1beta3", "flowcontrol.apiserver.k8s.io/v1", "",
		[]string{"FlowSchema:flowschemas", "PriorityLevelConfiguration:prioritylevelconfigurations"}},
	// v1.29
	{26, 29, "flowcontrol.apiserver.k8s.io/v1beta2", "flowcontrol.apiserver.k8s.io/v1", "",
		[]string{"FlowSchema:flowschemas", "PriorityLevelConfiguration:prioritylevelconfigurations"}},
	// v1.27
	{24, 27, "storage.k8s.io/v1beta1", "storage.k8s.io/v1", "", []string{"CSIStorageCapacity:csistoragecapacities"}},
	// v1.26
	{23, 26, "flowcontrol.apiserver.k8s.io/v1beta1", "flowcontrol.apiserver.k8s.io/v1", "",
		[]string{"FlowSchema:flowschemas", "PriorityLevelConfiguration:prioritylevelconfigurations"}},
	{23, 26, "autoscaling/v2beta2", "autoscaling/v2", "targetAverageUtilization and friends moved under target", []string{"HorizontalPodAutoscaler:horizontalpodautoscalers"}},
	// v1.25
	{21, 25, "batch/v1beta1", "batch/v1", "", []string{"CronJob:cronjobs"}},
	{21, 25, "discovery.k8s.io/v1beta1", "discovery.k8s.io/v1", "topology became zone and hints", []string{"EndpointSlice:endpointslices"}},
	{19, 25, "events.k8s.io/v1beta1", "events.k8s.io/v1", "", []string{"Event:events"}},
	{22, 25, "autoscaling/v2beta1", "autoscaling/v2", "metric targets were restructured", []string{"HorizontalPodAutoscaler:horizontalpodautoscalers"}},
	{21, 25, "policy/v1beta1", "policy/v1", "an empty selector now matches every pod in the namespace", []string{"PodDisruptionBudget:poddisruptionbudgets"}},
	{21, 25, "policy/v1beta1", "", "PodSecurityPolicy is gone: use Pod Security Admission or a policy engine", []string{"PodSecurityPolicy:podsecuritypolicies"}},
	{20, 25, "node.k8s.io/v1beta1", "node.k8s.io/v1", "", []string{"RuntimeClass:runtimeclasses"}},
	// v1.22
	{16, 22, "admissionregistration.k8s.io/v1beta1", "admissionregistration.k8s.io/v1", "failurePolicy now defaults to Fail and sideEffects is required",
		[]string{"MutatingWebhookConfiguration:mutatingwebhookconfigurations", "ValidatingWebhookConfiguration:validatingwebhookconfigurations"}},
	{16, 22, "apiextensions.k8s.io/v1beta1", "apiextensions.k8s.io/v1", "a structural schema is required", []string{"CustomResourceDefinition:customresourcedefinitions"}},
	{19, 22, "apiregistration.k8s.io/v1beta1", "apiregistration.k8s.io/v1", "", []string{"APIService:apiservices"}},
	{19, 22, "authentication.k8s.io/v1beta1", "authentication.k8s.io/v1", "", []string{"TokenReview:tokenreviews"}},
	{19, 22, "authorization.k8s.io/v1beta1", "authorization.k8s.io/v1", "",
		[]string{"SubjectAccessReview:subjectaccessreviews", "LocalSubjectAccessReview:localsubjectaccessreviews", "SelfSubjectAccessReview:selfsubjectaccessreviews"}},
	{19, 22, "certificates.k8s.io/v1beta1", "certificates.k8s.io/v1", "signerName is required", []string{"CertificateSigningRequest:certificatesigningrequests"}},
	{19, 22, "coordination.k8s.io/v1beta1", "coordination.k8s.io/v1", "", []string{"Lease:leases"}},
	{19, 22, "extensions/v1beta1", "networking.k8s.io/v1", "backend.serviceName became backend.service.name; pathType is required", []string{"Ingress:ingresses"}},
	{19, 22, "networking.k8s.io/v1beta1", "networking.k8s.io/v1", "backend.serviceName became backend.service.name; pathType is required",
		[]string{"Ingress:ingresses", "IngressClass:ingressclasses"}},
	{17, 22, "rbac.authorization.k8s.io/v1beta1", "rbac.authorization.k8s.io/v1", "",
		[]string{"ClusterRole:clusterroles", "ClusterRoleBinding:clusterrolebindings", "Role:roles", "RoleBinding:rolebindings"}},
	{14, 22, "scheduling.k8s.io/v1beta1", "scheduling.k8s.io/v1", "", []string{"PriorityClass:priorityclasses"}},
	{19, 22, "storage.k8s.io/v1beta1", "storage.k8s.io/v1", "",
		[]string{"CSIDriver:csidrivers", "CSINode:csinodes", "StorageClass:storageclasses", "VolumeAttachment:volumeattachments"}},
	// v1.16
	{9, 16, "extensions/v1beta1", "networking.k8s.io/v1", "", []string{"NetworkPolicy:networkpolicies"}},
	{9, 16, "extensions/v1beta1", "policy/v1beta1", "", []string{"PodSecurityPolicy:podsecuritypolicies"}},
	{9, 16, "extensions/v1beta1", "apps/v1", "spec.selector is required and immutable",
		[]string{"DaemonSet:daemonsets", "Deployment:deployments", "ReplicaSet:replicasets"}},
	{9, 16, "apps/v1beta1", "apps/v1", "spec.selector is required and immutable",
		[]string{"Deployment:deployments", "StatefulSet:statefulsets", "ReplicaSet:replicasets"}},
	{9, 16, "apps/v1beta2", "apps/v1", "spec.selector is required and immutable",
		[]string{"DaemonSet:daemonsets", "Deployment:deployments", "StatefulSet:statefulsets", "ReplicaSet:replicasets"}},
	// Alpha versions (no kinds: see Kinds).
	{0, 22, "rbac.authorization.k8s.io/v1alpha1", "rbac.authorization.k8s.io/v1", "", nil},
	{0, 21, "batch/v2alpha1", "batch/v1", "", nil},
}
