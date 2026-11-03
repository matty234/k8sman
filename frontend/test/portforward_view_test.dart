import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/portforward/portforward_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

class _PfApi extends ApiClient {
  _PfApi() : super(base: Uri.parse('http://fake'));
  @override
  Future<List<PortForward>> portForwards() async => [
        PortForward.fromJson({
          'id': 'a', 'context': 'kind-k8sman-dev', 'namespace': 'demo', 'kind': 'service', 'name': 'web', 'port': '80',
          'localPort': 18080, 'state': 'active', 'pod': 'web-6fd47b8fcb-4v4m9', 'remotePort': 8080, 'url': 'http://localhost:18080',
          'autoStart': true, 'label': 'web UI', 'connections': 3, 'reconnects': 1, 'since': '2026-11-03T11:00:00Z',
        }),
        PortForward.fromJson({
          'id': 'b', 'context': 'other', 'namespace': 'demo', 'kind': 'deployment', 'name': 'a-really-long-deployment-name-here', 'port': 'http',
          'localPort': 60725, 'state': 'reconnecting', 'error': 'pod web-xyz went away', 'reconnects': 4,
        }),
      ];
}

void main() {
  testWidgets('port-forward view has no overflow from 360 to 1600px', (tester) async {
    final api = _PfApi();
    final app = AppState(api)..currentContext = 'kind-k8sman-dev';
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (var w = 360.0; w <= 1600; w += 31) {
      tester.view.physicalSize = Size(w, 600);
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
        child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: PortForwardView())),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(tester.takeException(), isNull, reason: 'overflow at width $w');
    }
    await tester.pumpWidget(const SizedBox()); // stop the poll timer
  });
}
