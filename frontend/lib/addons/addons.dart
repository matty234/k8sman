/// Add-ons: cluster tools k8sman can use and install with one click (Helm).
///
/// Features that depend on an add-on should call [requestAddon] from their
/// "not installed" state instead of dead-ending, e.g.
/// `TextButton(onPressed: () => requestAddon(context, AddonIds.trivyOperator), child: Text('Install Trivy Operator'))`.
///
/// The catalog is the single source of truth for chart coordinates and
/// sensible defaults. The Add-ons page (`lib/ui/addons/`) detects, installs,
/// upgrades and uninstalls them through the Helm endpoints.
library;

import 'package:flutter/widgets.dart';

import '../state/app_state.dart';
import '../ui/addons/addon_install_dialog.dart';

abstract final class AddonIds {
  static const metricsServer = 'metrics-server';
  static const prometheus = 'kube-prometheus-stack';
  static const trivyOperator = 'trivy-operator';
  static const argoCd = 'argo-cd';
  static const envoyGateway = 'envoy-gateway';
  static const certManager = 'cert-manager';
}

/// Somewhere in k8sman an add-on lights up: a main page ([view]) or a
/// resource kind ([group] + [kind]) in the resource table.
class AddonLink {
  final String label;
  final MainView? view;
  final String group;
  final String kind;
  const AddonLink.page(this.label, MainView this.view)
      : group = '',
        kind = '';
  const AddonLink.kind(this.label, this.group, this.kind) : view = null;
}

class Addon {
  final String id;
  final String name;

  /// What it unlocks in k8sman, in one line.
  final String enables;
  final String description;

  /// Helm repo URL (https) or OCI reference (`oci://…`) for [chart].
  final String repo;
  final String chart;

  /// Pinned chart version; null = latest at install time.
  final String? version;
  final String namespace;
  final String releaseName;

  /// Default values (YAML) tuned for local/dev clusters.
  final String values;

  /// Detection: any of these CRDs present (`plural.group`) …
  final List<String> detectCrds;

  /// … or any of these Deployments exist (`namespace/name`).
  final List<String> detectDeployments;

  /// Where it shows up in k8sman.
  final List<AddonLink> links;

  /// Shown after a successful install: what happens next and where to look.
  final String nextSteps;

  /// Cluster-wide objects the chart creates (CRDs, webhooks, …), for the
  /// install confirmation. Empty = none worth calling out.
  final String clusterWide;

  /// Extra uninstall warning (data loss, CRDs left behind, …).
  final String uninstallNote;

  /// Kubernetes version caveats, shown when an install fails.
  final String compatibility;

  const Addon({
    required this.id,
    required this.name,
    required this.enables,
    required this.description,
    required this.repo,
    required this.chart,
    this.version,
    required this.namespace,
    required this.releaseName,
    this.values = '',
    this.detectCrds = const [],
    this.detectDeployments = const [],
    this.links = const [],
    this.nextSteps = '',
    this.clusterWide = '',
    this.uninstallNote = '',
    this.compatibility = '',
  });
}

