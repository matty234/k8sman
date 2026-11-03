import 'dart:convert';
import 'dart:io';

import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/argocd/app_diff.dart';

/// Serves `/api/argocd/*` from captured fixtures (`diff-<app>.json`, from a
/// live k8sman backend against Argo CD v3.5.7) and records calls.
class FakeArgoDiffApi extends ArgoDiffApi {
  /// none, configured or session.
  String auth;
  final bool serverFound;
  final bool initialAdmin;
  final List<String> calls = [];

  FakeArgoDiffApi(super.api, {this.auth = 'none', this.serverFound = true, this.initialAdmin = true});

  /// argocd-server isn't installed: the default for panel tests.
  FakeArgoDiffApi.notFound(ApiClient api) : this(api, serverFound: false);

  ArgoApiStatus get _status => ArgoApiStatus(
        found: serverFound,
        reachable: serverFound,
        auth: auth,
        authValid: auth == 'none' ? null : true,
        username: auth == 'none' ? null : 'admin',
        initialAdminAvailable: initialAdmin,
        serverNamespace: 'argocd',
        serverName: 'argocd-server',
        version: 'v3.5.7',
      );

  @override
  Future<ArgoApiStatus> status({String? namespace}) async {
    calls.add('status');
    return _status;
  }

  @override
  Future<ArgoApiStatus> setToken(String token, {String? context, String? namespace}) async {
    calls.add('setToken');
    auth = 'configured';
    return _status;
  }

  @override
  Future<ArgoApiStatus> clearToken({String? namespace}) async {
    calls.add('clearToken');
    auth = 'none';
    return _status;
  }

  @override
  Future<ArgoApiStatus> useInitialAdmin({String? namespace}) async {
    calls.add('initialAdmin');
    auth = 'session';
    return _status;
  }

  @override
  Future<Json> diff({String? namespace, required String name}) async {
    calls.add('diff $name');
    if (!serverFound) throw ApiException(404, 'argocd-server was not found', reason: 'NotFound');
    if (auth == 'none') throw ApiException(401, 'Connect to the Argo CD API to see diffs', reason: 'NoToken');
    final f = File('test/panels/argocd/fixtures/diff-$name.json');
    if (!f.existsSync()) return {'resources': [], 'auth': auth};
    return {...jsonDecode(f.readAsStringSync()) as Json, 'auth': auth};
  }
}
