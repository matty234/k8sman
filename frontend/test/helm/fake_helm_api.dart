import 'dart:convert';
import 'dart:io';

import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/helm/helm_api.dart';

import '../support/harness.dart';

Json fx(String name) => Map<String, dynamic>.from(jsonDecode(File('test/helm/fixtures/$name').readAsStringSync()) as Map);

/// Serves responses captured from a live backend (test/helm/fixtures) and
/// records mutations.
class FakeHelmApi extends HelmApi {
  final calls = <String>[];
  FakeHelmApi() : super(FakeApiClient());

  static const _details = {'helm-demo/web': 'release-web.json', 'helm-demo/api': 'release-api.json', 'helm-tools/worker': 'release-worker.json'};
  static const _histories = {'helm-demo/web': 'history-web.json', 'helm-demo/api': 'history-api.json', 'helm-tools/worker': 'history-worker.json'};

  @override
  Future<HelmReleaseList> releases({String? namespace}) async {
    final l = HelmReleaseList.fromJson(fx('releases.json'));
    if (namespace == null) return l;
    final rs = l.releases.where((r) => r.namespace == namespace).toList();
    return HelmReleaseList(rs, failed: rs.where((r) => r.failed).length, pending: rs.where((r) => r.pending).length);
  }

  @override
  Future<HelmReleaseDetail> release(String namespace, String name, {int? revision}) async {
    final f = _details['$namespace/$name'];
    if (f == null) throw ApiException(404, 'release "$name" was not captured');
    return HelmReleaseDetail.fromJson(fx(f));
  }

  @override
  Future<List<HelmRelease>> history(String namespace, String name) async {
    final f = _histories['$namespace/$name'] ?? 'history-web.json';
    return [for (final r in fx(f)['history'] as List) HelmRelease.fromJson(Map<String, dynamic>.from(r))];
  }

  @override
  Future<HelmDiff> diff(String namespace, String name, {required int from, int? to}) async {
    calls.add('diff $namespace/$name $from→$to');
    return HelmDiff.fromJson(fx('diff-web-3-5.json'));
  }

  @override
  Future<HelmResult> upgrade(String namespace, String name, String values, {bool reuseValues = false, bool dryRun = false}) async {
    calls.add('upgrade $namespace/$name dryRun=$dryRun');
    if (name == 'worker') throw ApiException(409, '${fx('upgrade-stuck-worker.json')['error']}', reason: 'ReleasePending');
    return dryRun ? HelmResult.fromJson(fx('upgrade-dryrun-api.json')) : HelmResult(message: 'Upgraded $name to revision 3 (deployed)');
  }

  @override
  Future<HelmResult> rollback(String namespace, String name, int revision, {bool dryRun = false, bool wait = false, int? timeoutSeconds}) async {
    calls.add('rollback $namespace/$name $revision');
    return HelmResult(message: 'Rolled back $name to revision $revision');
  }

  @override
  Future<HelmResult> uninstall(String namespace, String name, {bool keepHistory = false, bool dryRun = false}) async {
    calls.add('uninstall $namespace/$name keepHistory=$keepHistory');
    return HelmResult(message: 'Uninstalled $name');
  }
}
