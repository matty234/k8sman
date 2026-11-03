/// Detecting catalog add-ons on the cluster: served CRDs, known Deployments
/// and Helm releases (matched by chart name), plus health and upgrades.
library;

import '../api/client.dart';
import '../api/models.dart';
import '../ui/helm/helm_api.dart';
import '../util/k8s.dart';
import 'addons.dart';

enum AddonState {
  notInstalled,

  /// A Helm release of the chart, deployed and healthy.
  installed,

  /// Present (CRDs or Deployments) but not from a Helm release, e.g.
  /// applied from upstream manifests. k8sman can't upgrade or remove it.
  external,

  /// Release failed or pending, or a key Deployment has nothing available.
  unhealthy,
}

/// Availability of one Deployment that belongs to the add-on.
class DeploymentHealth {
  final String namespace, name;
  final int desired, available;
  const DeploymentHealth({required this.namespace, required this.name, required this.desired, required this.available});

  factory DeploymentHealth.fromJson(Json d) => DeploymentHealth(
        namespace: dig<String>(d, ['metadata', 'namespace']) ?? '',
        name: dig<String>(d, ['metadata', 'name']) ?? '',
        desired: (dig<num>(d, ['spec', 'replicas']) ?? 1).toInt(),
        available: (dig<num>(d, ['status', 'availableReplicas']) ?? 0).toInt(),
      );

  bool get healthy => desired == 0 || available >= 1;
}

class AddonStatus {
  final Addon addon;
  final AddonState state;

  /// The matching Helm release, if any.
  final HelmRelease? release;
  final List<DeploymentHealth> deployments;

  /// Detected through a served CRD.
  final bool crdServed;

  /// Upgrade target: the catalog's pinned version, else the latest stable
  /// chart version (null until chart versions are known).
  final String? targetVersion;

  const AddonStatus({
    required this.addon,
    required this.state,
    this.release,
    this.deployments = const [],
    this.crdServed = false,
    this.targetVersion,
  });

  bool get installed => state != AddonState.notInstalled;
  bool get viaHelm => release != null;

  /// Installed under a release name or namespace other than the catalog's.
  bool get customRelease => release != null && (release!.name != addon.releaseName || release!.namespace != addon.namespace);

  bool get upgradeAvailable {
    final r = release, t = targetVersion;
    return r != null && t != null && r.chartVersion.isNotEmpty && compareChartVersions(t, r.chartVersion) > 0;
  }

  List<DeploymentHealth> get unavailable => [for (final d in deployments) if (!d.healthy) d];

  /// One line on what's wrong, for unhealthy add-ons.
  String get problem {
    final r = release;
    if (r != null && r.failed) return 'Helm release ${r.name} failed';
    if (r != null && r.pending) return 'Helm release ${r.name} is ${r.status}';
    final u = unavailable;
    if (u.isEmpty) return '';
    return u.length == 1 ? '${u.first.name} has no available replicas' : '${u.length} deployments have no available replicas';
  }

  AddonStatus withTarget(String? v) =>
      AddonStatus(addon: addon, state: state, release: release, deployments: deployments, crdServed: crdServed, targetVersion: v);
}

/// Pure detection from already-fetched data (see [scanAddons]).
/// [servedCrds] holds `plural.group` keys; [deployments] are raw objects
/// from the namespaces returned by [addonNamespaces].
AddonStatus detectAddon(Addon a, {required Set<String> servedCrds, required List<HelmRelease> releases, required List<Json> deployments, String? latest}) {
  final release = matchRelease(a, releases);
  final crd = a.detectCrds.any(servedCrds.contains);
  String key(Json d) => '${dig<String>(d, ['metadata', 'namespace'])}/${dig<String>(d, ['metadata', 'name'])}';
  final named = [for (final d in deployments) if (a.detectDeployments.contains(key(d))) d];

  List<Json> owned;
  if (release != null) {
    // Everything the release runs (charts label with instance; Helm annotates).
    owned = [
      for (final d in deployments)
        if (dig<String>(d, ['metadata', 'namespace']) == release.namespace &&
            (dig<String>(d, ['metadata', 'labels', 'app.kubernetes.io/instance']) == release.name ||
                dig<String>(d, ['metadata', 'annotations', 'meta.helm.sh/release-name']) == release.name))
          d,
    ];
  } else if (named.isNotEmpty || crd) {
    // Installed some other way: its namespace's Deployments, if it's in ours.
    owned = [
      ...named,
      for (final d in deployments)
        if (dig<String>(d, ['metadata', 'namespace']) == a.namespace && a.namespace != 'kube-system' && !named.contains(d)) d,
    ];
  } else {
    owned = const [];
  }
  final health = [for (final d in owned) DeploymentHealth.fromJson(d)]..sort((x, y) => x.name.compareTo(y.name));
  final installed = release != null || crd || named.isNotEmpty;
  final unhealthy = (release != null && release.problem) || health.any((d) => !d.healthy);
  final state = !installed
      ? AddonState.notInstalled
      : unhealthy
          ? AddonState.unhealthy
          : release == null
              ? AddonState.external
              : AddonState.installed;
  return AddonStatus(addon: a, state: state, release: release, deployments: health, crdServed: crd, targetVersion: a.version ?? latest);
}

