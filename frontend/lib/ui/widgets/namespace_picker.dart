import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import 'searchable_picker.dart';

/// A searchable namespace popover with "All namespaces", recently used
/// namespaces, then all of them.
///
/// By default it is the toolbar filter and drives [AppState.namespace]. Pass
/// [onChanged] to use it for a page's own scope (see [PageScope]) instead:
/// it then shows [value] and leaves the table's namespace alone.
class NamespacePicker extends StatelessWidget {
  /// Button height; the toolbar uses 26.
  final double height;

  /// The selected namespace when [onChanged] is set (null = all).
  final String? value;
  final ValueChanged<String?>? onChanged;
  const NamespacePicker({super.key, this.height = 26}) : value = null, onChanged = null;

  /// A page-scope picker (independent of [AppState.namespace]).
  const NamespacePicker.scope({super.key, required this.value, required ValueChanged<String?> this.onChanged, this.height = 26});

  static const _all = '\u0000all';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final scoped = onChanged != null;
    final ns = scoped ? value : app.namespace;
    return SearchablePicker<String>(
      key: ValueKey(scoped ? 'page-scope-picker' : 'namespace-picker'),
      tooltip: scoped ? 'Scope' : 'Namespace',
      hint: 'Search namespaces',
      selected: ns ?? _all,
      pinned: () => const [PickerOption(_all, 'All namespaces')],
      recents: () => [
        for (final n in app.recentNamespaces)
          if (app.namespaces.contains(n)) PickerOption(n, n),
      ],
      items: () => [for (final n in app.namespaces) PickerOption(n, n)],
      onSelected: (v) => (onChanged ?? app.setNamespace)(v == _all ? null : v),
      builder: (h) => Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: theme.inputDecorationTheme.fillColor?.withValues(alpha: h ? 0.14 : null),
          borderRadius: BorderRadius.circular(6),
        ),
        child: LayoutBuilder(
          // Squeezed (e.g. a page header at 360px): just the folder icon.
          builder: (context, box) => box.maxWidth < 60
              ? Center(child: Icon(Icons.folder_outlined, size: 14, color: theme.hintColor))
              : Row(children: [
                  Icon(Icons.folder_outlined, size: 14, color: theme.hintColor),
                  const SizedBox(width: 6),
                  Expanded(child: Text(ns ?? 'All namespaces', overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.bodyMedium)),
                  Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
                ]),
        ),
      ),
    );
  }
}

/// Each page's own namespace scope (null = all namespaces), independent of
/// the table's [AppState.namespace] and remembered for the session.
class PageScope {
  PageScope._();
  static final _scopes = <String, String?>{};

  static String? of(String page) => _scopes[page];
  static void set(String page, String? namespace) => _scopes[page] = namespace;

  /// Tests: forget every page's scope.
  @visibleForTesting
  static void reset() => _scopes.clear();
}

/// The page-scope picker sized for the [PageHeader] subtitle slot.
class PageScopePicker extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  const PageScopePicker({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => SizedBox(width: 200, child: NamespacePicker.scope(value: value, onChanged: onChanged));
}
