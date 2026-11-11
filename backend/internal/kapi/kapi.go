// Package kapi is the registry of the Kubernetes API groups, versions and
// resources k8sman requests by name, and of the API versions Kubernetes has
// deprecated or removed (removed.go).
//
// To bump an API version, edit the entry here: Versions is a preference
// order, newest first. Groups resolved through discovery (Group.Served, the
// metrics APIs) use the first version the cluster serves; the rest request
// Versions[0]. Kinds the app finds by group and resource
// (cluster.Clients.Find with no version) already follow the server's
// preferred version and aren't listed.
//
// Plugin manifests (k8sman.dev/v1) and bundled plugin.yaml files carry
// their own versions and aren't covered here. The frontend's counterpart
// is frontend/lib/api/known_apis.dart.
package kapi

import (
	"net/url"

	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
)

// Group is an API group with its versions, newest first.
type Group struct {
	Name     string // "" for the core group
	Versions []string
}

// API is one resource of a group, with its versions, newest first.
type API struct {
	Group    string // "" for the core group
	Resource string // plural, as served
	Kind     string
	Versions []string
}

func (g Group) api(resource, kind string) API {
	return API{Group: g.Name, Resource: resource, Kind: kind, Versions: g.Versions}
}

var (
	core            = Group{"", []string{"v1"}}
	apps            = Group{"apps", []string{"v1"}}
	batch           = Group{"batch", []string{"v1"}}
	networking      = Group{"networking.k8s.io", []string{"v1"}}
	rbac            = Group{"rbac.authorization.k8s.io", []string{"v1"}}
	policy          = Group{"policy", []string{"v1"}}
	admission       = Group{"admissionregistration.k8s.io", []string{"v1"}}
	discoveryGroup  = Group{"discovery.k8s.io", []string{"v1"}}
	autoscaling     = Group{"autoscaling", []string{"v2"}}
	apiextensions   = Group{"apiextensions.k8s.io", []string{"v1"}}
	apiregistration = Group{"apiregistration.k8s.io", []string{"v1"}}
	monitoring      = Group{"monitoring.coreos.com", []string{"v1"}}
	monitoringAlpha = Group{"monitoring.coreos.com", []string{"v1alpha1"}}
)

// Groups resolved per cluster (through discovery, or the metrics
// APIServices): the first version served wins.
var (
	ResourceMetrics = Group{"metrics.k8s.io", []string{"v1", "v1beta1"}}
	CustomMetrics   = Group{"custom.metrics.k8s.io", []string{"v1beta2", "v1beta1"}}
	ExternalMetrics = Group{"external.metrics.k8s.io", []string{"v1beta1"}}
	GatewayAPI      = Group{"gateway.networking.k8s.io", []string{"v1", "v1beta1"}}
	// Trivy is the Trivy Operator's report CRDs.
	Trivy = Group{"aquasecurity.github.io", []string{"v1alpha1"}}
)

// Built-in kinds.
var (
	Pods                   = core.api("pods", "Pod")
	Nodes                  = core.api("nodes", "Node")
	Namespaces             = core.api("namespaces", "Namespace")
	PersistentVolumes      = core.api("persistentvolumes", "PersistentVolume")
	PersistentVolumeClaims = core.api("persistentvolumeclaims", "PersistentVolumeClaim")
	Events                 = core.api("events", "Event")
	Services               = core.api("services", "Service")
	ServiceAccounts        = core.api("serviceaccounts", "ServiceAccount")
	ConfigMaps             = core.api("configmaps", "ConfigMap")
	Secrets                = core.api("secrets", "Secret")

	Deployments         = apps.api("deployments", "Deployment")
	StatefulSets        = apps.api("statefulsets", "StatefulSet")
	DaemonSets          = apps.api("daemonsets", "DaemonSet")
	ReplicaSets         = apps.api("replicasets", "ReplicaSet")
	ControllerRevisions = apps.api("controllerrevisions", "ControllerRevision")

	Jobs     = batch.api("jobs", "Job")
	CronJobs = batch.api("cronjobs", "CronJob")

	Ingresses       = networking.api("ingresses", "Ingress")
	NetworkPolicies = networking.api("networkpolicies", "NetworkPolicy")
	EndpointSlices  = discoveryGroup.api("endpointslices", "EndpointSlice")

	Roles               = rbac.api("roles", "Role")
	RoleBindings        = rbac.api("rolebindings", "RoleBinding")
	ClusterRoles        = rbac.api("clusterroles", "ClusterRole")
	ClusterRoleBindings = rbac.api("clusterrolebindings", "ClusterRoleBinding")

	PodDisruptionBudgets            = policy.api("poddisruptionbudgets", "PodDisruptionBudget")
	ValidatingWebhookConfigurations = admission.api("validatingwebhookconfigurations", "ValidatingWebhookConfiguration")
	MutatingWebhookConfigurations   = admission.api("mutatingwebhookconfigurations", "MutatingWebhookConfiguration")

	// HorizontalPodAutoscalers: backend/internal/metrics/hpa.go decodes
	// this version's shape, so bump them together.
	HorizontalPodAutoscalers  = autoscaling.api("horizontalpodautoscalers", "HorizontalPodAutoscaler")
	CustomResourceDefinitions = apiextensions.api("customresourcedefinitions", "CustomResourceDefinition")
	APIServices               = apiregistration.api("apiservices", "APIService")
)

