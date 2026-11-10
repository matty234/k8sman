import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/logs/stream_logs_dialog.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

class _Api extends FakeApiClient {
  final requests = <String>[];
  _Api(List<Json> pods) : super(itemsByResource: {'pods': pods});

  @override
  Stream<AggregateMessage> aggregateLogs({
    NamespaceScope scope = NamespaceScope.all,
    List<String> selectors = const [],
    List<String>? pods,
    String? podRegex,
    String? containerRegex,
    String? container,
    int tailLines = 200,
    bool follow = true,
    bool previous = false,
    int? sinceSeconds,
  }) {
    requests.add('ns=${scope.namespaces.join(',')} podRegex=$podRegex container=$container');
    return const Stream.empty();
  }
}

Json _pod(String ns, String name) => {
  'metadata': {'name': name, 'namespace': ns},
  'spec': {
    'containers': [
      {'name': 'app'},
    ],
  },
};

void main() {
  testWidgets('the dialog previews the pods a regex matches and opens one merged tab', (tester) async {
    final api = _Api([_pod('default', 'web-1'), _pod('demo', 'web-2'), _pod('default', 'api-1')]);
    final app = AppState(api)..types = testTypes;
    final dock = LogDock(api);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<LogDock>.value(value: dock),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(builder: (context) => TextButton(onPressed: () => showStreamLogsDialog(context), child: const Text('open'))),
          ),
        ),
      ),
    );
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('3 pods match'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('stream-pod-regex')), '^web-');
    await tester.pumpAndSettle();
    expect(find.text('2 pods match'), findsOneWidget);
    expect(find.text('default/web-1'), findsOneWidget); // all namespaces: labelled with theirs
    expect(find.text('demo/web-2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stream-open')));
    await tester.pumpAndSettle();
    final tab = dock.tabs.single as AggregateLogStream;
    expect(tab.title, '~^web-');
    expect(tab.qualified, isTrue);
    expect(api.requests, ['ns= podRegex=^web- container=null']);
    await tester.pump(const Duration(seconds: 3)); // the tab's "quiet workload" timer
  });
}
