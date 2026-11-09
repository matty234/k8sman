import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

/// Overview | Table, beside the title of a page that is a kind's home (the
/// Nodes page): Table shows the kind's table in place, with its filter,
/// sorting, selection, keys and saved views. See [AppState.setPageMode].
class PageModeSwitch extends StatelessWidget {
  final MainView page;
  const PageModeSwitch({super.key, required this.page});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final table = context.select<AppState, bool>((a) => a.view == MainView.resources);
    final theme = Theme.of(context);
    return SizedBox(
      height: 24,
      child: SegmentedButton<bool>(
        key: const ValueKey('page-mode'),
        style: ButtonStyle(
          visualDensity: const VisualDensity(horizontal: -3, vertical: -4),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
          minimumSize: const WidgetStatePropertyAll(Size(0, 24)),
          textStyle: WidgetStatePropertyAll(theme.textTheme.labelMedium),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: false, label: Text('Overview', key: ValueKey('page-mode-overview'))),
          ButtonSegment(value: true, label: Text('Table', key: ValueKey('page-mode-table'))),
        ],
        selected: {table},
        onSelectionChanged: (s) => app.setPageMode(page, table: s.first),
      ),
    );
  }
}
