import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/modules/modules.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/palette/palette_commands.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/ui/widgets/page_mode_switch.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

void main() {
  testWidgets(':nodes and :no open the Nodes page; the Table toggle sticks and replaces history', (tester) async {
    final api = FakeApiClient();
    const node = ResourceType(group: '', version: 'v1', resource: 'nodes', kind: 'Node', namespaced: false, shortNames: ['no']);
    final app = AppState(api)
      ..types = [for (final t in testTypes) t.kind == 'Node' ? node : t]
      ..kindHomes = kindHomes;
    app.selectType(testType('', 'Pod'));

    void run(String cmd) => rankCommand(cmd, app).sections.first.items.first.run();
    run('no');
    expect((app.view, app.selectedType), (MainView.nodes, testType('', 'Pod')), reason: ':no is the Nodes page, Overview by default');

    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: Center(child: PageModeSwitch(page: MainView.nodes)))),
    ));
    await tester.tap(find.byKey(const ValueKey('page-mode-table')));
    await tester.pump();
    expect((app.view, app.selectedType), (MainView.resources, node), reason: 'Table mode is the Node table');
    expect(app.activeHomePage, MainView.nodes);

    // Back skips the switch (a replace) to the Pod table.
    app.navBack();
    expect((app.view, app.selectedType), (MainView.resources, testType('', 'Pod')));

    // The mode is remembered: the page, the kind and `:nodes` open the table.
    run('nodes');
    expect((app.view, app.selectedType), (MainView.resources, node));
    app.showView(MainView.overview);
    app.selectType(node);
    expect(app.view, MainView.resources);

    app.setPageMode(MainView.nodes, table: false);
    expect(app.tablePrefs.of(node.gk).mode, '');
    app.selectType(node);
    expect(app.view, MainView.nodes);
    // A filtered table (the Overview's "2 nodes not ready") is the table.
    app.openTable('', 'Node', filter: 'status=NotReady');
    expect(app.view, MainView.resources);
  });
}
