import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/app/links.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/links_ui.dart';

import 'support/fixture_api.dart';

/// Switching context without a backend: just lands on it.
class _App extends AppState {
  _App() : super(ApiClient(base: Uri.parse('http://fake')));
  final switched = <String>[];

  @override
  Future<void> switchContext(String name) async {
    switched.add(name);
    currentContext = name;
  }
}

void main() {
  test('links round-trip, reject bad input, and only navigate after confirming a context switch', () async {
    const pod = AppLink(context: 'kind-dev', namespace: 'shop', kind: 'Pod', name: 'web-6fd47b8fcb-4v4m9');
    const deploy = AppLink(context: 'arn:aws:eks:eu-west-1:1:cluster/prod eu&x', namespace: 'shop', kind: 'Deployment', group: 'apps', name: 'api');
    const role = AppLink(context: 'kind-dev', kind: 'ClusterRole', group: 'rbac.authorization.k8s.io', name: 'system:controller:job-controller');
    for (final l in [pod, deploy, role, const AppLink(context: 'kind-dev', kind: 'Pod', namespace: 'shop'), const AppLink(context: 'kind-dev', view: 'nodes')]) {
      expect(AppLink.parse(l.appUrl), l, reason: l.appUrl);
      expect(AppLink.parse(l.webUrl), l, reason: l.webUrl);
    }
    expect(pod.appUrl, 'k8sman://open?ctx=kind-dev&ns=shop&kind=Pod&name=web-6fd47b8fcb-4v4m9');
    expect(deploy.webUrl, 'https://k8sman.dev/o/?ctx=arn%3Aaws%3Aeks%3Aeu-west-1%3A1%3Acluster%2Fprod%20eu%26x&ns=shop&kind=Deployment&group=apps&name=api');
    for (final bad in [
      'k8sman://open?ns=shop&kind=Pod&name=x', // no context
      'k8sman://open?ctx=a&kind=Pod&name=%3Cscript%3E',
      'k8sman://open?ctx=a&ns=Shop&kind=Pod&name=x',
      'k8sman://open?ctx=a&name=x', // a name without a kind
      'k8sman://open?ctx=a%0Ab',
      'k8sman://run?ctx=a',
      'https://evil.example/o/?ctx=a',
    ]) {
      expect(AppLink.parse(bad), isNull, reason: bad);
    }

    final app = _App()
      ..currentContext = 'kind-dev'
      ..contexts = const [
        ContextInfo(name: 'kind-dev', cluster: 'kind', user: 'u'),
        ContextInfo(name: 'prod-eu', cluster: 'prod', user: 'u'),
      ]
      ..types = FixtureApi.types;
    final asked = <String>[], notices = <String>[];
    var answer = false;
    Future<LinkOutcome> follow(AppLink l) => followLink(app, l, confirm: (_, m) async {
          asked.add(m);
          return answer;
        }, notice: notices.add);

    // Not in the kubeconfig: says so, switches nothing.
    expect(await follow(const AppLink(context: 'staging', kind: 'Pod')), LinkOutcome.missingContext);
    expect(notices.single, contains('staging, which isn\'t in your kubeconfig'));
    // Another context: asks first; declining changes nothing.
    const remote = AppLink(context: 'prod-eu', namespace: 'shop', kind: 'Deployment', group: 'apps', name: 'api');
    expect(await follow(remote), LinkOutcome.cancelled);
    expect(asked.single, 'Open Deployment shop/api in prod-eu? This switches from kind-dev.');
    expect(app.switched, isEmpty);
    expect(app.detail, isNull);
    // Accepting switches, then opens the table and the inspector.
    answer = true;
    expect(await follow(remote), LinkOutcome.opened);
    expect(app.switched, ['prod-eu']);
    expect(app.selectedType?.kind, 'Deployment');
    expect((app.detail?.name, app.detail?.namespace), ('api', 'shop'));
    // Same context: no question.
    expect(await follow(const AppLink(context: 'prod-eu', view: 'nodes')), LinkOutcome.opened);
    expect(app.view, MainView.nodes);
    expect(asked, hasLength(2));
  });
}
