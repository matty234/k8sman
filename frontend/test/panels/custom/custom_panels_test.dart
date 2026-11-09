import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/actions/actions.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/custom/crd_schema.dart';
import 'package:k8sman/panels/custom/generic_panel.dart';
import 'package:k8sman/panels/custom/humanize.dart';
import 'package:k8sman/panels/custom/refs.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';

Json _load(String path) => jsonDecode(File(path).readAsStringSync()) as Json;
Json _devFixture(String name) => _load('../dev/fixtures/$name');
Json _fixture(String name) => _load('test/panels/custom/fixtures/$name');

const _backupType = ResourceType(group: 'ops.example.dev', version: 'v1', resource: 'backups', kind: 'Backup', custom: true);

/// Like [pumpPanel] but always renders [GenericPanel], so built-ins that may
/// later get a dedicated panel keep exercising the fallback.
Future<AppState> pumpGeneric(WidgetTester tester, Json object, ResourceType t, {Size size = const Size(560, 2400)}) async {
  final client = FakeApiClient();
  final app = AppState(client)..types = testTypes;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(builder: (context) {
          final ctx = PanelContext(object: object, type: t, api: client, app: app);
          return ListView(padding: const EdgeInsets.all(12), children: const GenericPanel().buildSections(context, ctx));
        }),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return app;
}