const addonCatalog = <Addon>[
  Addon(
    id: AddonIds.metricsServer,
    name: 'metrics-server',
    enables: 'Live CPU and memory usage for nodes and pods',
    description: 'Resource metrics API (metrics.k8s.io) used by kubectl top and HPAs.',
    repo: 'https://kubernetes-sigs.github.io/metrics-server/',
    chart: 'metrics-server',
    namespace: 'kube-system',
    releaseName: 'metrics-server',
    // Local clusters (kind, k3d, Docker Desktop) use self-signed kubelet certs.
    values: 'args:\n  - --kubelet-insecure-tls\n',
    detectDeployments: ['kube-system/metrics-server'],
    links: [AddonLink.page('Nodes', MainView.nodes), AddonLink.page('Metrics', MainView.metrics)],
    nextSteps: 'Usage appears within a minute, once the first scrape completes. See Nodes and Metrics.',
    clusterWide: 'an APIService (v1beta1.metrics.k8s.io) and ClusterRoles',
    uninstallNote: 'kubectl top and HorizontalPodAutoscalers on CPU or memory stop working.',
  ),
  Addon(
    id: AddonIds.prometheus,
    name: 'Prometheus stack',
    enables: 'Metrics history, alerts and dashboards',
    description: 'kube-prometheus-stack: Prometheus, Alertmanager, Grafana and exporters.',
    repo: 'https://prometheus-community.github.io/helm-charts',
    chart: 'kube-prometheus-stack',
    version: '92.17.1',
    namespace: 'monitoring',
    releaseName: 'kube-prometheus-stack',
    // Without the *NilUsesHelmValues=false selectors, Prometheus ignores
    // rules/monitors that weren't created by this release.
    values: 'grafana:\n  enabled: true\nalertmanager:\n  enabled: true\nprometheus:\n  prometheusSpec:\n'
        '    ruleSelectorNilUsesHelmValues: false\n    serviceMonitorSelectorNilUsesHelmValues: false\n'
        '    podMonitorSelectorNilUsesHelmValues: false\n    probeSelectorNilUsesHelmValues: false\n',
    detectCrds: ['prometheuses.monitoring.coreos.com'],
    links: [AddonLink.page('Alerts', MainView.alerts), AddonLink.page('Metrics', MainView.metrics)],
    nextSteps: 'Prometheus starts scraping within a couple of minutes; history charts fill in from then on. See Alerts for firing rules.',
    clusterWide: 'the monitoring.coreos.com CRDs, an admission webhook and ClusterRoles',
    uninstallNote: 'All stored metrics and Alertmanager silences are lost. The monitoring.coreos.com CRDs stay (Helm never deletes CRDs), '
        'so ServiceMonitors and PrometheusRules elsewhere are kept.',
  ),
  Addon(
    id: AddonIds.trivyOperator,
    name: 'Trivy Operator',
    enables: 'Image vulnerability and config-audit reports on the Security page',
    description: 'Continuously scans workloads and writes VulnerabilityReports as CRDs.',
    repo: 'https://aquasecurity.github.io/helm-charts/',
    chart: 'trivy-operator',
    version: '0.38.1',
    namespace: 'trivy-system',
    releaseName: 'trivy-operator',
    detectCrds: ['vulnerabilityreports.aquasecurity.github.io'],
    links: [AddonLink.page('Security', MainView.security)],
    nextSteps: 'Scans start within minutes, one workload at a time; see Security → Images as reports arrive.',
    clusterWide: 'the aquasecurity.github.io CRDs and ClusterRoles',
    uninstallNote: 'Scanning stops. The report CRDs stay (Helm never deletes CRDs), so existing reports remain until you delete them.',
  ),
  Addon(
    id: AddonIds.argoCd,
    name: 'Argo CD',
    enables: 'GitOps applications with sync and health',
    description: 'Declarative GitOps continuous delivery.',
    repo: 'https://argoproj.github.io/argo-helm',
    chart: 'argo-cd',
    namespace: 'argocd',
    releaseName: 'argocd',
    detectCrds: ['applications.argoproj.io'],
    detectDeployments: ['argocd/argocd-server'],
    links: [AddonLink.kind('Applications', 'argoproj.io', 'Application'), AddonLink.page('Overview', MainView.overview)],
    nextSteps: 'Create an Application to start syncing; it shows up under Argo CD → Applications.',
    clusterWide: 'the argoproj.io CRDs and ClusterRoles',
    uninstallNote: 'The chart keeps its CRDs by default, so Applications stay but nothing reconciles them; '
        'the workloads they deployed keep running.',
  ),
  Addon(
    id: AddonIds.envoyGateway,
    name: 'Envoy Gateway',
    enables: 'A Gateway API implementation (Gateways, HTTPRoutes)',
    description: 'Envoy-based Gateway API controller, including the Gateway API CRDs.',
    repo: 'oci://docker.io/envoyproxy/gateway-helm',
    chart: 'gateway-helm',
    // v1.2.x supports Kubernetes 1.25+; newer charts need 1.30+.
    version: 'v1.2.8',
    namespace: 'envoy-gateway-system',
    releaseName: 'eg',
    detectDeployments: ['envoy-gateway-system/envoy-gateway'],
    links: [AddonLink.kind('Gateways', 'gateway.networking.k8s.io', 'Gateway'), AddonLink.kind('HTTPRoutes', 'gateway.networking.k8s.io', 'HTTPRoute')],
    nextSteps: 'Create a GatewayClass with controllerName gateway.envoyproxy.io/gatewayclass-controller, then a Gateway and HTTPRoutes.',
    clusterWide: 'the Gateway API and gateway.envoyproxy.io CRDs and ClusterRoles',
    uninstallNote: 'Gateways stop serving traffic. The Gateway API CRDs stay (Helm never deletes CRDs).',
    compatibility: 'Envoy Gateway v1.3 and newer need Kubernetes 1.30+; k8sman pins v1.2.8, which supports 1.25+.',
  ),
  Addon(
    id: AddonIds.certManager,
    name: 'cert-manager',
    enables: 'Automatic TLS certificates for Ingresses and Gateways',
    description: 'X.509 certificate management for Kubernetes.',
    repo: 'https://charts.jetstack.io',
    chart: 'cert-manager',
    namespace: 'cert-manager',
    releaseName: 'cert-manager',
    values: 'crds:\n  enabled: true\n',
    detectCrds: ['certificates.cert-manager.io'],
    detectDeployments: ['cert-manager/cert-manager'],
    links: [AddonLink.kind('Certificates', 'cert-manager.io', 'Certificate'), AddonLink.kind('Issuers', 'cert-manager.io', 'ClusterIssuer')],
    nextSteps: 'Create a ClusterIssuer (for example a self-signed one for local clusters), then Certificates or annotated Ingresses.',
    clusterWide: 'the cert-manager.io CRDs, validating and mutating webhooks and ClusterRoles',
    uninstallNote: 'With crds.enabled the chart keeps its CRDs (crds.keep), so Certificates and Issuers stay but are no longer renewed. '
        'Issued certificate Secrets are kept.',
  ),
];

Addon addonById(String id) => addonCatalog.firstWhere((a) => a.id == id);

/// Hook for features to offer installing a missing add-on: opens the
/// Add-ons install dialog for [id] on the current context (or explains why
/// it can't, in read-only mode).
Future<void> requestAddon(BuildContext context, String id) => showAddonInstallDialog(context, addonById(id));
