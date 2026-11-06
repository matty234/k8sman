import 'package:flutter/material.dart';

import 'keys.dart';
import 'theme.dart';

/// The `?` overlay: every keyboard binding, in three groups.
Future<void> showKeyboardHelp(BuildContext context) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('keyboard-help'),
        title: const Text('Keyboard shortcuts'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _Group('Navigation', _navigation)),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [_Group('Actions', _actions), const SizedBox(height: 16), _Group('App', _app)],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );

final _navigation = [
  (':', 'Command mode: :po, :ns <name>, :ctx'),
  ('/  ${shortcutLabel('F')}', 'Filter the table'),
  ('j / k  ↑ / ↓', 'Move the selection'),
  ('g / G', 'First / last row'),
  ('Enter', 'Open in the inspector'),
  ('Esc', 'Leave the filter, clear, close'),
];

final _actions = [
  ('l', 'Logs (merged for workloads / 2+ pods)'),
  ('s', 'Shell'),
  ('d', 'Overview'),
  ('y', 'YAML'),
  ('e', 'Edit YAML'),
  ('⇧F', 'Port-forward'),
  ('Ctrl+D', 'Delete'),
];

final _app = [
  (shortcutLabel('K'), 'Command palette'),
  (shortcutLabel('J'), 'Bottom dock'),
  (shortcutLabel('I'), 'Inspector'),
  ('?', 'This help'),
];

class _Group extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;
  const _Group(this.title, this.rows);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor)),
        const SizedBox(height: 6),
        for (final (keys, what) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 96, child: Text(keys, style: monoStyle(context, size: 12))),
                Expanded(child: Text(what, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}
