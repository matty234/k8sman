import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/state/startup_gate.dart';
import 'package:k8sman/ui/widgets/group_icon.dart';
import 'package:provider/provider.dart';

class _IconApi extends ApiClient {
  final calls = <String>[];
  _IconApi() : super(base: Uri.parse('http://fake'));
  @override
  Future<Uint8List?> groupIcon(String group) async {
    calls.add(group);
    return null;
  }
}

void main() {
  setUp(() {
    StartupGate.reset();
    GroupIconCache.clear();
  });
  tearDown(StartupGate.open);

  Future<_IconApi> pumpIcon(WidgetTester tester) async {
    final api = _IconApi();
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: api,
      child: const Directionality(textDirection: TextDirection.ltr, child: Center(child: GroupIcon(group: 'traefik.io'))),
    ));
    await tester.pump();
    return api;
  }

  testWidgets('while held, icon fetches wait for the first table to paint', (tester) async {
    StartupGate.hold();
    final api = await pumpIcon(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(api.calls, isEmpty);
    StartupGate.firstContentShown();
    expect(api.calls, isEmpty, reason: 'not before that frame is drawn');
    await tester.pump();
    await tester.pump();
    expect(api.calls, ['traefik.io']);
  });

}
