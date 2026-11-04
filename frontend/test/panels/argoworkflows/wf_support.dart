import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/argoworkflows/wf_common.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';

const workflowType = ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'workflows', kind: 'Workflow', custom: true);
const cronWorkflowType = ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'cronworkflows', kind: 'CronWorkflow', custom: true);
const workflowTemplateType = ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'workflowtemplates', kind: 'WorkflowTemplate', custom: true);
const clusterWorkflowTemplateType =
    ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'clusterworkflowtemplates', kind: 'ClusterWorkflowTemplate', namespaced: false, custom: true);

final wfTypes = [...testTypes, workflowType, cronWorkflowType, workflowTemplateType, clusterWorkflowTemplateType];

ResourceType wfTypeOf(Json o) => wfTypes.firstWhere((t) => t.kind == o['kind'] && (t.group == 'argoproj.io') == '${o['apiVersion']}'.startsWith('argoproj.io'));

/// Fixtures in test/panels/argoworkflows/fixtures (captured from the dev
/// kind cluster running dev/argo-workflows/samples.yaml).
Json wfFixture(String name) => jsonDecode(File('test/panels/argoworkflows/fixtures/$name').readAsStringSync()) as Json;

/// A fake argo-server status (never real HTTP).
class FakeArgoWFApi extends ArgoWFApi {
  final ArgoWFStatus fixed;
  FakeArgoWFApi(super.api, this.fixed);
  @override
  Future<ArgoWFStatus> fetchStatus({bool refresh = false}) async => fixed;
}

/// Renders [object]'s panel sections like the sidebar's Overview tab.
Future<AppState> pumpWf(
  WidgetTester tester,
  Json object, {
  ApiClient? api,
  Size size = const Size(560, 2400),
  bool readOnly = false,
  ArgoWFStatus status = const ArgoWFStatus(found: true, reachable: true, available: true, auth: 'server', version: 'v4.0.1', serverNamespace: 'argo'),
}) async {
  final t = wfTypeOf(object);
  final client = api ?? FakeApiClient();
  ArgoWFApi.debugOverride = (a) => FakeArgoWFApi(a, status);
  addTearDown(() => ArgoWFApi.debugOverride = null);
  final app = AppState(client)
    ..types = wfTypes
    ..readOnly = readOnly
    ..currentContext = 'kind-k8sman-dev';
  app.openDetail(DetailTarget(type: t, name: '${object['metadata']?['name']}', namespace: object['metadata']?['namespace']));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final dock = LogDock(client);
  addTearDown(dock.closeAll);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: client),
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<LogDock>.value(value: dock),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: AppColors.of(context).inspector,
          body: Builder(builder: (context) {
            final ctx = PanelContext(object: object, type: t, api: client, app: app);
            return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: panelFor(t).buildSections(context, ctx));
          }),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return app;
}
