import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/kubeconfig.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/table_controller.dart';
import 'package:provider/provider.dart';

import 'support/table_fakes.dart';

TableController _table(WidgetTester tester) =>
    Provider.of<TableController>(tester.element(find.byKey(const ValueKey('table-title'))), listen: false);

void main() {
  testWidgets('a saved view reopens with its kind, namespaces, filter, sort and columns', (tester) async {
    const viewColumns = [ColumnDef(name: 'Namespace', query: '.metadata.namespace'), ColumnDef(name: 'Pod', query: '.metadata.name')];
    final api = TableFakeApi();
    // The table shows the columns the watch asked for (a view's), else the kind's.
    api.onWatch = () => [
          WatchMessage(
            type: 'SNAPSHOT',
            table: TableData(
              resource: podType,
              columns: api.lastWatchColumns ?? testColumns,
              isDefaultColumns: api.lastWatchColumns == null,
              resourceVersion: '1',
              rows: [fakeRow('web-1'), fakeRow('api-1', ns: 'kube-system')],
            ),
          ),
        ];
    final app = await pumpTable(tester, api, podType);
    app.types = [podType, deployType];
    app.selectType(podType);
    app.setNamespaceScope(NamespaceScope.of(['demo', 'kube-system']));
    await tester.pump();
    await tester.pump();
    _table(tester)
      ..setFilter('web')
      ..sortBy(1)
      ..sortBy(1); // Namespace, descending
    await tester.pump();

    // Save from the toolbar: "any context" is the default.
    await tester.tap(find.byKey(const ValueKey('table-save-view')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('save-view-name')), 'My pods');
    await tester.tap(find.byKey(const ValueKey('save-view-save')));
    await tester.pumpAndSettle();
    expect(api.views, hasLength(1));
    final saved = SavedView.fromJson(api.views.single)!;
    expect(saved.context, isNull, reason: 'new views apply to any context');
    expect(saved.namespaces, ['demo', 'kube-system']);
    expect(saved.filter, 'web');
    expect((saved.sortColumn, saved.sortDescending), ('Namespace', true));

    // The view keeps its own columns (independent of the kind's).
    await app.saveView(saved.copyWith(columns: () => viewColumns));

    // Leave it: another kind, all namespaces.
    app.selectType(deployType);
    app.setNamespace(null);
    await tester.pump();

    // Reopen.
    app.selectType(podType);
    await tester.pump();
    await app.openView(app.savedViews.single);
    await tester.pump();
    await tester.pump();
    final tc = _table(tester);
    expect(app.selectedType, podType);
    expect(app.namespaceScope, NamespaceScope.of(['demo', 'kube-system']));
    expect(api.lastWatchScope, NamespaceScope.of(['demo', 'kube-system']));
    expect(tc.filter, 'web');
    expect(tc.columns.map((c) => c.name), ['Namespace', 'Pod']);
    expect(api.lastWatchColumns?.map((c) => c.name), ['Namespace', 'Pod']);
    expect((tc.columns[tc.sortColumn!].name, tc.sortAscending), ('Namespace', false));
    expect(find.text('My pods'), findsOneWidget, reason: 'the title names the open view');
    expect(find.byKey(const ValueKey('view-modified-dot')), findsNothing);

    // A change marks the view modified; Revert restores it.
    tc.setFilter('api');
    await tester.pump();
    expect(find.byKey(const ValueKey('view-modified-dot')), findsOneWidget);
    expect(app.tablePrefs.of(podType.gk).filter, 'web', reason: "a view session never writes the kind's prefs");
    await tester.tap(find.byKey(const ValueKey('view-revert')));
    await tester.pump();
    await tester.pump();
    expect(_table(tester).filter, 'web');

    // Narrow (an inspector beside the table): one menu button, no overflow.
    _table(tester).setFilter('api');
    for (final w in [360.0, 400.0, 500.0, 640.0, 800.0, 1200.0]) {
      await tester.binding.setSurfaceSize(Size(w, 600));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'toolbar at $w');
      expect(find.byKey(ValueKey(w <= 640 ? 'view-changes-menu' : 'view-update')), findsOneWidget, reason: 'at $w');
    }
    await tester.binding.setSurfaceSize(null);
  });

  test('a view matches the active kubeconfig by its resolved key, and an undone delete returns to its place', () async {
    final api = TableFakeApi()..kubeconfigKeys = {'': '/home/me/.kube/config', '/home/me/.kube/config': '/home/me/.kube/config', '/elsewhere': '/elsewhere'};
    final app = AppState(api)
      ..currentContext = 'dev'
      ..kubeconfigs = const KubeconfigList(current: '', currentKey: '/home/me/.kube/config');
    SavedView view(String id, {String? kubeconfig}) => SavedView(
          id: id,
          name: id,
          group: 'apps',
          kind: 'Deployment',
          context: kubeconfig == null ? null : ViewContext(kubeconfig: kubeconfig, name: 'dev'),
        );
    for (final v in [view('a'), view('b', kubeconfig: '/home/me/.kube/config'), view('c', kubeconfig: '/elsewhere'), view('d', kubeconfig: '')]) {
      await app.saveView(v);
    }
    await app.loadViews();
    // The default kubeconfig and the same file picked explicitly are one context.
    expect([for (final v in app.savedViews) if (v.context != null) app.isCurrentContext(v.context!)], [true, false, true]);

    final removed = (await app.deleteView('b'))!;
    await app.restoreView(removed.$1, removed.$2);
    await app.loadViews();
    expect([for (final v in app.savedViews) v.id], ['a', 'b', 'c', 'd']);
    expect([for (final v in api.views) v['id']], ['a', 'b', 'c', 'd']);
  });
}
