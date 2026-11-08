import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/modules/kyverno_module.dart';
import 'package:k8sman/modules/modules.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';

Json _report(String name, String uid, List<Json> results) => {
      'apiVersion': 'wgpolicyk8s.io/v1alpha2',
      'kind': 'PolicyReport',
      'metadata': {'name': name, 'namespace': 'demo'},
      'scope': {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'name': name, 'namespace': 'demo', 'uid': uid},
      'results': results,
    };

void main() {
  testWidgets('Policy results tab: a Deployment gets its per-resource report, failures first', (tester) async {
    final client = FakeApiClient(itemsByResource: {
      'policyreports.wgpolicyk8s.io': [
        _report('web', 'd1', [
          {'policy': 'require-labels', 'rule': 'check-team', 'result': 'pass'},
          {'policy': 'disallow-latest', 'rule': 'no-latest', 'result': 'fail', 'severity': 'medium', 'message': 'image tag latest is not allowed'},
          {'policy': 'require-limits', 'rule': 'limits', 'result': 'warn', 'message': 'no limits set'},
        ]),
        _report('other', 'd2', [
          {'policy': 'disallow-latest', 'rule': 'no-latest', 'result': 'fail', 'message': 'belongs to another deployment'},
        ]),
      ],
    });
    final app = AppState(client)
      ..types = [
        ...testTypes,
        const ResourceType(group: 'wgpolicyk8s.io', version: 'v1alpha2', resource: 'policyreports', kind: 'PolicyReport'),
      ];
    const module = KyvernoModule();
    moduleStatuses.debugSet(module, client, app.currentContext, const ModuleStatus(ModuleState.connected));
    final deploy = {
      'apiVersion': 'apps/v1',
      'kind': 'Deployment',
      'metadata': {'name': 'web', 'namespace': 'demo', 'uid': 'd1'},
    };
    final ctx = PanelContext(object: deploy, type: testType('apps', 'Deployment'), api: client, app: app);
    final tab = module.inspectorTabs(ctx).single;
    expect(tab.label, 'Policy results');

    tester.view.physicalSize = const Size(520, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: Builder(builder: (c) => tab.builder(c, ctx)))),
    ));
    await tester.pump();

    expect(find.text('belongs to another deployment'), findsNothing);
    final fail = tester.getTopLeft(find.text('image tag latest is not allowed')).dy;
    final warn = tester.getTopLeft(find.text('no limits set')).dy;
    final pass = tester.getTopLeft(find.text('require-labels')).dy;
    expect(fail, lessThan(warn));
    expect(warn, lessThan(pass));
  });
}
