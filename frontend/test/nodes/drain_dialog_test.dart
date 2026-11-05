import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/nodes/drain_dialog.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

class _DrainApi extends ApiClient {
  _DrainApi() : super(base: Uri.parse('http://fake'));
  final plans = <String>[];
  final drains = <String>[];
  DrainResult result = const DrainResult(node: 'worker-1', evicted: ['demo/bare', 'demo/web-abc']);

  @override
  Future<DrainPlan> drainPlan(String node, {bool deleteEmptyDirData = false, bool force = false}) async {
    plans.add('$node emptyDir=$deleteEmptyDirData force=$force');
    return DrainPlan(
      node: node,
      evict: ['demo/web-abc', if (force) 'demo/bare'],
      warnings: const ['ignoring DaemonSet-managed Pods: demo/agent-xyz'],
      blockers: [if (!force) 'cannot delete cannot delete Pods that declare no controller (use --force to override): demo/bare'],
    );
  }

  @override
  Future<DrainResult> drainNode(String node, {bool deleteEmptyDirData = false, bool force = false, int timeoutSeconds = 300}) async {
    drains.add('$node emptyDir=$deleteEmptyDirData force=$force');
    return result;
  }
}

Future<void> _open(WidgetTester tester, _DrainApi api, ValueChanged<DrainResult?> done) async {
  await tester.pumpWidget(Provider<ApiClient>.value(
    value: api,
    child: MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () async => done(await showDrainDialog(context, 'worker-1')), child: const Text('go')))),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('plan follows the options; blockers disable Drain; success closes with a snackbar', (tester) async {
    final api = _DrainApi();
    DrainResult? got;
    await _open(tester, api, (r) => got = r);

    expect(find.text('Will evict 1 pod:'), findsOneWidget);
    expect(find.textContaining('demo/agent-xyz'), findsOneWidget, reason: 'DaemonSet pods are listed as skipped');
    expect(find.textContaining('no controller'), findsOneWidget);
    FilledButton drainButton() => tester.widget<FilledButton>(find.byKey(const ValueKey('drain-confirm')));
    expect(drainButton().onPressed, isNull, reason: 'blocked until --force');

    await tester.tap(find.byKey(const ValueKey('drain-force')));
    await tester.pumpAndSettle();
    expect(api.plans.last, 'worker-1 emptyDir=false force=true');
    expect(find.text('Will evict 2 pods:'), findsOneWidget);
    expect(drainButton().onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('drain-confirm')));
    await tester.pumpAndSettle();
    expect(api.drains, ['worker-1 emptyDir=false force=true']);
    expect(got?.evicted, hasLength(2));
    expect(find.text('Drained worker-1: evicted 2 pods'), findsOneWidget);
  });

}
