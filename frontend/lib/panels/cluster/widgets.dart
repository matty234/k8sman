import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import 'logic.dart';

/// Severity for a utilisation fraction.
Severity usageSeverity(double frac) => frac >= 0.9 ? Severity.error : (frac >= 0.7 ? Severity.warn : Severity.ok);

/// `label  [=====-----]  used / total  42%`.
class UsageBar extends StatelessWidget {
  final String label;
  final double used;
  final double? total;
  final String usedText;
  final String totalText;
  final double labelWidth;

  const UsageBar({
    super.key,
    required this.label,
    required this.used,
    required this.total,
    required this.usedText,
    required this.totalText,
    this.labelWidth = 110,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = total;
    final frac = (t == null || t <= 0) ? (used > 0 ? 1.0 : 0.0) : used / t;
    final c = (t == null || t <= 0) ? theme.hintColor : severityColor(context, usageSeverity(frac));
    final pct = (t == null || t <= 0) ? '' : '${(frac * 100).toStringAsFixed(0)}%';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: labelWidth,
          child: Text(label, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: frac.clamp(0.0, 1.0),
              minHeight: 8,
              color: c,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 130,
          child: Text('$usedText / $totalText', textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11)),
        ),
        SizedBox(
          width: 40,
          child: Text(pct, textAlign: TextAlign.right, style: monoStyle(context, size: 11, color: c).copyWith(fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// A prominent coloured box for important state (cordoned, Terminating, dangerous grants).
class Callout extends StatelessWidget {
  final Severity severity;
  final IconData icon;
  final String title;
  final Widget? child;
  const Callout({super.key, required this.severity, required this.icon, required this.title, this.child});

  @override
  Widget build(BuildContext context) {
    final c = severityColor(context, severity);
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.bodyMedium?.copyWith(color: c, fontWeight: FontWeight.w700)),
            if (child != null) ...[const SizedBox(height: 4), child!],
          ]),
        ),
      ]),
    );
  }
}

/// Small header-row table. [flex] gives each column's flex factor.
class CompactTable extends StatelessWidget {
  final List<String> headers;
  final List<List<Widget>> rows;
  final List<int> flex;
  final List<TextAlign>? align;
  const CompactTable({super.key, required this.headers, required this.rows, required this.flex, this.align});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(Widget w, int i) {
      final a = align?[i] ?? TextAlign.left;
      return Expanded(
        flex: flex[i],
        child: Align(alignment: a == TextAlign.right ? Alignment.centerRight : Alignment.centerLeft, child: w),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.dividerColor))),
        child: Row(children: [
          for (var i = 0; i < headers.length; i++)
            cell(Text(headers[i], style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)), i),
        ]),
      ),
      for (final r in rows)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)))),
          child: Row(children: [for (var i = 0; i < r.length; i++) cell(r[i], i)]),
        ),
    ]);
  }
}

/// Monospace text cell.
class MonoText extends StatelessWidget {
  final String text;
  final Color? color;
  const MonoText(this.text, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Text(text, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: color));
}

// ---------------------------------------------------------------------------
// RBAC
// ---------------------------------------------------------------------------

Color verbRiskColor(BuildContext context, VerbRisk r) => switch (r) {
      VerbRisk.read => severityColor(context, Severity.ok),
      VerbRisk.write => severityColor(context, Severity.warn),
      VerbRisk.escalate => severityColor(context, Severity.error),
      VerbRisk.other => severityColor(context, Severity.info),
    };

class VerbChip extends StatelessWidget {
  final String verb;
  final VerbRisk risk;
  const VerbChip(this.verb, this.risk, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = verbRiskColor(context, risk);
    final tip = switch (risk) {
      VerbRisk.read => 'read',
      VerbRisk.write => 'write',
      VerbRisk.escalate => 'escalation risk',
      VerbRisk.other => 'other',
    };
    return Tooltip(
      message: tip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: c.withValues(alpha: 0.45)),
        ),
        child: Text(verb, style: monoStyle(context, size: 11, color: c)),
      ),
    );
  }
}

