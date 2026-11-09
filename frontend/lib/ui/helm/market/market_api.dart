/// Client and models for the Helm charts browser: the user's repositories
/// (`/api/helm/repos*`), Artifact Hub (`/api/helm/artifacthub/*`, opt-in)
/// and "upgrade available" lookups (`/api/helm/updates`). See API.md.
library;

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../../api/backend_http.dart';
import '../../../api/client.dart';
import '../../../api/models.dart' show Json;
import '../../../util/json.dart';
import '../helm_api.dart';

/// A configured repository (`helm repo list`). Credentials never reach the UI.
class HelmRepo {
  final String name, url;
  final DateTime? updated;
  final int? charts;
  final bool hasCredentials;
  const HelmRepo({required this.name, required this.url, this.updated, this.charts, this.hasCredentials = false});
  factory HelmRepo.fromJson(Json j) => HelmRepo(
        name: asStr(j['name']),
        url: asStr(j['url']),
        updated: DateTime.tryParse(asStr(j['updated'])),
        charts: j['charts'] == null ? null : asInt(j['charts']),
        hasCredentials: j['hasCredentials'] == true,
      );
}

class HelmRepoList {
  final List<HelmRepo> repositories;
  final String configPath, cachePath, registryConfig;
  final List<String> registries;
  const HelmRepoList(this.repositories, {this.configPath = '', this.cachePath = '', this.registryConfig = '', this.registries = const []});
  factory HelmRepoList.fromJson(Json j) => HelmRepoList(
        [for (final r in (j['repositories'] as List? ?? const [])) HelmRepo.fromJson(Map<String, dynamic>.from(r))],
        configPath: asStr(j['configPath']),
        cachePath: asStr(j['cachePath']),
        registryConfig: asStr(j['registryConfig']),
        registries: [for (final r in (j['registries'] as List? ?? const [])) asStr((r as Map)['host'])],
      );
}

/// Where a chart is browsed from.
enum ChartSource { repo, artifactHub }

/// One chart in a listing: a repository's latest version, or an Artifact
/// Hub search result.
class ChartSummary {
  final ChartSource source;
  final String repo, repoDisplay, repoURL, name, version, appVersion, description, icon, publisher, packageId;
  final List<String> keywords;
  final bool deprecated, official, verified;
  final int stars;
  const ChartSummary({
    required this.source,
    required this.repo,
    required this.name,
    this.repoDisplay = '',
    this.repoURL = '',
    this.version = '',
    this.appVersion = '',
    this.description = '',
    this.icon = '',
    this.publisher = '',
    this.packageId = '',
    this.keywords = const [],
    this.deprecated = false,
    this.official = false,
    this.verified = false,
    this.stars = 0,
  });

  factory ChartSummary.fromRepoJson(Json j) => ChartSummary(
        source: ChartSource.repo,
        repo: asStr(j['repo']),
        repoURL: asStr(j['repoURL']),
        name: asStr(j['name']),
        version: asStr(j['version']),
        appVersion: asStr(j['appVersion']),
        description: asStr(j['description']),
        icon: asStr(j['icon']),
        keywords: asStrings(j['keywords']),
        deprecated: j['deprecated'] == true,
      );

  factory ChartSummary.fromHubJson(Json j) => ChartSummary(
        source: ChartSource.artifactHub,
        repo: asStr(j['repo']),
        repoDisplay: asStr(j['repoDisplay']),
        repoURL: asStr(j['repoURL']),
        name: asStr(j['name']),
        version: asStr(j['version']),
        appVersion: asStr(j['appVersion']),
        description: asStr(j['description']),
        icon: asStr(j['icon']),
        publisher: asStr(j['publisher']),
        packageId: asStr(j['packageId']),
        deprecated: j['deprecated'] == true,
        official: j['official'] == true,
        verified: j['verified'] == true,
        stars: asInt(j['stars']),
      );

  String get key => '${source.name}/$repo/$name';
}

