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
    showBulkIgnoreDialog(context, [finding], visible);

/// [showIgnoreDialog] for several findings at once (a selection).
Future<List<SecIgnoreRule>?> showBulkIgnoreDialog(BuildContext context, List<SecFinding> findings, List<SecFinding> visible) =>
    showDialog<List<SecIgnoreRule>>(context: context, builder: (_) => _IgnoreDialog(findings: findings, visible: visible));

enum _Scope { finding, namespace, everywhere }

bool _canTarget(SecFinding f) => f.objects.isNotEmpty && f.objects.length <= _maxObjectRules;

class _IgnoreDialog extends StatefulWidget {
  final List<SecFinding> findings;
  final List<SecFinding> visible;
  const _IgnoreDialog({required this.findings, required this.visible});

  @override
  State<_IgnoreDialog> createState() => _IgnoreDialogState();
}

class _IgnoreDialogState extends State<_IgnoreDialog> {
  final _reason = TextEditingController();
  late _Scope _scope = _canFinding ? _Scope.finding : (_canNamespace ? _Scope.namespace : _Scope.everywhere);

  List<SecFinding> get fs => widget.findings;
  SecFinding get f => fs.first;
  bool get _single => fs.length == 1;

  /// Several findings: "these findings" always works, those that can't be
  /// named object by object falling back to their check in their namespace
  /// (or everywhere, outside one).
  bool get _canFinding => _single ? _canTarget(f) : true;
  bool get _canNamespace => fs.every((f) => f.namespace != null);
  int get _broadened => _single ? 0 : fs.where((f) => !_canTarget(f)).length;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  List<SecIgnoreRule> _rules() {
    final reason = _reason.text.trim();
    final out = <SecIgnoreRule>[];
    void add(SecIgnoreRule r) {
      if (!out.any((o) => o.sameTarget(r))) out.add(r);
    }
    for (final f in fs) {
      switch (_scope) {
        case _Scope.finding when _canTarget(f):
          for (final o in f.objects) {
            add(SecIgnoreRule(check: f.check, namespace: o.namespace, kind: o.kind, name: o.name, reason: reason));
          }
        case _Scope.finding || _Scope.namespace:
          add(SecIgnoreRule(check: f.check, namespace: f.namespace, reason: reason));
        case _Scope.everywhere:
          add(SecIgnoreRule(check: f.check, reason: reason));
      }
    }
    return out;
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
    final checks = {for (final f in fs) f.check};
    final namespaces = {for (final f in fs) ?f.namespace};
    final List<Widget> options;
    if (_single) {
      options = [
        option(_Scope.finding, 'This finding', _canFinding ? 'Only for $target; it comes back if another object joins it' : 'Not available: no single target to name', _canFinding),
        option(_Scope.namespace, _canNamespace ? 'This check in ${f.namespace}' : 'This check in a namespace', _canNamespace ? null : 'Not available: this finding is not in a namespace', _canNamespace),
        option(_Scope.everywhere, 'This check everywhere', 'Every finding of this check in this cluster', true),
      ];
    } else {
      final b = _broadened;
      options = [
        option(_Scope.finding, 'These ${fs.length} findings',
            'Only their current objects; each comes back if another object joins it${b == 0 ? '' : ' ($b with too many objects to name: their check in their namespace)'}', true),
        option(_Scope.namespace, checks.length == 1 && namespaces.length == 1 ? 'This check in ${namespaces.single}' : 'Their checks in their namespaces',
            _canNamespace ? '${checks.length} ${checks.length == 1 ? 'check' : 'checks'} in ${namespaces.length} ${namespaces.length == 1 ? 'namespace' : 'namespaces'}' : 'Not available: some are not in a namespace',
            _canNamespace),
        option(_Scope.everywhere, checks.length == 1 ? 'This check everywhere' : 'Their ${checks.length} checks everywhere', 'Every finding of ${checks.length == 1 ? 'this check' : 'these checks'} in this cluster', true),
      ];
    }
    return AlertDialog(
      title: Text(_single ? 'Ignore finding' : 'Ignore ${fs.length} findings'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_single) ...[
            Text(f.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 2),
            Text(f.check, style: monoStyle(context, size: 11).copyWith(color: theme.hintColor)),
          ] else ...[
            for (final x in fs.take(4)) Text('•  ${x.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
            if (fs.length > 4) Text('…and ${fs.length - 4} more', style: hint),
          ],
          const SizedBox(height: 10),
          ...options,
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
                  Text.rich(
                    TextSpan(children: [
                      if (it.rule.byClaude)
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Tooltip(
                              message: 'Ignored by Claude Code through the k8sman MCP server',
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.auto_awesome_outlined, size: 12, color: theme.colorScheme.primary),
                                const SizedBox(width: 3),
                                Text('Claude', key: ValueKey('ignored-by-claude-${it.finding.id}'), style: hint?.copyWith(color: theme.colorScheme.primary)),
                              ]),
                            ),
                          ),
                        ),
                      TextSpan(
                        text: [
                          'Ignored ${it.rule.scope}',
                          if (it.rule.reason.isNotEmpty) '"${it.rule.reason}"',
                          if (it.rule.at.length >= 10) it.rule.at.substring(0, 10),
                          if (it.finding.namespace != null && !it.rule.scope.contains(it.finding.namespace!)) it.finding.namespace!,
                        ].join(' · '),
                      ),
                    ]),
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
