import 'dart:convert';
import 'dart:io';

import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/helm/helm_api.dart';

import '../support/harness.dart';

/// Fixtures captured from the dev kind cluster through `/api/*`:
/// `fixtures/` (cert-manager not installed), `fixtures/with-cert-manager/`
/// (right after a real install) and `fixtures/after-uninstall/` (its CRDs left).
const fixtureDir = 'test/addons/fixtures';

dynamic readFixture(String path) => jsonDecode(File('$fixtureDir/$path').readAsStringSync());

List<ResourceType> fixtureTypes([String dir = '']) =>
    [for (final r in readFixture('${dir}resources.json') as List) ResourceType.fromJson(Map<String, dynamic>.from(r))];

List<Json> fixtureDeployments([String dir = '']) =>
    [for (final d in (readFixture('${dir}deployments.json') as Map)['items'] as List) Map<String, dynamic>.from(d)];

List<HelmRelease> fixtureReleases([String dir = '']) => HelmReleaseList.fromJson(Map<String, dynamic>.from(readFixture('${dir}releases.json'))).releases;

class AddonsApiClient extends FakeApiClient {
  final List<ResourceType> types;
  AddonsApiClient({List<Json>? deployments, List<ResourceType>? types})
      : types = types ?? fixtureTypes(),
        super(itemsByResource: {
          'deployments.apps': deployments ?? fixtureDeployments(),
          'nodes': [jsonDecode(File('../dev/fixtures/node-k8sman-dev-control-plane.json').readAsStringSync())],
        });

  @override
  Future<List<ResourceType>> resources({bool refresh = false}) async => types;
}

/// Serves the captured Helm responses and records mutations.
class FakeAddonHelmApi extends HelmApi {
  final calls = <String>[];
  final List<HelmRelease> releaseList;

  /// Error thrown by a real (non-dry-run) install.
  String? installError;

  FakeAddonHelmApi({List<HelmRelease>? releases})
      : releaseList = releases ?? fixtureReleases(),
        super(FakeApiClient());

  @override
  Future<HelmReleaseList> releases({String? namespace}) async => HelmReleaseList(releaseList);

  @override
  Future<List<HelmChartVersion>> chartVersions(String repo, String chart) async {
    calls.add('chart-versions $chart');
    final f = File('$fixtureDir/chart-versions-$chart.json');
    if (f.existsSync()) {
      return [for (final v in (jsonDecode(f.readAsStringSync()) as Map)['versions'] as List) HelmChartVersion.fromJson(Map<String, dynamic>.from(v))];
    }
    if (chart == 'metrics-server') return const [HelmChartVersion(version: '3.15.0'), HelmChartVersion(version: '3.14.0')];
    return const [HelmChartVersion(version: '9.1.0')];
  }

  @override
  Future<HelmReleaseDetail> release(String namespace, String name, {int? revision}) async =>
      HelmReleaseDetail(release: releaseList.firstWhere((r) => r.name == name && r.namespace == namespace), latestRevision: 1, values: 'args:\n  - --kubelet-insecure-tls\n');

  @override
  Future<HelmResult> install({
    required String namespace,
    required String releaseName,
    required String repo,
    required String chart,
    String? version,
    String values = '',
    bool createNamespace = true,
    bool wait = false,
    int? timeoutSeconds,
    bool dryRun = false,
  }) async {
    calls.add('install $namespace/$releaseName $chart@$version dryRun=$dryRun wait=$wait timeout=$timeoutSeconds');
    if (dryRun) return HelmResult.fromJson(Map<String, dynamic>.from(readFixture('install-dryrun-cert-manager.json')));
    if (installError != null) throw ApiException(500, installError!);
    return HelmResult(
      message: 'Installed $chart $version as $releaseName in $namespace (deployed)',
      notes: '$chart $version has been deployed successfully!',
    );
  }

  @override
  Future<HelmResult> upgradeChart(String namespace, String name,
      {required String repo, required String chart, String? version, String values = '', bool wait = false, int? timeoutSeconds, bool dryRun = false}) async {
    calls.add('upgrade $namespace/$name $chart@$version dryRun=$dryRun wait=$wait');
    return HelmResult(
      message: dryRun ? 'Dry run' : 'Upgraded $name to revision 2 (deployed)',
      manifest: 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: $name\n# $version\n',
      currentManifest: 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: $name\n',
    );
  }

  @override
  Future<HelmResult> uninstall(String namespace, String name, {bool keepHistory = false, bool dryRun = false}) async {
    calls.add('uninstall $namespace/$name');
    return HelmResult(message: 'Uninstalled $name');
  }
}
