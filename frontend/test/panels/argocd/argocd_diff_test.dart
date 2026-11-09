import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/argocd/app_diff.dart';
import 'package:k8sman/panels/panel.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/detail/yaml_editor.dart' show DiffView;

import '../../support/screenshot.dart';
import 'argocd_panels_test.dart' hide main;
import 'fake_argo_diff.dart';

// Fixtures captured from a live backend against Argo CD v3.5.7 (dev cluster):
// - app-helm-guestbook-drift.json + diff-helm-guestbook.json: the Deployment
//   was scaled to 3 (git says 2) and a ConfigMap tracked by the app isn't in
//   git (to be pruned).
// - app-kustomize-guestbook.json + diff-kustomize-guestbook.json: nothing is
//   deployed yet (to be created).

const depKey = 'apps/Deployment/helm-guestbook/helm-guestbook';
const cmKey = '/ConfigMap/helm-guestbook/legacy-settings';

Finder toggle(String key) => find.byKey(ValueKey('diff-toggle-$key'));

void main() {
  late FakeArgoDiffApi argo;
  setUp(() => argo = FakeArgoDiffApi(ApiClient(base: Uri.parse('http://unused'))));

  // One instance per test, like ArgoDiffApi.of's per-client instance.
  ArgoDiffApi Function(ApiClient) fake({String auth = 'session', bool initialAdmin = true, String? argoUrl, String? cliLogin}) {
    FakeArgoDiffApi? inst;
    return (api) => inst ??= argo = FakeArgoDiffApi(api, auth: auth, initialAdmin: initialAdmin, argoUrl: argoUrl, cliLogin: cliLogin);
  }

  testWidgets('SSO cluster: shows the argocd CLI login command, then connects via the CLI login', (tester) async {
    await pumpArgo(tester, fx('app-kustomize-guestbook.json'),
        diffApi: fake(auth: 'none', initialAdmin: false, argoUrl: 'argocd.example.internal'));
    await tester.tap(find.text('Connect…'));
    await tester.pumpAndSettle();
    expect(find.text('argocd login argocd.example.internal --sso --grpc-web'), findsOneWidget);
    // Not logged in yet: connecting explains what to run.
    await tester.tap(find.text("I've logged in"));
    await tester.pumpAndSettle();
    expect(find.textContaining('No argocd CLI login found'), findsOneWidget);
    // After `argocd login`, the status reports the CLI context and we connect.
    argo.cliLogin = 'argocd.example.internal';
    await tester.tap(find.text("I've logged in"));
    await tester.pumpAndSettle();
    expect(argo.calls.where((c) => c == 'useCli').length, 2);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Diffs via argocd-server · argocd CLI login'), findsOneWidget);
  });

  testWidgets('existing CLI login: one click, no command shown', (tester) async {
    await pumpArgo(tester, fx('app-kustomize-guestbook.json'),
        diffApi: fake(auth: 'none', initialAdmin: false, argoUrl: 'argocd.example.internal', cliLogin: 'lon'));
    await tester.tap(find.text('Connect…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('argocd login '), findsNothing);
    await tester.tap(find.text('Use argocd CLI login'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Diffs via argocd-server · argocd CLI login'), findsOneWidget);
  });

  testWidgets('out-of-sync diff: modified deployment and resource to prune', (tester) async {
    await loadRealFonts();
    await pumpArgo(tester, fx('app-helm-guestbook-drift.json'), diffApi: fake());
    expect(tester.takeException(), isNull);
    expect(find.text('Diffs via argocd-server · session'), findsOneWidget);
    // Only resources with a diff get the toggle; the synced Service doesn't.
    expect(toggle(depKey), findsOneWidget);
    expect(toggle(cmKey), findsOneWidget);
    expect(toggle('/Service/helm-guestbook/helm-guestbook'), findsNothing);

    await tester.tap(toggle(depKey));
    await tester.pumpAndSettle();
    expect(find.byType(DiffView), findsOneWidget);
    expect(find.text('  replicas: 3'), findsOneWidget);
    expect(find.text('  replicas: 2'), findsOneWidget);
    expect(find.text('Deployment/helm-guestbook'), findsOneWidget);
    expect(find.text('will be pruned'), findsNothing);

    await tester.tap(toggle(cmKey));
    await tester.pumpAndSettle();
    expect(find.text('will be pruned'), findsOneWidget);
    expect(find.byType(DiffView), findsNWidgets(2));
    expect(argo.calls.where((c) => c.startsWith('diff')).length, 1);
  });

  testWidgets('resources to be created, and Show all diffs', (tester) async {
    await pumpArgo(tester, fx('app-kustomize-guestbook.json'), diffApi: fake());
    expect(find.text('Show all diffs'), findsOneWidget);
    await tester.tap(find.text('Show all diffs'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('will be created'), findsNWidgets(2));
    expect(find.byType(DiffView), findsNWidgets(2));
    // Close one while all are shown.
    await tester.tap(toggle('apps/Deployment/kustomize-guestbook/staging-guestbook-ui'));
    await tester.pumpAndSettle();
    expect(find.byType(DiffView), findsOneWidget);
  });

  testWidgets('not connected: strip offers the initial admin password (opt-in)', (tester) async {
    await loadRealFonts();
    await pumpArgo(tester, fx('app-helm-guestbook-drift.json'), diffApi: fake(auth: 'none'));
    expect(find.text('Connect to the Argo CD API to see diffs'), findsOneWidget);
    expect(toggle(depKey), findsNothing);
    await tester.tap(find.text('Connect…'));
    await tester.pumpAndSettle();
    expect(find.text('Use initial admin password'), findsOneWidget);
    expect(find.byKey(const ValueKey('argocd-token')), findsOneWidget);

    await tester.tap(find.text('Use initial admin password'));
    await tester.pumpAndSettle();
    expect(find.textContaining('argocd/argocd-initial-admin-secret'), findsOneWidget);
    expect(argo.calls, isNot(contains('initialAdmin')), reason: 'never silent');
    await tester.tap(find.text('Use it'));
    await tester.pumpAndSettle();
    expect(argo.calls, contains('initialAdmin'));
    // Signed in: the form says so and offers Disconnect.
    expect(find.text('Signed in via the initial admin session as admin'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(argo.calls, contains('clearToken'));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to the Argo CD API to see diffs'), findsOneWidget);
  });

  testWidgets('not connected without the initial admin secret: paste a token', (tester) async {
    await pumpArgo(tester, fx('app-kustomize-guestbook.json'), diffApi: fake(auth: 'none', initialAdmin: false));
    await tester.tap(find.text('Connect…'));
    await tester.pumpAndSettle();
    expect(find.text('Use initial admin password'), findsNothing);
    expect(find.text('argocd account generate-token'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('argocd-token')), 'eyJhbGciOi.token');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(argo.calls, contains('setToken'));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Diffs via argocd-server · token'), findsOneWidget);
  });

  testWidgets('no argocd-server: a quiet hint, no toggles', (tester) async {
    await pumpArgo(tester, fx('app-kustomize-guestbook.json'));
    expect(find.textContaining("wasn't found"), findsOneWidget);
    expect(find.text('Show all diffs'), findsNothing);
  });

  testWidgets('synced app never asks for diffs', (tester) async {
    await pumpArgo(tester, fx('app-guestbook.json'), diffApi: fake());
    expect(argo.calls, isEmpty);
    expect(find.textContaining('Argo CD API'), findsNothing);
  });

  for (final w in [320.0, 760.0]) {
    testWidgets('all diffs open at ${w.toInt()}px: no overflow', (tester) async {
      await pumpArgo(tester, fx('app-helm-guestbook-drift.json'), diffApi: fake(), size: Size(w, 3000));
      await tester.tap(find.text('Show all diffs'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(DiffView), findsNWidgets(2));
    });
    testWidgets('connect strip at ${w.toInt()}px: no overflow', (tester) async {
      await pumpArgo(tester, fx('app-helm-guestbook-drift.json'), diffApi: fake(auth: 'none'), size: Size(w, 2400));
      expect(tester.takeException(), isNull);
    });
  }

  test('cache: refetch only when the revision or reconciledAt changes', () async {
    final api = ApiClient(base: Uri.parse('http://fake'));
    ArgoDiffCache.reset();
    ArgoDiffApi.debugOverride = fake();
    addTearDown(() => ArgoDiffApi.debugOverride = null);
    final app = AppState(api)..currentContext = 'kind-k8sman-dev';
    PanelContext ctxFor(Json obj) => PanelContext(object: obj, type: appType, api: api, app: app);
    final obj = fx('app-helm-guestbook-drift.json');
    await ArgoDiffCache.get(ctxFor(obj));
    // A watch tick that changes health/operation state only.
    final tick = {
      ...obj,
      'status': {...(obj['status'] as Json), 'health': {'status': 'Healthy'}},
    };
    await ArgoDiffCache.get(ctxFor(tick));
    expect(argo.calls.where((c) => c.startsWith('diff')).length, 1);
    final reconciled = {
      ...obj,
      'status': {...(obj['status'] as Json), 'reconciledAt': '2099-01-01T00:00:00Z'},
    };
    await ArgoDiffCache.get(ctxFor(reconciled));
    expect(argo.calls.where((c) => c.startsWith('diff')).length, 2);
  });
}
