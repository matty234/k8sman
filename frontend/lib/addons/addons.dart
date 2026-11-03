/// Add-ons: cluster tools k8sman can use and install with one click (Helm).
///
/// Features that depend on an add-on should call [requestAddon] from their
/// "not installed" state instead of dead-ending, e.g.
/// `TextButton(onPressed: () => requestAddon(context, AddonIds.trivyOperator), child: Text('Install Trivy Operator'))`.
///
/// The catalog is the single source of truth for chart coordinates and
/// sensible defaults. The full Add-ons page (detect / install / upgrade /
/// uninstall via the Helm endpoints) replaces the placeholder dialog below.
library;

import 'package:flutter/material.dart';

abstract final class AddonIds {
  static const metricsServer = 'metrics-server';
  static const prometheus = 'kube-prometheus-stack';
  static const trivyOperator = 'trivy-operator';
  static const argoCd = 'argo-cd';
  static const envoyGateway = 'envoy-gateway';
  static const certManager = 'cert-manager';
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
  ),
];

Addon addonById(String id) => addonCatalog.firstWhere((a) => a.id == id);

/// Hook for features to offer installing a missing add-on. Placeholder
/// until the Add-ons page lands: explains what it is and how to install.
Future<void> requestAddon(BuildContext context, String id) {
  final a = addonById(id);
  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Install ${a.name}?'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(a.enables),
          const SizedBox(height: 8),
          Text(a.description, style: Theme.of(c).textTheme.bodySmall),
          const SizedBox(height: 12),
          SelectableText(
            a.repo.startsWith('oci://')
                ? 'helm install ${a.releaseName} ${a.repo} -n ${a.namespace} --create-namespace'
                : 'helm install ${a.releaseName} ${a.chart} --repo ${a.repo} -n ${a.namespace} --create-namespace',
            style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
    ),
  );
}