/// The release of [a]'s chart: the catalog name/namespace if present, else
/// any other release of the same chart. Uninstalled (kept history) ones don't count.
HelmRelease? matchRelease(Addon a, List<HelmRelease> releases) {
  final rs = [for (final r in releases) if (r.chart == a.chart && r.status != 'uninstalled') r];
  if (rs.isEmpty) return null;
  return rs.firstWhere((r) => r.name == a.releaseName && r.namespace == a.namespace, orElse: () => rs.first);
}

/// Namespaces whose Deployments detection needs.
Set<String> addonNamespaces(Iterable<Addon> addons, List<HelmRelease> releases) => {
      for (final a in addons) ...[
        a.namespace,
        for (final d in a.detectDeployments) d.split('/').first,
        if (matchRelease(a, releases) case final r?) r.namespace,
      ],
    };

/// Served CRD keys (`plural.group`) from discovered types.
Set<String> servedCrdKeys(Iterable<ResourceType> types) => {for (final t in types) if (t.group.isNotEmpty) '${t.resource}.${t.group}'};

/// Fetches releases and Deployments in parallel and detects every add-on.
/// [types] are the discovered API resources (CRDs are served types).
Future<List<AddonStatus>> scanAddons(ApiClient api, HelmApi helm, List<ResourceType> types, {List<Addon> addons = addonCatalog}) async {
  final releases = (await helm.releases()).releases;
  final namespaces = addonNamespaces(addons, releases).toList();
  final lists = await Future.wait([
    for (final ns in namespaces)
      api.items(const ResourceRef(group: 'apps', resource: 'deployments'), namespace: ns).catchError((Object _) => <Json>[]),
  ]);
  final deployments = [for (final l in lists) ...l];
  final crds = servedCrdKeys(types);
  return [for (final a in addons) detectAddon(a, servedCrds: crds, releases: releases, deployments: deployments)];
}

/// Newest non-prerelease, non-deprecated version (the list is newest first).
String? latestStable(List<HelmChartVersion> versions) {
  for (final v in versions) {
    if (!v.prerelease && !v.deprecated && !v.version.contains('-')) return v.version;
  }
  return versions.isEmpty ? null : versions.first.version;
}

/// Semver-ish comparison that ignores a leading "v"; pre-releases sort
/// before their release. Returns <0, 0 or >0.
int compareChartVersions(String a, String b) {
  (List<int>, String) parse(String v) {
    v = v.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    final plus = v.indexOf('+');
    if (plus >= 0) v = v.substring(0, plus);
    final dash = v.indexOf('-');
    final pre = dash >= 0 ? v.substring(dash + 1) : '';
    final core = dash >= 0 ? v.substring(0, dash) : v;
    return ([for (final p in core.split('.')) int.tryParse(p) ?? 0], pre);
  }

  final (ca, pa) = parse(a), (cb, pb) = parse(b);
  for (var i = 0; i < 3; i++) {
    final x = i < ca.length ? ca[i] : 0, y = i < cb.length ? cb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  if (pa.isEmpty != pb.isEmpty) return pa.isEmpty ? 1 : -1;
  return pa.compareTo(pb);
}

/// Same version, ignoring a leading "v".
bool sameChartVersion(String a, String b) => compareChartVersions(a, b) == 0;

/// Rendered objects by kind (for dry-run summaries), most frequent first.
List<(String, int)> manifestKinds(String manifest) {
  final counts = <String, int>{};
  final kindLine = RegExp(r'^kind:\s*["]?([A-Za-z0-9]+)', multiLine: true);
  for (final doc in manifest.split(RegExp(r'^---\s*$', multiLine: true))) {
    final m = kindLine.firstMatch(doc);
    if (m != null) counts.update(m.group(1)!, (n) => n + 1, ifAbsent: () => 1);
  }
  final out = [for (final e in counts.entries) (e.key, e.value)];
  out.sort((x, y) => x.$2 != y.$2 ? y.$2.compareTo(x.$2) : x.$1.compareTo(y.$1));
  return out;
}

/// Kinds that are cluster-scoped and worth calling out before installing.
const clusterWideKinds = {
  'CustomResourceDefinition',
  'ValidatingWebhookConfiguration',
  'MutatingWebhookConfiguration',
  'APIService',
  'ClusterRole',
  'ClusterRoleBinding',
  'GatewayClass',
  'IngressClass',
  'PriorityClass',
  'StorageClass',
};
