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
                Expanded(child: KeyboardShortcutGroup('Navigation', _navigation)),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [KeyboardShortcutGroup('Actions', _actions), const SizedBox(height: 16), KeyboardShortcutGroup('App', _app)],
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
  (':', 'Command mode: :po, :ns <name>, :ctx, :view [save <name>]'),
  ('/  ${shortcutLabel('F')}', 'Filter the table: status=x  !text  /regex/'),
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
  (shortcutLabel('['), 'Back (also the mouse back button)'),
  (shortcutLabel(']'), 'Forward'),
  (shortcutLabel('S'), 'Save the table as a view / update the open view'),
  (shortcutLabel(','), 'Settings'),
  ('?', 'This help'),
];

/// The groups of [showKeyboardHelp], for Settings ▸ Keyboard too: (title,
/// [(keys, what it does)]).
List<(String, List<(String, String)>)> get keyboardShortcutGroups => [('Navigation', _navigation), ('Actions', _actions), ('App', _app)];

/// A titled list of shortcuts: keys on the left, what they do on the right.
class KeyboardShortcutGroup extends StatelessWidget {
  final String? title;
  final List<(String, String)> rows;
  const KeyboardShortcutGroup(this.title, this.rows, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(title!, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor)),
          const SizedBox(height: 6),
        ],
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
