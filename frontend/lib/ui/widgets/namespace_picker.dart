import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import 'searchable_picker.dart';

/// The toolbar namespace filter (drives [AppState.namespace]): a searchable
/// popover with "All namespaces", recently used namespaces, then all of them.
class NamespacePicker extends StatelessWidget {
  /// Button height; the toolbar uses 26.
  final double height;
  const NamespacePicker({super.key, this.height = 26});

  static const _all = '\u0000all';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final ns = app.namespace;
    return SearchablePicker<String>(
      key: const ValueKey('namespace-picker'),
      tooltip: 'Namespace',
      hint: 'Search namespaces',
      selected: ns ?? _all,
      pinned: () => const [PickerOption(_all, 'All namespaces')],
      recents: () => [
        for (final n in app.recentNamespaces)
          if (app.namespaces.contains(n)) PickerOption(n, n),
      ],
      items: () => [for (final n in app.namespaces) PickerOption(n, n)],
      onSelected: (v) => app.setNamespace(v == _all ? null : v),
      builder: (h) => Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: theme.inputDecorationTheme.fillColor?.withValues(alpha: h ? 0.14 : null),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Icon(Icons.folder_outlined, size: 14, color: theme.hintColor),
          const SizedBox(width: 6),
          Expanded(child: Text(ns ?? 'All namespaces', overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.bodyMedium)),
          Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
        ]),
      ),
    );
  }
}