class RepoChartList {
  final List<ChartSummary> charts;
  final List<String> notCached;
  final Map<String, String> errors;
  const RepoChartList(this.charts, {this.notCached = const [], this.errors = const {}});
  factory RepoChartList.fromJson(Json j) => RepoChartList(
        [for (final c in (j['charts'] as List? ?? const [])) ChartSummary.fromRepoJson(Map<String, dynamic>.from(c))],
        notCached: asStrings(j['notCached']),
        errors: {for (final e in (j['errors'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'},
      );
}

class HubSearch {
  final List<ChartSummary> packages;
  final int total;
  const HubSearch(this.packages, this.total);
}

class ChartMaintainer {
  final String name, email, url;
  const ChartMaintainer(this.name, {this.email = '', this.url = ''});
}

/// A chart's detail, from a repository index or Artifact Hub.
class ChartDetail {
  final ChartSource source;
  final String repo, repoDisplay, repoURL, name, version, appVersion, description, icon, home, kubeVersion, license, packageId, readme;
  final List<String> keywords;
  final List<ChartMaintainer> maintainers;
  final List<(String, String)> links;
  final List<HelmChartVersion> versions;
  final bool deprecated, official, verified;
  const ChartDetail({
    required this.source,
    required this.repo,
    required this.repoURL,
    required this.name,
    required this.version,
    this.repoDisplay = '',
    this.appVersion = '',
    this.description = '',
    this.icon = '',
    this.home = '',
    this.kubeVersion = '',
    this.license = '',
    this.packageId = '',
    this.readme = '',
    this.keywords = const [],
    this.maintainers = const [],
    this.links = const [],
    this.versions = const [],
    this.deprecated = false,
    this.official = false,
    this.verified = false,
  });

  factory ChartDetail.fromJson(Json j) => ChartDetail(
        source: j['source'] == 'artifacthub' ? ChartSource.artifactHub : ChartSource.repo,
        repo: asStr(j['repo']),
        repoDisplay: asStr(j['repoDisplay']),
        repoURL: asStr(j['repoURL']),
        name: asStr(j['name']),
        version: asStr(j['version']),
        appVersion: asStr(j['appVersion']),
        description: asStr(j['description']),
        icon: asStr(j['icon']),
        home: asStr(j['home']),
        kubeVersion: asStr(j['kubeVersion']),
        license: asStr(j['license']),
        packageId: asStr(j['packageId']),
        readme: asStr(j['readme']),
        keywords: asStrings(j['keywords']),
        maintainers: [
          for (final m in (j['maintainers'] as List? ?? const []))
            ChartMaintainer(asStr((m as Map)['name']), email: asStr(m['email']), url: asStr(m['url'])),
        ],
        links: [for (final l in (j['links'] as List? ?? const [])) (asStr((l as Map)['name']), asStr(l['url']))],
        versions: [for (final v in (j['versions'] as List? ?? const [])) HelmChartVersion.fromJson(Map<String, dynamic>.from(v))],
        deprecated: j['deprecated'] == true,
        official: j['official'] == true,
        verified: j['verified'] == true,
      );

  String get repoLabel => repoDisplay.isNotEmpty ? repoDisplay : repo;
}

/// A chart's README and default values.yaml for one version.
class ChartFiles {
  final String version, readme, values;
  const ChartFiles({required this.version, this.readme = '', this.values = ''});
}

/// A newer version of an installed chart.
class ChartUpdate {
  final String chart, installed, latest, repo, repoURL;
  final ChartSource source;
  const ChartUpdate({required this.chart, required this.installed, required this.latest, required this.repo, required this.repoURL, this.source = ChartSource.repo});
  factory ChartUpdate.fromJson(Json j) => ChartUpdate(
        chart: asStr(j['chart']),
        installed: asStr(j['installed']),
        latest: asStr(j['latest']),
        repo: asStr(j['repo']),
        repoURL: asStr(j['repoURL']),
        source: j['source'] == 'artifacthub' ? ChartSource.artifactHub : ChartSource.repo,
      );
}

/// The `/api/helm/updates` key of a release's chart.
String chartUpdateKey(HelmRelease r) => '${r.chart}@${r.chartVersion}';

/// Thin client for the charts browser. Subclass it in tests to serve fixtures.
class HelmMarketApi {
  final http.Client _client;
  late final BackendHttp _http = BackendHttp(_api, '/api/helm/', httpClient: _client);
  final ApiClient _api;
  HelmMarketApi(ApiClient api, {http.Client? httpClient})
      : _api = api,
        _client = httpClient ?? http.Client();

  /// One from an ancestor Provider (tests), else one on the app's [ApiClient].
  static HelmMarketApi of(BuildContext context) {
    try {
      return Provider.of<HelmMarketApi>(context, listen: false);
    } on ProviderNotFoundException {
      return HelmMarketApi(context.read<ApiClient>());
    }
  }

  Future<Json> _get(String path, [Map<String, String?> query = const {}]) async => jsonObjectBody(await _http.get(path, query));
  Future<Json> _post(String path, Json body) async => jsonObjectBody(await _http.send('POST', path, body: body));

  Future<HelmRepoList> repos() async => HelmRepoList.fromJson(await _get('repos'));

  /// Downloads a repository's index (`helm repo update <name>`).
  Future<HelmRepo> updateRepo(String name) async => HelmRepo.fromJson(await _post('repos/update', {'name': name}));

  /// Adds a repository to the user's repositories.yaml (`helm repo add`).
  Future<HelmRepo> addRepo({required String name, required String url, String? username, String? password, bool passCredentialsAll = false, bool insecureSkipTLSVerify = false}) async =>
      HelmRepo.fromJson(await _post('repos/add', {
        'name': name,
        'url': url,
        if (username != null && username.isNotEmpty) 'username': username,
        if (password != null && password.isNotEmpty) 'password': password,
        'passCredentialsAll': passCredentialsAll,
        'insecureSkipTLSVerify': insecureSkipTLSVerify,
      }));

  Future<void> removeRepo(String name) async => _post('repos/remove', {'name': name});

  /// Latest version of every chart in the cached indexes ([repo] null = all).
  Future<RepoChartList> repoCharts({String? repo}) async => RepoChartList.fromJson(await _get('repos/charts', {'repo': repo}));

  Future<ChartDetail> repoChart(String repo, String chart, {String? version}) async =>
      ChartDetail.fromJson(await _get('repos/chart', {'repo': repo, 'chart': chart, 'version': version}));

  Future<ChartFiles> repoChartFiles(String repo, String chart, {String? version}) async {
    final j = await _get('repos/chart/files', {'repo': repo, 'chart': chart, 'version': version});
    return ChartFiles(version: asStr(j['version']), readme: asStr(j['readme']), values: asStr(j['values']));
  }

  Future<bool> artifactHubEnabled() async => (await _get('artifacthub/settings'))['enabled'] == true;

  Future<bool> setArtifactHub(bool enabled) async =>
      jsonObjectBody(await _http.send('PUT', 'artifacthub/settings', body: {'enabled': enabled}))['enabled'] == true;

  Future<HubSearch> searchHub(String q, {int offset = 0, int limit = 60}) async {
    final j = await _get('artifacthub/search', {'q': q, 'offset': '$offset', 'limit': '$limit'});
    return HubSearch([for (final p in (j['packages'] as List? ?? const [])) ChartSummary.fromHubJson(Map<String, dynamic>.from(p))], asInt(j['total']));
  }

  Future<ChartDetail> hubPackage(String repo, String chart, {String? version}) async =>
      ChartDetail.fromJson(await _get('artifacthub/package', {'repo': repo, 'chart': chart, 'version': version}));

  Future<String> hubValues(String packageId, String version) async => asStr((await _get('artifacthub/values', {'packageId': packageId, 'version': version}))['values']);

  /// Detail of [c] (from its source), at [version] (null = latest).
  Future<ChartDetail> detail(ChartSummary c, {String? version}) =>
      c.source == ChartSource.artifactHub ? hubPackage(c.repo, c.name, version: version) : repoChart(c.repo, c.name, version: version);

  /// README and default values of [d] at [version] (null = [d]'s version).
  Future<ChartFiles> files(ChartDetail d, {String? version}) async {
    final v = version ?? d.version;
    if (d.source == ChartSource.artifactHub) {
      final readme = v == d.version ? d.readme : (await hubPackage(d.repo, d.name, version: v)).readme;
      return ChartFiles(version: v, readme: readme, values: await hubValues(d.packageId, v));
    }
    return repoChartFiles(d.repo, d.name, version: v);
  }

  /// Newer versions of installed charts, keyed by [chartUpdateKey].
  Future<Map<String, ChartUpdate>> updates(Iterable<HelmRelease> releases) async {
    final keys = {for (final r in releases) if (r.chart.isNotEmpty && r.chartVersion.isNotEmpty) chartUpdateKey(r)}.toList()..sort();
    if (keys.isEmpty) return const {};
    // backendUri can't repeat a parameter: build the query here.
    final r = await _client.get(_http.uri('updates').replace(queryParameters: {'chart': keys}), headers: _api.authHeaders);
    throwIfFailed(r);
    final j = jsonObjectBody(r);
    return {for (final e in (j['updates'] as Map? ?? const {}).entries) '${e.key}': ChartUpdate.fromJson(Map<String, dynamic>.from(e.value))};
  }
}
