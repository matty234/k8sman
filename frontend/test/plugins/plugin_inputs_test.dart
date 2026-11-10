import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/plugins/plugin_actions.dart';
import 'package:k8sman/plugins/plugin_api.dart';
import 'package:k8sman/ui/theme.dart';

/// A patch action's form: defaults filled in, a wrong type caught before
/// the dry run, the backend's refusal (the plugin's validateMessage) shown
/// inline with the form kept open, and a passing dry run closing it with
/// the typed values and the preview.
void main() {
  testWidgets('plugin patch inputs', (tester) async {
    const action = PluginAction(
      plugin: 'demo',
      id: 'resize',
      label: 'Resize…',
      type: 'patch',
      inputs: [
        PluginInput(name: 'size', label: 'Size', type: 'int', defaultValue: 3),
        PluginInput(name: 'mode', label: 'Mode', type: 'enum', options: ['fast', 'safe'], defaultValue: 'safe'),
        PluginInput(name: 'note', label: 'Note', defaultValue: 'hi'),
      ],
    );
    final sent = <Map<String, Object?>>[];
    Object? closed;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            closed = await showDialog<Object?>(
              context: context,
              builder: (_) => PluginInputsDialog(
                action: action,
                submit: (values) async {
                  sent.add(values);
                  if (values['size'] == 50) throw ApiException(400, 'At most 10.');
                  return const ActionResult(message: 'Dry run OK', dryRun: true, preview: ActionPreview(before: 'size: 3', after: 'size: 7'));
                },
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Resize'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('safe'), findsOneWidget);

    // Not a whole number: refused in the form, nothing sent.
    await tester.enterText(find.byKey(const ValueKey('plugin-input-size')), '');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a whole number.'), findsOneWidget);
    expect(sent, isEmpty);

    // The backend refuses: its message shows, the form stays.
    await tester.enterText(find.byKey(const ValueKey('plugin-input-size')), '50');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plugin-inputs-error')), findsOneWidget);
    expect(find.text('At most 10.'), findsOneWidget);
    expect(sent.single, {'size': 50, 'mode': 'safe', 'note': 'hi'});

    // A passing dry run closes the form with the values and the preview.
    await tester.enterText(find.byKey(const ValueKey('plugin-input-size')), '7');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.byType(PluginInputsDialog), findsNothing);
    final r = closed as ({Map<String, Object?> values, ActionResult preview});
    expect(r.values, {'size': 7, 'mode': 'safe', 'note': 'hi'});
    expect(r.preview.preview?.after, 'size: 7');
  });
}
