import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/table_prefs.dart';
import '../theme.dart';
import 'settings_widgets.dart';

/// Settings ▸ Tables: the kinds whose tables remember a sort, column
/// widths or a filter, each with Reset.
List<SettingItem> tableSettings() => [
      SettingItem(
        key: const ValueKey('settings-tables'),
        label: 'Saved table layouts',
        description: 'Reset a kind\'s table to its default sort and widths, with no filter. Columns themselves are edited from the table.',
        keywords: const ['table', 'tables', 'columns', 'column', 'width', 'widths', 'sort', 'filter', 'reset'],
        builder: (_) => const _TablePrefsList(),
      ),
    ];

class _TablePrefsList extends StatefulWidget {
  const _TablePrefsList();

  @override
  State<_TablePrefsList> createState() => _TablePrefsListState();
}

class _TablePrefsListState extends State<_TablePrefsList> {
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final faint = theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint);
    final store = app.tablePrefs;
    final kinds = store.savedKinds;
    return SettingRow(
      label: 'Saved table layouts',
      description: 'Reset a kind\'s table to its default sort and widths, with no filter. Columns themselves are edited from the table.',
      trailing: TextButton(
        key: const ValueKey('tables-reset-all'),
        onPressed: kinds.isEmpty ? null : () => setState(store.resetAll),
        child: const Text('Reset All'),
      ),
      child: kinds.isEmpty
          ? const SettingsEmpty('No table has a saved sort, widths or filter.')
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final k in kinds)
                SizedBox(
                  height: 34,
                  child: Row(children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: _kindLabel(app, k)),
                          TextSpan(text: '   ${_summary(store.of(k))}', style: faint),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    TextButton(key: ValueKey('tables-reset-$k'), onPressed: () => setState(() => store.reset(k)), child: const Text('Reset')),
                  ]),
                ),
            ]),
    );
  }

  /// "Deployment" for "apps/Deployment", with the group when the cluster
  /// doesn't serve it ("Widget · example.dev").
  static String _kindLabel(AppState app, String gk) {
    final i = gk.lastIndexOf('/');
    final (group, kind) = i < 0 ? ('', gk) : (gk.substring(0, i), gk.substring(i + 1));
    if (app.typeFor(group, kind) != null || group.isEmpty) return kind;
    return '$kind · $group';
  }

  static String _summary(TablePrefs p) => [
        if (p.sortColumn != null) 'sorted by ${p.sortColumn}${p.sortDescending ? ' ↓' : ' ↑'}',
        if (p.widths.isNotEmpty) '${p.widths.length} column width${p.widths.length == 1 ? '' : 's'}',
        if (p.filter.isNotEmpty) 'filter “${p.filter}”',
      ].join(' · ');
}
