import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/panel.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/portforward/portforward_dialog.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

class _PfApi extends FakeApiClient {
  final calls = <(int, bool)>[];
  @override
  Future<PortForward> createPortForward({
    required String namespace,
    required String kind,
    required String name,
    required String port,
    int localPort = 0,
    bool autoStart = false,
    String? label,
    bool replace = false,
  }) async {
    calls.add((localPort, replace));
    if (!replace && localPort == 8080) {
      throw ApiException(409, 'in use', reason: 'LocalPortInUse', usedBy: 'demo/pod/old:80', suggestedPort: 8081);
    }
    return PortForward(id: 'x', context: 'kind', namespace: namespace, kind: kind, name: name, port: port, localPort: localPort, state: 'active');
  }
}

void main() {
  testWidgets('start dialog offers to replace the forward holding the local port', (tester) async {
    final api = _PfApi();
    final pod = Map<String, dynamic>.from(jsonDecode(File('../dev/fixtures/pod-web.json').readAsStringSync()));
    final app = AppState(api)..types = testTypes;
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPortForwardDialog(context, PanelContext(object: pod, type: testType('', 'Pod'), api: api, app: app)),
            child: const Text('open'),
          ),
        )),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start forwarding'));
    await tester.pumpAndSettle();
    expect(find.text('Port 8080 is used by demo/pod/old:80.'), findsOneWidget);
    expect(find.text('Use 8081 instead'), findsOneWidget);
    await tester.tap(find.text('Replace it'));
    await tester.pumpAndSettle();
    expect(api.calls, [(8080, false), (8080, true)]);
    expect(find.text('Replace it'), findsNothing);
  });
}