// prometheus-operator kinds.
var (
	Prometheuses        = monitoring.api("prometheuses", "Prometheus")
	Alertmanagers       = monitoring.api("alertmanagers", "Alertmanager")
	PrometheusRules     = monitoring.api("prometheusrules", "PrometheusRule")
	ServiceMonitors     = monitoring.api("servicemonitors", "ServiceMonitor")
	PodMonitors         = monitoring.api("podmonitors", "PodMonitor")
	Probes              = monitoring.api("probes", "Probe")
	ScrapeConfigs       = monitoringAlpha.api("scrapeconfigs", "ScrapeConfig")
	AlertmanagerConfigs = monitoringAlpha.api("alertmanagerconfigs", "AlertmanagerConfig")
)

// Version is the version requested: the first preference.
func (a API) Version() string { return a.Versions[0] }

// GVR is the resource at Version.
func (a API) GVR() schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: a.Group, Version: a.Version(), Resource: a.Resource}
}

// APIVersion is "group/version" at Version ("version" for the core group).
func (a API) APIVersion() string {
	return Group{Name: a.Group}.GroupVersion(a.Version())
}

// Path is the REST path of the resource at Version: the collection across
// namespaces (namespace ""), in a namespace, or one object (name set).
func (a API) Path(namespace, name string) string {
	p := "/api/" + a.Version()
	if a.Group != "" {
		p = "/apis/" + a.Group + "/" + a.Version()
	}
	if namespace != "" {
		p += "/namespaces/" + url.PathEscape(namespace)
	}
	p += "/" + a.Resource
	if name != "" {
		p += "/" + url.PathEscape(name)
	}
	return p
}

// GroupVersion is "group/version" for version v ("v" for the core group).
func (g Group) GroupVersion(v string) string {
	if g.Name == "" {
		return v
	}
	return g.Name + "/" + v
}

// GVR is resource at version v of the group.
func (g Group) GVR(v, resource string) schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: g.Name, Version: v, Resource: resource}
}

// Pick returns the first of versions (a preference order) that served
// reports true for, or "" when none is.
func Pick(versions []string, served func(version string) bool) string {
	for _, v := range versions {
		if served(v) {
			return v
		}
	}
	return ""
}

// Served resolves the group's version through discovery: the first
// preferred version the server serves, with the resources served there;
// "" and nil when none is. Pass the context's cached discovery client
// (cluster.Clients.Discovery): once discovery is warm this costs no round
// trip, and a context switch brings a new cache.
func (g Group) Served(d discovery.DiscoveryInterface) (string, map[string]bool) {
	var res map[string]bool
	v := Pick(g.Versions, func(v string) bool {
		l, err := d.ServerResourcesForGroupVersion(g.GroupVersion(v))
		if err != nil || l == nil {
			return false
		}
		res = make(map[string]bool, len(l.APIResources))
		for _, r := range l.APIResources {
			res[r.Name] = true
		}
		return true
	})
	if v == "" {
		return "", nil
	}
	return v, res
}