void main() {
  setUp(CrdCache.clear);

  group('helpers', () {
    test('humanize', () {
      expect(humanize('leaseDurationSeconds'), 'Lease duration seconds');
      expect(humanize('podCIDR'), 'Pod CIDR');
      expect(humanize('apiVersion'), 'API version');
      expect(humanize('caBundle'), 'CA bundle');
      expect(humanize('hostIPs'), 'Host IPs');
      expect(humanize('app.kubernetes.io/name'), 'app.kubernetes.io/name');
    });

    test('reference detection', () {
      const r = RefResolver(namespace: 'demo');
      expect(r.fromScalar('secretName', 'tls')?.kind, 'Secret');
      expect(r.fromScalar('credentialsSecretName', 'x')?.kind, 'Secret');
      expect(r.fromScalar('claimName', 'data')?.kind, 'PersistentVolumeClaim');
      expect(r.fromScalar('serviceAccountName', 'sa')?.kind, 'ServiceAccount');
      expect(r.fromScalar('name', 'x'), isNull);
      expect(r.fromScalar('displayName', 'x'), isNull);
      final cm = r.fromMap('configMapRef', {'name': 'cfg'});
      expect((cm?.kind, cm?.namespace), ('ConfigMap', 'demo'));
      final job = r.fromMap('lastJob', {'apiVersion': 'batch/v1', 'kind': 'Job', 'name': 'j', 'namespace': 'ops'});
      expect((job?.group, job?.kind, job?.namespace), ('batch', 'Job', 'ops'));
      expect(r.fromMap('owner', {'name': 'x', 'email': 'y'}), isNull);
      expect(r.fromList('imagePullSecrets', [{'name': 'a'}, {'name': 'b'}])?.map((e) => e.kind), ['Secret', 'Secret']);
    });
  });

  group('CRD panel', () {
    testWidgets('widgets CRD: names, versions, conditions, instances button', (tester) async {
      final crd = _devFixture('crd-widgets.example.k8sman.dev.json');
      final api = FakeApiClient(itemsByResource: {
        'widgets.example.k8sman.dev': [_devFixture('widget-sprocket.json'), {'metadata': {'name': 'gizmo', 'namespace': 'demo'}}],
      });
      final app = await pumpPanel(tester, crd, api: api);
      expect(find.text('Established'), findsWidgets);
      expect(find.text('WidgetList'), findsOneWidget);
      expect(find.text('match spec'), findsOneWidget);
      expect(find.text('v1alpha1'), findsWidgets);
      expect(find.text('.spec.color'), findsOneWidget); // printer column
      expect(find.text('widgets in 1 namespace'), findsOneWidget);
      expect(find.text('Storage migration pending', findRichText: true), findsNothing);
      // schema browser: spec/status expanded by default
      expect(find.text('color'), findsOneWidget);
      expect(find.textContaining('enum: red | green | blue'), findsOneWidget);
      expect(find.text('preserve-unknown-fields'), findsOneWidget);

      await tester.tap(find.text('Show widgets'));
      await tester.pump();
      expect(app.selectedType?.kind, 'Widget');
    });

    testWidgets('rich CRD: deprecation, migration warning, webhook, schema search', (tester) async {
      await loadRealFonts();
      final crd = _fixture('crd-backups.ops.example.dev.json');
      await pumpPanel(tester, crd, size: const Size(560, 3600));
      expect(find.textContaining('Storage migration pending'), findsOneWidget);
      expect(find.textContaining('deprecated; use ops.example.dev/v1'), findsOneWidget);
      expect(find.text('Service/ops-system/backup-operator-webhook:443/convert'), findsOneWidget);
      expect(find.text('immutable'), findsOneWidget);
      expect(find.text('list-type: map [name]'), findsOneWidget);
      expect(find.text('Show backups'), findsOneWidget); // disabled: type not discovered

      // Expand everything for the screenshot.
      await tester.tap(find.byTooltip('Expand all'));
      await tester.pumpAndSettle();
      expect(find.text('timeoutSeconds'), findsOneWidget);
      expect(find.text('int-or-string'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'secret');
      await tester.pumpAndSettle();
      expect(find.text('1 matching field'), findsOneWidget);
      expect(find.text('credentialsSecretName'), findsOneWidget);
      expect(find.text('schedule'), findsNothing);

      // Switch schema version.
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.widgetWithText(ChoiceChip, 'v1beta1'));
      await tester.pumpAndSettle();
      expect(find.text('schedule'), findsNothing);
      expect(find.text('preserve-unknown-fields'), findsWidgets);
    });

  });

  group('generic fallback', () {
    test('is the registry fallback', () {
      expect(panelFor(_backupType), isA<GenericPanel>());
      expect(panelFor(testType('example.k8sman.dev', 'Widget')), isA<GenericPanel>());
    });

    testWidgets('Widget: health, conditions, spec with schema tooltips', (tester) async {
      await loadRealFonts();
      final api = FakeApiClient(objects: {
        'customresourcedefinitions.apiextensions.k8s.io//widgets.example.k8sman.dev': _devFixture('crd-widgets.example.k8sman.dev.json'),
      });
      await pumpPanel(tester, _devFixture('widget-sprocket.json'), api: api, size: const Size(560, 1000));
      expect(find.text('Health'), findsOneWidget);
      expect(find.text('Conditions'), findsOneWidget);
      expect(find.text('Spec'), findsOneWidget);
      expect(find.text('Reconciled'), findsOneWidget);
      expect(find.text('Color'), findsOneWidget);
      expect(find.text('core'), findsOneWidget); // tags as chips
      expect(find.text('platform@example.com'), findsOneWidget);
      expect(find.text('CRD'), findsOneWidget);
    });

    testWidgets('CR with refs, tables, generation drift and schema descriptions', (tester) async {
      await loadRealFonts();
      final api = FakeApiClient(objects: {
        'customresourcedefinitions.apiextensions.k8s.io//backups.ops.example.dev': _fixture('crd-backups.ops.example.dev.json'),
      });
      final app = await pumpPanel(tester, _fixture('backup-nightly.json'), api: api, type: _backupType, size: const Size(560, 2400));

      expect(find.textContaining("hasn't observed generation 5 yet"), findsOneWidget);
      expect(find.textContaining('403 AccessDenied'), findsWidgets);
      expect(find.textContaining('Stale conditions'), findsOneWidget);
      // refs
      expect(find.text('Secret/s3-creds'), findsOneWidget);
      expect(find.text('ServiceAccount/backup-runner'), findsOneWidget);
      expect(find.text('PersistentVolumeClaim/backup-scratch'), findsOneWidget);
      expect(find.text('ConfigMap/backup-config'), findsOneWidget);
      expect(find.text('Secret/backup-env'), findsOneWidget);
      expect(find.text('Job/nightly-29372'), findsOneWidget);
      expect(find.text('Database/data/orders-db'), findsOneWidget);
      // homogeneous array → table with headers
      expect(find.text('Timeout seconds'), findsOneWidget);
      expect(find.text('psql, -c, CHECKPOINT'), findsOneWidget);
      // long string → code block
      expect(find.textContaining('set -eu'), findsOneWidget);
      // schema description as tooltip
      final tip = tester.widget<Tooltip>(find.ancestor(of: find.text('Schedule'), matching: find.byType(Tooltip)).first);
      expect(tip.message, contains('Cron schedule in UTC'));


      await tester.tap(find.text('Secret/s3-creds'));
      await tester.pump();
      expect(app.detail?.name, 's3-creds');
      expect(app.detail?.namespace, 'demo');
    });

    testWidgets('scale control for CRs with a scale subresource, hidden when read-only', (tester) async {
      final crd = _fixture('crd-backups.ops.example.dev.json');
      final obj = _fixture('backup-nightly.json');
      (obj['spec'] as Map)['replicas'] = 2;
      Future<AppState> pump({bool readOnly = false, Json? crdOverride}) async {
        CrdCache.clear();
        final api = FakeApiClient(objects: {'customresourcedefinitions.apiextensions.k8s.io//backups.ops.example.dev': crdOverride ?? crd});
        final app = AppState(api)
          ..types = testTypes
          ..readOnly = readOnly;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(MultiProvider(
          providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: Scaffold(
              body: Builder(builder: (context) {
                final ctx = PanelContext(object: obj, type: _backupType, api: api, app: app);
                return ListView(children: const GenericPanel().buildSections(context, ctx));
              }),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        return app;
      }

      tester.view.physicalSize = const Size(560, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pump();
      expect(find.byType(ScaleControl), findsOneWidget);
      expect(find.text('Replicas'), findsOneWidget);

      await pump(readOnly: true);
      expect(find.byType(ScaleControl), findsNothing);

      // No scale subresource → no control.
      final noScale = jsonDecode(jsonEncode(crd)) as Json;
      for (final v in (noScale['spec']['versions'] as List)) {
        (v['subresources'] as Map).remove('scale');
      }
      await pump(crdOverride: noScale);
      expect(find.byType(ScaleControl), findsNothing);
      expect(find.text('Replicas'), findsOneWidget);
    });

    testWidgets('works when the CRD fetch fails', (tester) async {
      await pumpPanel(tester, _fixture('backup-nightly.json'), type: _backupType);
      expect(find.text('Spec'), findsOneWidget);
      expect(find.text('Secret/s3-creds'), findsOneWidget);
    });

    testWidgets('built-in Lease (no status)', (tester) async {
      await loadRealFonts();
      const leaseType = ResourceType(group: 'coordination.k8s.io', version: 'v1', resource: 'leases', kind: 'Lease');
      await pumpGeneric(tester, _fixture('lease-kube-scheduler.json'), leaseType, size: const Size(560, 500));
      expect(find.text('Health'), findsNothing);
      expect(find.text('Holder identity'), findsOneWidget);
      expect(find.text('Lease duration seconds'), findsOneWidget);
      expect(find.textContaining('ago'), findsWidgets);
    });

    testWidgets('built-in APIService (cluster-scoped, conditions)', (tester) async {
      await loadRealFonts();
      const t = ResourceType(group: 'apiregistration.k8s.io', version: 'v1', resource: 'apiservices', kind: 'APIService', namespaced: false);
      await pumpGeneric(tester, _fixture('apiservice-v1alpha1.example.k8sman.dev.json'), t, size: const Size(560, 600));
      expect(find.text('Available'), findsWidgets);
      expect(find.text('Group priority minimum'), findsOneWidget);
    });

    testWidgets('top-level fields beyond spec/status, and empty objects', (tester) async {
      await loadRealFonts();
      const t = ResourceType(group: 'admissionregistration.k8s.io', version: 'v1', resource: 'mutatingwebhookconfigurations', kind: 'MutatingWebhookConfiguration', namespaced: false);
      await pumpGeneric(
        tester,
        {
          'apiVersion': 'admissionregistration.k8s.io/v1',
          'kind': 'MutatingWebhookConfiguration',
          'metadata': {'name': 'inject', 'uid': 'u1'},
          'webhooks': [
            {
              'name': 'inject.example.dev',
              'admissionReviewVersions': ['v1'],
              'sideEffects': 'None',
              'failurePolicy': 'Fail',
              'clientConfig': {
                'service': {'name': 'injector', 'namespace': 'ops-system', 'path': '/mutate', 'port': 443},
              },
              'rules': [
                {'apiGroups': [''], 'apiVersions': ['v1'], 'operations': ['CREATE'], 'resources': ['pods'], 'scope': '*'},
              ],
            }
          ],
        },
        t,
        size: const Size(560, 700),
      );
      expect(find.text('Webhooks'), findsOneWidget);
      expect(find.text('Service/ops-system/injector'), findsOneWidget);
      expect(find.text('CREATE'), findsOneWidget);

      await pumpGeneric(tester, {'apiVersion': 'example.dev/v1', 'kind': 'Thing', 'metadata': {'name': 'x'}},
          const ResourceType(group: 'example.dev', version: 'v1', resource: 'things', kind: 'Thing', namespaced: false));
      expect(find.textContaining('no spec, status or data'), findsOneWidget);
    });
  });
}
