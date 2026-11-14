import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/ui/settings/claude_code_setting.dart';
import 'package:provider/provider.dart';

class _McpApi extends ApiClient {
  bool on = false;
  _McpApi() : super(base: Uri.parse('http://mcp.test'));

  McpSettings get _s => McpSettings(enabled: on, command: const ['/k8sman-server', 'mcp'], addCommand: "claude mcp add k8sman -- '/k8sman-server' mcp");

  @override
  Future<McpSettings> getMcpSettings() async => _s;

  @override
  Future<McpSettings> putMcpSettings({bool? enabled, String? folder}) async {
    on = enabled ?? on;
    return _s;
  }
}

void main() {
  testWidgets('turning it on shows the command to add', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Provider<ApiClient>.value(
        value: _McpApi(),
        child: Scaffold(body: Builder(builder: (c) => claudeCodeSetting().builder(c))),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('claude-code-copy')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('claude-code-switch')));
    await tester.pump();
    expect(find.textContaining('claude mcp add'), findsOneWidget);
    expect(find.byKey(const ValueKey('claude-code-copy')), findsOneWidget);
  });
}
