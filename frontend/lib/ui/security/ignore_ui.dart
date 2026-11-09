import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/common.dart';
import 'security_api.dart';
import 'security_widgets.dart';

/// Findings with more objects than this can't be ignored one by one.
const _maxObjectRules = 20;

/// Asks how widely to ignore [finding]. Returns the rules to add (with the
/// reason), or null when cancelled. [visible] are the findings on the page,
/// to say what will disappear.
Future<List<SecIgnoreRule>?> showIgnoreDialog(BuildContext context, SecFinding finding, List<SecFinding> visible) =>
    showDialog<List<SecIgnoreRule>>(context: context, builder: (_) => _IgnoreDialog(finding: finding, visible: visible));

enum _Scope { finding, namespace, everywhere }

class _IgnoreDialog extends StatefulWidget {
  final SecFinding finding;
  final List<SecFinding> visible;
  const _IgnoreDialog({required this.finding, required this.visible});

  @override
  State<_IgnoreDialog> createState() => _IgnoreDialogState();
}

class _IgnoreDialogState extends State<_IgnoreDialog> {
  final _reason = TextEditingController();
  late _Scope _scope = _canFinding ? _Scope.finding : (_canNamespace ? _Scope.namespace : _Scope.everywhere);

  SecFinding get f => widget.finding;
  bool get _canFinding => f.objects.isNotEmpty && f.objects.length <= _maxObjectRules;
  bool get _canNamespace => f.namespace != null;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  List<SecIgnoreRule> _rules() {
    final reason = _reason.text.trim();
    return switch (_scope) {
      _Scope.finding => [for (final o in f.objects) SecIgnoreRule(check: f.check, namespace: o.namespace, kind: o.kind, name: o.name, reason: reason)],
      _Scope.namespace => [SecIgnoreRule(check: f.check, namespace: f.namespace, reason: reason)],
      _Scope.everywhere => [SecIgnoreRule(check: f.check, reason: reason)],
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final rules = _rules();
    final hides = widget.visible.where((v) => ignoredBy(rules, v)).length;
    Widget option(_Scope s, String title, String? detail, bool enabled) => Hoverable(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onTap: enabled ? () => setState(() => _scope = s) : null,
          builder: (_) => Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_scope == s ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 16, color: _scope == s ? theme.colorScheme.primary : theme.hintColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: theme.textTheme.bodyMedium),
                    if (detail != null) Text(detail, style: hint),
                  ]),
                ),
              ]),
            ),
          ),
        );
    final target = f.objects.length == 1 ? '${f.objects.first.kind} ${f.objects.first.name}' : '${f.objects.length} objects';
    return AlertDialog(
      title: const Text('Ignore finding'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(f.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 2),
          Text(f.check, style: monoStyle(context, size: 11).copyWith(color: theme.hintColor)),
          const SizedBox(height: 10),
          option(_Scope.finding, 'This finding', _canFinding ? 'Only for $target; it comes back if another object joins it' : 'Not available: no single target to name', _canFinding),
          option(_Scope.namespace, _canNamespace ? 'This check in ${f.namespace}' : 'This check in a namespace', _canNamespace ? null : 'Not available: this finding is not in a namespace', _canNamespace),
          option(_Scope.everywhere, 'This check everywhere', 'Every finding of this check in this cluster', true),
          const SizedBox(height: 8),
          Text(
            hides == 1 ? 'Hides this finding.' : 'Hides $hides findings now (and future ones that match).',
            key: const ValueKey('ignore-summary'),
            style: hint,
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('ignore-reason'),
            controller: _reason,
            decoration: const InputDecoration(isDense: true, labelText: 'Reason (optional)', hintText: 'e.g. intended for the CI runner'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('ignore-confirm'), onPressed: () => Navigator.pop(context, _rules()), child: const Text('Ignore')),
      ],
    );
  }
}

/// The ignored findings, greyed, with the rule that hides each, its reason
/// and date, and an "Un-ignore" button.
class IgnoredList extends StatelessWidget {
  final List<SecIgnored> items;
  final int Function(SecIgnoreRule rule) coveredBy;
  final void Function(SecFinding finding) onUnignore;
  const IgnoredList({super.key, required this.items, required this.coveredBy, required this.onUnignore});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final it in items)
        Opacity(
          opacity: 0.65,
          child: Padding(
            key: ValueKey('ignored-${it.finding.id}'),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 82, child: SevLabel(it.finding.severity)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(it.finding.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                  Text(
                    [
                      'Ignored ${it.rule.scope}',
                      if (it.rule.reason.isNotEmpty) '"${it.rule.reason}"',
                      if (it.rule.at.length >= 10) it.rule.at.substring(0, 10),
                    ].join(' · '),
                    style: hint,
                  ),
                ]),
              ),
              Tooltip(
                message: coveredBy(it.rule) > 1 ? 'Removes the rule; ${coveredBy(it.rule)} findings return' : 'Show this finding again',
                child: TextButton(
                  key: ValueKey('unignore-${it.finding.id}'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => onUnignore(it.finding),
                  child: const Text('Un-ignore'),
                ),
              ),
            ]),
          ),
        ),
    ]);
  }
}