/// Warning badge listing dangerous grants.
class DangerCallout extends StatelessWidget {
  final List<String> dangers;
  const DangerCallout(this.dangers, {super.key});

  @override
  Widget build(BuildContext context) {
    if (dangers.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Callout(
      severity: Severity.error,
      icon: Icons.gpp_maybe_outlined,
      title: 'Dangerous grants',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final d in dangers) Text('• $d', style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

/// Rules of a Role/ClusterRole: groups | resources (+names) | verbs.
class RulesTable extends StatelessWidget {
  final List<Json> rules;
  const RulesTable(this.rules, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (rules.isEmpty) return const InlineMessage('No rules: this role grants nothing');
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.dividerColor))),
        child: Row(children: [
          Expanded(flex: 4, child: Text('API GROUPS', style: hint)),
          Expanded(flex: 7, child: Text('RESOURCES', style: hint)),
          Expanded(flex: 4, child: Text('VERBS', style: hint)),
        ]),
      ),
      for (final r in rules) _RuleRow(r),
      const SizedBox(height: 6),
      Wrap(spacing: 10, runSpacing: 4, children: [
        for (final risk in [VerbRisk.read, VerbRisk.write, VerbRisk.escalate])
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: verbRiskColor(context, risk), shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(switch (risk) { VerbRisk.read => 'read', VerbRisk.write => 'write', _ => 'escalation / secrets' },
                style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
          ]),
      ]),
    ]);
  }
}

class _RuleRow extends StatelessWidget {
  final Json rule;
  const _RuleRow(this.rule);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = strList(rule['apiGroups']);
    final resources = strList(rule['resources']);
    final names = strList(rule['resourceNames']);
    final urls = strList(rule['nonResourceURLs']);
    final verbs = strList(rule['verbs']);
    final dangers = ruleDangers(rule);
    final mono = monoStyle(context, size: 11);
    final danger = severityColor(context, Severity.error);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: urls.isNotEmpty && resources.isEmpty
                ? Text('non-resource', style: mono.copyWith(color: theme.hintColor))
                : Text(groups.map((g) => apiGroupLabel(g).replaceAll('.', '.\u200b')).join('\n'), style: mono.copyWith(color: theme.hintColor)),
          ),
        ),
        Expanded(
          flex: 7,
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (dangers.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 4, top: 1),
                    child: Tooltip(message: dangers.join('\n'), child: Icon(Icons.warning_amber_rounded, size: 14, color: danger)),
                  ),
                Expanded(child: SelectableText([...resources, ...urls].join(', '), style: mono)),
              ]),
              if (names.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('names: ${names.join(', ')}', style: mono.copyWith(color: theme.hintColor)),
                ),
            ]),
          ),
        ),
        Expanded(
          flex: 4,
          child: Wrap(spacing: 3, runSpacing: 3, children: [
            for (final v in verbs) VerbChip(v, verbRisk(v, resources: resources)),
          ]),
        ),
      ]),
    );
  }
}

/// One subject of a binding: kind badge, name (SA → link), namespace.
class SubjectRow extends StatelessWidget {
  final Json subject;
  final String? bindingNamespace;
  const SubjectRow(this.subject, {super.key, this.bindingNamespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = '${subject['kind'] ?? ''}';
    final name = '${subject['name'] ?? ''}';
    final ns = subject['namespace'] as String? ?? bindingNamespace;
    final (icon, color) = switch (kind) {
      'ServiceAccount' => (Icons.smart_toy_outlined, severityColor(context, Severity.info)),
      'Group' => (Icons.group_outlined, Colors.purple.shade200),
      _ => (Icons.person_outline, Colors.teal.shade200),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        SizedBox(width: 92, child: Text(kind, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor))),
        Expanded(
          child: kind == 'ServiceAccount'
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: ResourceLink(ObjectRef(kind: 'ServiceAccount', name: name, namespace: ns), label: ns != null ? '$ns/$name' : name),
                )
              : Align(alignment: Alignment.centerLeft, child: Chipish(text: name, copyValue: name, color: color.withValues(alpha: 0.4))),
        ),
      ]),
    );
  }
}
