package icons

import "strings"

// curated maps well-known API group domains to the icon assets bundled with
// the app (frontend/assets/icons/<asset>.png, see ATTRIBUTION.md there). A
// group matches a domain when it equals it or is a subdomain of it. Keep in
// sync with frontend/lib/ui/widgets/group_icon.dart.
var curated = []struct{ domain, asset string }{
	{"argoproj.io", "argo"},
	{"cert-manager.io", "cert-manager"},
	{"monitoring.coreos.com", "prometheus"},
	{"operators.coreos.com", "operatorframework"},
	{"envoyproxy.io", "envoy"},
	{"keda.sh", "keda"},
	{"istio.io", "istio"},
	{"linkerd.io", "linkerd"},
	{"crossplane.io", "crossplane"},
	{"fluxcd.io", "flux"},
	{"cilium.io", "cilium"},
	{"knative.dev", "knative"},
	{"tekton.dev", "tekton"},
	{"kyverno.io", "kyverno"},
	{"gatekeeper.sh", "opa"},
	{"openpolicyagent.org", "opa"},
	{"velero.io", "velero"},
	{"external-secrets.io", "external-secrets"},
	{"kubevirt.io", "kubevirt"},
	{"longhorn.io", "longhorn"},
	{"rook.io", "rook"},
	{"strimzi.io", "strimzi"},
	{"metallb.io", "metallb"},
	{"projectcontour.io", "contour"},
	{"opentelemetry.io", "opentelemetry"},
	{"jaegertracing.io", "jaeger"},
	{"thanos.io", "thanos"},
	{"goharbor.io", "harbor"},
	{"cnpg.io", "cloudnativepg"},
	{"kubeflow.org", "kubeflow"},
	{"dapr.io", "dapr"},
	{"karmada.io", "karmada"},
	{"kruise.io", "openkruise"},
	{"volcano.sh", "volcano"},
	{"aquasecurity.github.io", "trivy"},
	{"k8s.io", "kubernetes"},
	{"x-k8s.io", "kubernetes"},
}

// CuratedAsset returns the bundled asset name for a group, or "".
func CuratedAsset(group string) string {
	for _, c := range curated {
		if group == c.domain || strings.HasSuffix(group, "."+c.domain) {
			return c.asset
		}
	}
	return ""
}
