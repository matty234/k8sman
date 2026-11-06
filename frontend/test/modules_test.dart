import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/modules/helm_module.dart';
import 'package:k8sman/ui/palette/palette_commands.dart';
import 'package:k8sman/ui/palette/palette_sources.dart';
import 'package:k8sman/ui/shell.dart';

import 'support/fixture_api.dart';

void main() {
  testWidgets('a turned-off integration leaves the sidebar and the palette', (tester) async {
    final (app, _) = await pumpShell(tester, FixtureApi());
    app.setSidebar(app.sidebar.setHidden(HelmModule.page, false)); // out from under More
    await tester.pump();
    final helmNav = find.byKey(const ValueKey('nav-view-helm'));
    List<String> palette() => [for (final i in paletteItems(tester.element(find.byType(Shell)))) i.title];
    List<String> command(String c) => [for (final s in rankCommand(c, app).sections) ...s.items.map((i) => i.title)];
    expect(helmNav, findsOneWidget);
    expect(palette(), containsAll(['Helm', 'Add-ons']));
    expect(command('helm'), contains('Helm'));

    app.setDisabledModules({'helm'});
    await tester.pump();
    expect(helmNav, findsNothing);
    expect(palette(), isNot(contains('Helm')));
    expect(palette(), isNot(contains('Add-ons')), reason: 'Add-ons installs through Helm');
    expect(command('helm'), isNot(contains('Helm')));
    expect(palette(), contains('Overview'));
  });
}
