import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/app/backend.dart';
import 'package:k8sman/app/kubeconfig_picker.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

const _backend = MethodChannel('k8sman/backend');

class _KubeconfigApi extends ApiClient {
  final switched = <String>[];
  _KubeconfigApi() : super(base: Uri.parse('http://fake'));

  @override
  Future<KubeconfigList> kubeconfigs() async => KubeconfigList.fromJson({
        'current': '/Users/me/.kube/config',
        'home': '/Users/me',
        'candidates': [
          {'path': '/Users/me/.kube/config', 'contexts': ['a', 'b', 'c'], 'source': 'default'},
          {'path': '/Users/me/.kube/staging', 'contexts': ['s'], 'source': 'kube-dir'},
          {'path': '/tmp/gone', 'contexts': [], 'source': 'recent', 'error': 'no such file'},
        ],
      });

  @override
  Future<KubeconfigList> switchKubeconfig(String path) async {
    switched.add(path);
    return kubeconfigs();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('embedded backend: starting, failure with log, then connect on retry', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final messenger = tester.binding.defaultBinaryMessenger;
    var restarted = 0;
    messenger.setMockMethodCallHandler(_backend, (call) async {
      if (call.method == 'start') return {'state': 'starting'};
      if (call.method == 'restart') restarted++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_backend, null));
    Future<void> push(Map<String, Object?> status) => messenger.handlePlatformMessage(
        'k8sman/backend', const StandardMethodCodec().encodeMethodCall(MethodCall('status', status)), (_) {});

    final api = ApiClient(base: Uri.parse('http://127.0.0.1:7443'));
    var readyCalls = 0;
    final backend = BackendController(api, onReady: () => readyCalls++);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: backend,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const BackendGate(child: Text('APP'))),
    ));
    await backend.start();
    await tester.pump();
    expect(find.text('Starting backend…'), findsOneWidget);
    expect(find.text('APP'), findsNothing);

    await push({'state': 'failed', 'error': 'The backend exited with status 1.', 'log': 'line one\nfatal: boom'});
    await tester.pump();
    expect(find.text('The k8sman backend could not start'), findsOneWidget);
    expect(find.textContaining('fatal: boom'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(restarted, 1);

    await push({'state': 'running', 'url': 'http://127.0.0.1:61234'});
    await tester.pump();
    expect(find.text('APP'), findsOneWidget);
    expect(api.base.port, 61234);
    expect(readyCalls, 1);

    // A crash after connecting shows a banner over the app, and the new
    // port is picked up on restart.
    await push({'state': 'restarting', 'error': 'The backend exited with status 2.'});
    await tester.pump();
    expect(find.text('APP'), findsOneWidget);
    expect(find.textContaining('restarting'), findsOneWidget);
    await push({'state': 'running', 'url': 'http://127.0.0.1:61235'});
    await tester.pump();
    expect(api.base.port, 61235);
    expect(readyCalls, 2);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('kubeconfig picker lists candidates and switches', (tester) async {
    final api = _KubeconfigApi();
    final app = AppState(api);
    await app.loadKubeconfigs();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: SizedBox(width: 232, child: KubeconfigPicker())),
      ),
    ));
    expect(find.text('~/.kube/config'), findsOneWidget);
    await tester.tap(find.byType(KubeconfigPicker));
    await tester.pumpAndSettle();
    expect(find.text('3 contexts'), findsOneWidget);
    expect(find.text('1 context'), findsOneWidget);
    expect(find.text('no such file'), findsOneWidget);
    expect(find.text('Choose file…'), findsOneWidget);
    expect(find.text('Reveal in Finder'), findsOneWidget);
    await tester.tap(find.text('~/.kube/staging'));
    await tester.pumpAndSettle();
    expect(api.switched, ['/Users/me/.kube/staging']);
  });

}
