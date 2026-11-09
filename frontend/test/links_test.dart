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
  test('links parse old and new forms; opening matches by mapping, fingerprint, then name, else offers a chooser', () async {
    // ---- parsing and building ----
    const api = AppLink(
      context: 'arn:aws:eks:eu-west-1:1:cluster/prod eu&x',
      cluster: '1111111111aa',
      namespace: 'shop',
      kind: 'Deployment',
      group: 'apps',
      name: 'api',
    );
    expect(
      api.webUrl,
      'https://k8sman.dev/o/?kind=Deployment&group=apps&ns=shop&name=api#c=1111111111aa&ctx=arn%3Aaws%3Aeks%3Aeu-west-1%3A1%3Acluster%2Fprod%20eu%26x',
    );
    expect(
      api.appUrl,
      'k8sman://open?kind=Deployment&group=apps&ns=shop&name=api&c=1111111111aa&ctx=arn%3Aaws%3Aeks%3Aeu-west-1%3A1%3Acluster%2Fprod%20eu%26x',
    );
    expect(const AppLink(context: 'kind-dev', cluster: 'aaaaaaaaaaaa', view: 'nodes').webUrl, 'https://k8sman.dev/o/?view=nodes#c=aaaaaaaaaaaa&ctx=kind-dev');
    for (final l in [
      api,
      const AppLink(context: 'kind-dev', kind: 'ClusterRole', group: 'rbac.authorization.k8s.io', name: 'system:controller:job-controller'),
      const AppLink(context: 'kind-dev', cluster: 'aaaaaaaaaaaa', kind: 'Pod', namespace: 'shop'),
      const AppLink(context: 'kind-dev', cluster: 'aaaaaaaaaaaa'),
    ]) {
      expect(AppLink.parse(l.appUrl), l, reason: l.appUrl);
      expect(AppLink.parse(l.webUrl), l, reason: l.webUrl);
    }
    // Older links (ctx in the query), and c/ctx in a k8sman:// fragment.
    const pod = AppLink(context: 'kind-dev', namespace: 'shop', kind: 'Pod', name: 'web-1');
    expect(AppLink.parse('k8sman://open?ctx=kind-dev&ns=shop&kind=Pod&name=web-1'), pod);
    expect(AppLink.parse('https://k8sman.dev/o/?ctx=kind-dev&ns=shop&kind=Pod&name=web-1'), pod);
    expect(AppLink.parse('k8sman://open?ns=shop&kind=Pod&name=web-1#c=aaaaaaaaaaaa&ctx=kind-dev')?.cluster, 'aaaaaaaaaaaa');
    for (final bad in [
      'k8sman://open?ns=shop&kind=Pod&name=x', // no context
      'https://k8sman.dev/o/?kind=Pod#c=aaaaaaaaaaaa', // no context
      'https://k8sman.dev/o/?kind=Pod#c=AAAAAAAAAAAA&ctx=a',
      'k8sman://open?kind=Pod&c=abc&ctx=a',
      'k8sman://open?ctx=a&kind=Pod&name=%3Cscript%3E',
      'k8sman://open?ctx=a&name=x', // a name without a kind
      'https://k8sman.dev/o/?kind=Pod#ctx=a%0Ab',
      'k8sman://run?ctx=a',
      'https://evil.example/o/?ctx=a',
    ]) {
      expect(AppLink.parse(bad), isNull, reason: bad);
    }

    // ---- matching ----
    final app = _App()
      ..currentContext = 'kind-dev'
      ..contexts = const [
        ContextInfo(name: 'admin@prod', cluster: 'p', user: 'admin', fingerprint: '222222222222'),
        ContextInfo(name: 'kind-dev', cluster: 'kind', user: 'u', fingerprint: 'aaaaaaaaaaaa'),
        ContextInfo(name: 'prod-eu', cluster: 'prod', user: 'u', fingerprint: '1111111111aa'),
        ContextInfo(name: 'prod-ro', cluster: 'p', user: 'viewer', fingerprint: '222222222222'),
      ]
      ..types = FixtureApi.types;
    final asked = <String>[], notices = <String>[], offered = <(String, List<String>, bool)>[];
    var answer = false;
    LinkChoice? pick;
    Future<LinkOutcome> follow(AppLink l) => followLink(
      app,
      l,
      confirm: (_, m) async {
        asked.add(m);
        return answer;
      },
      notice: notices.add,
      choose: (m, contexts, {required missing, required canRemember}) async {
        offered.add((m, contexts, missing));
        return pick;
      },
    );

    // One context has the fingerprint: asks before switching, whatever the sender called it.
    expect(await follow(api), LinkOutcome.cancelled);
    expect(asked.last, 'Open Deployment shop/api in prod-eu? This switches from kind-dev.');
    expect(app.switched, isEmpty);
    answer = true;
    expect(await follow(api), LinkOutcome.opened);
    expect(app.switched, ['prod-eu']);
    expect((app.selectedType?.kind, app.detail?.name, app.detail?.namespace), ('Deployment', 'api', 'shop'));
    // Same context: no question.
    expect(await follow(const AppLink(context: 'whatever', cluster: '1111111111aa', view: 'nodes')), LinkOutcome.opened);
    expect(app.view, MainView.nodes);
    expect(asked, hasLength(2));

    // Several contexts share it: the one named like ctx, then the current one.
    expect(await follow(const AppLink(context: 'admin@prod', cluster: '222222222222')), LinkOutcome.opened);
    expect(app.switched.last, 'admin@prod');
    expect(await follow(const AppLink(context: 'zzz', cluster: '222222222222')), LinkOutcome.opened);
    expect(app.switched.last, 'admin@prod');
    // Neither: the chooser lists just those; a pick switches without asking again and can be remembered.
    app.currentContext = 'kind-dev';
    pick = (context: 'prod-ro', remember: true);
    expect(await follow(const AppLink(context: 'zzz', cluster: '222222222222')), LinkOutcome.opened);
    expect(offered.single.$2, ['admin@prod', 'prod-ro']);
    expect(offered.single.$3, isFalse);
    expect(app.switched.last, 'prod-ro');
    expect(app.linkClusterMap, {'222222222222': 'prod-ro'});
    expect(asked, hasLength(3));
    // A remembered mapping comes first, before the current context and the name.
    app.currentContext = 'admin@prod';
    answer = false;
    expect(await follow(const AppLink(context: 'admin@prod', cluster: '222222222222')), LinkOutcome.cancelled);
    expect(asked.last, 'Open prod-ro? This switches from admin@prod.');

    // No fingerprint match (or an older link): a context of the same name, said quietly.
    expect(await follow(const AppLink(context: 'prod-eu', cluster: '999999999999', kind: 'Pod')), LinkOutcome.cancelled);
    expect(asked.last, 'Open Pod in prod-eu? This switches from admin@prod. Matched by context name.');
    expect(await follow(const AppLink(context: 'prod-eu')), LinkOutcome.cancelled);
    expect(asked.last, endsWith('Matched by context name.'));

    // Neither: says so, and Choose a context… lists them all; cancelling changes nothing.
    offered.clear();
    pick = null;
    const gone = AppLink(context: 'gone', cluster: '999999999999');
    expect(await follow(gone), LinkOutcome.missingContext);
    expect(offered.single.$1, 'This link is for a cluster that isn\'t in your kubeconfig (context gone).');
    expect((offered.single.$2.length, offered.single.$3), (4, true));
    pick = (context: 'kind-dev', remember: true);
    expect(await follow(gone), LinkOutcome.opened);
    expect(app.switched.last, 'kind-dev');
    expect(app.linkClusterMap['999999999999'], 'kind-dev');
    expect(notices, isEmpty);
  });
}
