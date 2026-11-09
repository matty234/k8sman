import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../addons/addons.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart';
import 'security_api.dart';

// ---------------------------------------------------------------------------
// Severity styling: the only colour on the page, kept restrained.
// ---------------------------------------------------------------------------

Color sevColor(BuildContext context, SecSeverity s) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (s) {
    SecSeverity.critical => severityColor(context, Severity.error),
    SecSeverity.high => dark ? const Color(0xFFF0884E) : const Color(0xFFC2520C),
    SecSeverity.medium => severityColor(context, Severity.warn),
    SecSeverity.low => Theme.of(context).hintColor,
    SecSeverity.info => Theme.of(context).hintColor.withValues(alpha: 0.6),
  };
}

/// A small filled dot (critical..medium) or ring (low/info).
class SevDot extends StatelessWidget {
  final SecSeverity severity;
  final double size;
  const SevDot(this.severity, {super.key, this.size = 8});

  @override
  Widget build(BuildContext context) {
    final c = sevColor(context, severity);
    final filled = severity.index <= SecSeverity.medium.index;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? c : null,
        border: filled ? null : Border.all(color: c, width: 1.3),
      ),
    );
  }
}

/// "● High" label used in finding rows.
class SevLabel extends StatelessWidget {
  final SecSeverity severity;
  const SevLabel(this.severity, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loud = severity.index <= SecSeverity.medium.index;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SevDot(severity, size: 7),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          severity.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: loud ? sevColor(context, severity) : theme.hintColor,
            fontWeight: loud ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Links into the inspector
// ---------------------------------------------------------------------------

/// Opens [ref] in the inspector (replacing the stack, like a table row).
void openRef(BuildContext context, ObjectRef ref) {
  final app = context.read<AppState>();
  final t = app.typeFor(ref.group, ref.kind);
  if (t == null) return;
  app.openDetail(DetailTarget(type: t, name: ref.name, namespace: t.namespaced ? ref.namespace : null));
}

/// An object name that opens the inspector when its type is known.
class RefLink extends StatelessWidget {
  final ObjectRef ref;
  final bool strong;
  final bool showNamespace;
  final String? label;
  const RefLink(this.ref, {super.key, this.strong = false, this.showNamespace = false, this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = context.read<AppState>().typeFor(ref.group, ref.kind) != null;
    final text = label ?? (showNamespace && ref.namespace != null ? '${ref.namespace}/${ref.name}' : ref.name);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: known ? theme.colorScheme.primary : null,
      fontWeight: strong ? FontWeight.w600 : null,
    );
    final t = Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    if (!known) return t;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => openRef(context, ref),
        child: Tooltip(message: 'Open ${ref.kind} ${ref.namespace != null ? '${ref.namespace}/' : ''}${ref.name}', waitDuration: const Duration(milliseconds: 500), child: t),
      ),
    );
  }
}

/// "Kind name" chip for an affected object.
class ObjectChip extends StatelessWidget {
  final ObjectRef ref;
  final bool showNamespace;
  const ObjectChip(this.ref, {super.key, this.showNamespace = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: chipFill(context), borderRadius: BorderRadius.circular(4)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(ref.kind, style: hint),
        const SizedBox(width: 5),
        Flexible(child: RefLink(ref, showNamespace: showNamespace)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Summary: score + category tiles
// ---------------------------------------------------------------------------

/// The posture at a glance: score, findings and the serious counts as
/// large figures divided by hairlines, coloured only by severity.
class SummaryLine extends StatelessWidget {
  final SecurityData data;
  const SummaryLine({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final score = data.score;
    return StatStrip(minCell: 104, maxCell: 150, items: [
      StatItem(
        'score',
        '$score',
        of: '/ 100',
        tooltip: 'A rough posture score: 100 with no findings; each critical costs ~9 points, high ~4, medium ~1.5.',
        tone: score < 50 ? Severity.error : (score < 80 ? Severity.warn : null),
      ),
      StatItem(data.findings.length == 1 ? 'finding' : 'findings', '${data.findings.length}'),
      for (final s in SecSeverity.values.take(3))
        if (data.countAll(s) > 0) StatItem(s.name, '${data.countAll(s)}', color: sevColor(context, s)),
    ]);
  }
}

IconData categoryIcon(String id) => switch (id) {
      'network' => Icons.lan_outlined,
      'rbac' => Icons.key_outlined,
      'workloads' => Icons.shield_outlined,
      'images' => Icons.layers_outlined,
      _ => Icons.checklist_outlined,
    };

/// One unboxed cell per category, side by side: a hairline down the left
/// (in the colour of its worst finding), the name, the total and a dot per
/// severity. Clicking one filters the page to it.
class CategoryTiles extends StatelessWidget {
  final List<SecCategory> categories;
  final String? selected;
  final ValueChanged<String> onSelect;
  const CategoryTiles({super.key, required this.categories, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final cols = (box.maxWidth / 170).floor().clamp(1, categories.length.clamp(1, 5));
      return evenGrid([
        for (final c in categories) _CategoryTile(category: c, selected: selected == c.id, onTap: () => onSelect(c.id)),
      ], cols, gap: 20, runGap: 14);
    });
  }
}

class _CategoryTile extends StatelessWidget {
  final SecCategory category;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryTile({required this.category, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final worst = SecSeverity.values.take(3).where((s) => category.count(s) > 0).firstOrNull;
    return Tooltip(
      message: selected ? 'Show all findings' : 'Show only ${category.title}',
      waitDuration: const Duration(milliseconds: 600),
      child: HairlineCell(
        selected: selected,
        accent: selected ? theme.colorScheme.primary : (worst == null ? null : sevColor(context, worst)),
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(categoryIcon(category.id), size: 14, color: theme.hintColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(category.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 2),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text('${category.total}',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontSize: 26,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -0.4,
                  height: 1.15,
                  color: theme.colorScheme.onSurface,
                  fontFeatures: tabularFigures,
                )),
            const SizedBox(width: 6),
            Flexible(child: Text(category.total == 1 ? 'finding' : 'findings', maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
          ]),
          const SizedBox(height: 4),
          SizedBox(
            height: 16,
            child: category.total == 0
                ? Text('Nothing found', style: hint)
                : ClipRect(
                    child: Wrap(spacing: 10, clipBehavior: Clip.hardEdge, children: [
                      for (final s in SecSeverity.values)
                        if (category.count(s) > 0)
                          Tooltip(
                            message: '${category.count(s)} ${s.name}',
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              SevDot(s, size: 7),
                              const SizedBox(width: 4),
                              Text('${category.count(s)}', style: hint?.copyWith(fontFeatures: tabularFigures)),
                            ]),
                          ),
                    ]),
                  ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

/// Findings grouped by category (in [categoryOrder]), sorted by severity.
class FindingList extends StatefulWidget {
  final List<SecFinding> findings;
  final List<SecCategory> categories;

  /// When true, group headers are shown (no category filter).
  final bool grouped;

  /// Hide each finding's namespace (the page is scoped to one).
  final bool hideNamespace;
  const FindingList({super.key, required this.findings, required this.categories, this.grouped = true, this.hideNamespace = false});

  @override
  State<FindingList> createState() => _FindingListState();
}

class _FindingListState extends State<FindingList> {
  static const _initial = 6;
  final _expanded = <String>{};
  final _showAll = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.findings.isEmpty) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: InlineMessage('No findings.', icon: Icons.check_circle_outline));
    }
    final groups = <SecCategory, List<SecFinding>>{};
    for (final c in widget.categories) {
      final fs = widget.findings.where((f) => f.category == c.id).toList()..sort((a, b) => a.severity.index.compareTo(b.severity.index));
      if (fs.isNotEmpty) groups[c] = fs;
    }
    final limit = widget.grouped ? _initial : 40;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in groups.entries) ...[
        if (widget.grouped)
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 2),
            child: Row(children: [
              Icon(categoryIcon(e.key.id), size: 14, color: theme.hintColor),
              const SizedBox(width: 6),
              Text(e.key.title, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('${e.value.length}', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
            ]),
          ),
        for (final (i, f) in (_showAll.contains(e.key.id) ? e.value : e.value.take(limit)).indexed) ...[
          if (i > 0) const Divider(height: 1),
          FindingTile(
            key: ValueKey(f.id),
            finding: f,
            hideNamespace: widget.hideNamespace,
            expanded: _expanded.contains(f.id),
            onToggle: () => setState(() => _expanded.contains(f.id) ? _expanded.remove(f.id) : _expanded.add(f.id)),
          ),
        ],
        if (e.value.length > limit)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
              onPressed: () => setState(() => _showAll.contains(e.key.id) ? _showAll.remove(e.key.id) : _showAll.add(e.key.id)),
              child: Text(
                _showAll.contains(e.key.id) ? 'Show fewer' : 'Show ${e.value.length - limit} more',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
          ),
      ],
    ]);
  }
}

class FindingTile extends StatelessWidget {
  final SecFinding finding;
  final bool expanded;
  final bool hideNamespace;
  final VoidCallback onToggle;
  const FindingTile({super.key, required this.finding, required this.expanded, required this.onToggle, this.hideNamespace = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final f = finding;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 17, color: theme.hintColor),
            ),
            const SizedBox(width: 4),
            SizedBox(width: 78, child: Padding(padding: const EdgeInsets.only(top: 1), child: SevLabel(f.severity))),
            Expanded(
              child: Text(f.title, maxLines: expanded ? 4 : 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
            ),
            if (f.namespace != null && !hideNamespace) ...[
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(f.namespace!, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
              ),
            ],
          ]),
        ),
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 4, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(f.detail, style: theme.textTheme.bodySmall),
            if (f.checks.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final c in f.checks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('•  ', style: hint),
                    Expanded(child: Text(c, style: theme.textTheme.bodySmall)),
                  ]),
                ),
            ],
            if (f.remediation.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.build_outlined, size: 13, color: theme.hintColor)),
                const SizedBox(width: 6),
                Expanded(child: SelectableText(f.remediation, style: hint)),
              ]),
            ],
            if (f.objects.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final o in f.objects.take(30)) ObjectChip(o, showNamespace: o.namespace != null && o.namespace != f.namespace),
                if (f.objects.length > 30) Text('+${f.objects.length - 30} more', style: hint),
              ]),
            ],
          ]),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// RBAC: most permissive grants
// ---------------------------------------------------------------------------

class PermissiveTable extends StatefulWidget {
  final List<Grant> grants;
  const PermissiveTable({super.key, required this.grants});

  @override
  State<PermissiveTable> createState() => _PermissiveTableState();
}

class _PermissiveTableState extends State<PermissiveTable> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.grants.isEmpty) return const InlineMessage('No risky grants found.', icon: Icons.check_circle_outline);
    final shown = _all ? widget.grants : widget.grants.take(10).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, g) in shown.indexed) ...[
        if (i > 0) const Divider(height: 1),
        _GrantRow(grant: g, rank: i + 1),
      ],
      if (widget.grants.length > 10)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
            onPressed: () => setState(() => _all = !_all),
            child: Text(_all ? 'Show top 10' : 'Show all ${widget.grants.length}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
          ),
        ),
    ]);
  }
}

SecSeverity grantSeverity(Grant g) {
  if (g.score >= 90) return g.clusterWide ? SecSeverity.critical : SecSeverity.high;
  if (g.score >= 45) return g.clusterWide ? SecSeverity.high : SecSeverity.medium;
  if (g.score >= 30) return g.clusterWide ? SecSeverity.medium : SecSeverity.low;
  return SecSeverity.info;
}

class _GrantRow extends StatelessWidget {
  final Grant grant;
  final int rank;
  const _GrantRow({required this.grant, required this.rank});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final g = grant;
    final sev = grantSeverity(g);
    final subjects = <Widget>[];
    for (final s in g.subjects.take(3)) {
      final r = s.ref;
      subjects.add(Row(mainAxisSize: MainAxisSize.min, children: [
        Text('${s.kind == 'ServiceAccount' ? 'SA' : s.kind} ', style: hint),
        Flexible(
          child: r != null
              ? RefLink(r, showNamespace: true)
              : Text('${s.namespace != null ? '${s.namespace}/' : ''}${s.name}${s.exists == false ? ' (missing)' : ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
        ),
      ]));
    }
    if (g.subjects.length > 3) subjects.add(Text('+${g.subjects.length - 3} more', style: hint));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 44,
          child: Tooltip(
            message: 'Risk score ${g.score}/100',
            child: Row(children: [
              SevDot(sev, size: 7),
              const SizedBox(width: 6),
              Text('${g.score}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              RefLink(g.binding, strong: true, showNamespace: g.binding.namespace != null),
              Text('→', style: hint),
              Text(g.role.kind, style: hint),
              g.roleMissing ? Text('${g.role.name} (missing)', style: theme.textTheme.bodySmall) : RefLink(g.role),
              if (g.unused)
                const Tooltip(
                  message: 'No pod or workload uses these ServiceAccounts',
                  child: StatusBadge('Unused', severity: Severity.warn),
                ),
              if (g.system) const StatusBadge('System', severity: Severity.neutral),
            ]),
            if (g.reasons.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(g.reasons.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis, style: hint),
              ),
            if (subjects.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 3), child: Wrap(spacing: 12, runSpacing: 2, children: subjects)),
          ]),
        ),
        const SizedBox(width: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 130),
          child: Text(g.clusterWide ? 'cluster-wide' : g.scope, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Network matrix
// ---------------------------------------------------------------------------

class NetworkMatrix extends StatelessWidget {
  final List<NamespaceNetwork> rows;
  const NetworkMatrix({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    if (rows.isEmpty) return const InlineMessage('No namespaces in scope.');
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 620;
      final cols = <(String, double, String)>[
        ('Policies', 62, 'NetworkPolicies in the namespace'),
        ('Ingress', wide ? 120 : 92, 'open: no pod is isolated · partial: some are · restricted: all are · default-deny: a namespace-wide deny policy'),
        ('Egress', wide ? 120 : 92, 'Same, for outbound traffic'),
        if (wide) ('Exposed', 64, 'LoadBalancer/NodePort/externalIP Services, Ingresses and Gateways'),
        if (wide) ('PSA', 84, 'Pod Security admission enforce level'),
      ];
      Widget header() => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              Expanded(child: Text('Namespace', style: hint)),
              for (final (label, w, tip) in cols) SizedBox(width: w, child: Tooltip(message: tip, child: Text(label, style: hint))),
            ]),
          );
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header(),
        const Divider(height: 1),
        for (final r in rows) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Expanded(child: RefLink(ObjectRef(kind: 'Namespace', name: r.namespace))),
              SizedBox(width: 62, child: _num(context, r.policies, quiet: true)),
              SizedBox(width: cols[1].$2, child: _Mode(mode: r.ingress, open: r.ingressOpen, total: r.workloads, direction: 'ingress', loud: true)),
              SizedBox(width: cols[2].$2, child: _Mode(mode: r.egress, open: r.egressOpen, total: r.workloads, direction: 'egress')),
              if (wide) SizedBox(width: 64, child: _num(context, r.exposed, quiet: r.exposed == 0)),
              if (wide)
                SizedBox(
                  width: 84,
                  child: Text(r.psa ?? 'none', style: theme.textTheme.bodySmall?.copyWith(color: r.psa == null || r.psa == 'privileged' ? theme.hintColor : null)),
                ),
            ]),
          ),
        ],
      ]);
    });
  }

  Widget _num(BuildContext context, int n, {bool quiet = false}) {
    final theme = Theme.of(context);
    return Text(n == 0 ? '–' : '$n',
        style: theme.textTheme.bodySmall?.copyWith(color: quiet && n == 0 ? theme.hintColor : null, fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

class _Mode extends StatelessWidget {
  final String mode;
  final int open;
  final int total;
  final String direction;

  /// Open ingress is a finding (medium); open egress is informational.
  final bool loud;
  const _Mode({required this.mode, required this.open, required this.total, required this.direction, this.loud = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noWorkloads = total == 0;
    final sev = switch (mode) {
      'open' when !noWorkloads => loud ? SecSeverity.medium : SecSeverity.low,
      'partial' => SecSeverity.low,
      _ => null,
    };
    final label = switch (mode) {
      'partial' => 'partial',
      'default-deny' => 'default-deny',
      'restricted' => 'restricted',
      _ => 'open',
    };
    final tip = noWorkloads ? 'No workloads' : '$open of $total ${total == 1 ? 'workload' : 'workloads'} accept $direction from anywhere';
    return Tooltip(
      message: tip,
      child: Row(children: [
        if (sev != null) ...[SevDot(sev, size: 6), const SizedBox(width: 5)] else const SizedBox(width: 11),
        Flexible(
          child: Text(
            mode == 'partial' ? '$label $open/$total' : label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: sev == null ? theme.hintColor : null),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

/// Where image vulnerability data comes from, and how to get more.
class ScannerSources extends StatelessWidget {
  final ScannerStatus? status;
  final bool hasOperatorData;
  const ScannerSources({super.key, required this.status, required this.hasOperatorData});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final s = status;
    final installed = s?.operatorInstalled ?? hasOperatorData;
    final scanning = s?.operatorScanning ?? false;

    Widget line(IconData icon, Widget text, {Widget? action, Color? iconColor}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Icon(icon, size: 15, color: iconColor ?? theme.hintColor),
            const SizedBox(width: 8),
            Expanded(child: text),
            if (action != null) ...[const SizedBox(width: 8), action],
          ]),
        );

    final ok = severityColor(context, Severity.ok);
    final op = !installed
        ? line(
            Icons.cloud_off_outlined,
            Text.rich(TextSpan(children: [
              TextSpan(text: 'Trivy Operator not installed. ', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              TextSpan(text: 'It scans every workload image in the cluster continuously and keeps VulnerabilityReports up to date.', style: hint),
            ])),
            action: OutlinedButton(
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: theme.textTheme.bodySmall),
              onPressed: () => requestAddon(context, AddonIds.trivyOperator),
              child: const Text('Install Trivy Operator'),
            ),
          )
        : scanning
            ? line(
                Icons.hourglass_top,
                Text.rich(TextSpan(children: [
                  TextSpan(text: 'Trivy Operator is scanning… ', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                  TextSpan(text: 'The first reports can take several minutes while it downloads its vulnerability database.', style: hint),
                ])),
                action: const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
              )
            : line(
                Icons.check_circle_outline,
                iconColor: ok,
                Text.rich(TextSpan(children: [
                  TextSpan(text: 'Trivy Operator ', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                  TextSpan(text: 'is installed; vulnerability data comes from its in-cluster reports.', style: hint),
                ])),
              );
    final cli = s == null
        ? null
        : s.trivyAvailable
            ? line(Icons.terminal, iconColor: ok, Text('Local trivy ${s.trivyVersion ?? ''} available for on-demand scans (${s.trivyPath ?? 'on PATH'}).', style: hint))
            : line(
                Icons.terminal,
                Text.rich(TextSpan(children: [
                  TextSpan(text: 'On-demand scans: ', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                  TextSpan(text: s.installHint.replaceAll('`', ''), style: hint),
                ])),
              );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [op, ?cli]);
  }
}

class ImageTable extends StatefulWidget {
  final List<ImageSummary> images;
  final bool canScan;
  final Set<String> scanning;
  final Map<String, String> scanErrors;
  final void Function(String image) onScan;
  const ImageTable({
    super.key,
    required this.images,
    required this.canScan,
    required this.onScan,
    this.scanning = const {},
    this.scanErrors = const {},
  });

  @override
  State<ImageTable> createState() => _ImageTableState();
}

class _ImageTableState extends State<ImageTable> {
  bool _all = false;
  final _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    if (widget.images.isEmpty) return const InlineMessage('No images in scope.');
    final shown = _all ? widget.images : widget.images.take(12).toList();
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 640;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            const SizedBox(width: 20),
            Expanded(child: Text('Image', style: hint)),
            SizedBox(width: 56, child: Text('Critical', style: hint, textAlign: TextAlign.right)),
            SizedBox(width: 50, child: Text('High', style: hint, textAlign: TextAlign.right)),
            SizedBox(width: 62, child: Tooltip(message: 'Critical + high with a fixed version available', child: Text('Fixable', style: hint, textAlign: TextAlign.right))),
            if (wide) SizedBox(width: 150, child: Padding(padding: const EdgeInsets.only(left: 16), child: Text('Used by', style: hint))),
            const SizedBox(width: 76),
          ]),
        ),
        const Divider(height: 1),
        for (final img in shown) ..._row(context, img, wide),
        if (widget.images.length > 12)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Show fewer' : 'Show all ${widget.images.length} images', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
            ),
          ),
      ]);
    });
  }

  List<Widget> _row(BuildContext context, ImageSummary img, bool wide) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final c = img.counts;
    final busy = widget.scanning.contains(img.image);
    final open = _open.contains(img.image);
    final num = theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    Widget count(int n, SecSeverity s) => Text(
          !img.scanned ? '–' : (n == 0 ? '0' : '$n'),
          textAlign: TextAlign.right,
          style: n == 0 ? num?.copyWith(color: theme.hintColor) : num?.copyWith(color: sevColor(context, s), fontWeight: FontWeight.w600),
        );
    final scanButton = SizedBox(
      width: 76,
      child: Align(
        alignment: Alignment.centerRight,
        child: busy
            ? const Padding(padding: EdgeInsets.only(right: 10), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)))
            : Tooltip(
                message: widget.canScan ? 'Scan with the local trivy CLI' : 'Install trivy (brew install trivy) to scan on demand',
                child: TextButton(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 26)),
                  onPressed: widget.canScan ? () => widget.onScan(img.image) : null,
                  child: Text(img.scanned && img.source == 'trivy-cli' ? 'Rescan' : 'Scan', style: theme.textTheme.bodySmall?.copyWith(color: widget.canScan ? theme.colorScheme.primary : theme.hintColor)),
                ),
              ),
      ),
    );
    final err = widget.scanErrors[img.image];
    return [
      InkWell(
        onTap: img.topCves.isEmpty ? null : () => setState(() => open ? _open.remove(img.image) : _open.add(img.image)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(
              width: 20,
              child: img.topCves.isEmpty ? null : Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: theme.hintColor),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Tooltip(
                  message: img.image,
                  waitDuration: const Duration(milliseconds: 500),
                  child: Text(img.image, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5)),
                ),
                if (!img.scanned) Text('not scanned', style: hint?.copyWith(fontSize: 11)),
                if (img.scanned && img.source == 'trivy-cli') Text('scanned locally', style: hint?.copyWith(fontSize: 11)),
              ]),
            ),
            SizedBox(width: 56, child: count(c.critical, SecSeverity.critical)),
            SizedBox(width: 50, child: count(c.high, SecSeverity.high)),
            SizedBox(
              width: 62,
              child: Text(!img.scanned ? '–' : '${c.fixable}', textAlign: TextAlign.right, style: c.fixable == 0 ? num?.copyWith(color: theme.hintColor) : num),
            ),
            if (wide)
              SizedBox(
                width: 150,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: img.workloads.isEmpty
                      ? const SizedBox()
                      : Row(children: [
                          Flexible(child: RefLink(img.workloads.first)),
                          if (img.workloads.length > 1) Text(' +${img.workloads.length - 1}', style: hint),
                        ]),
                ),
              ),
            scanButton,
          ]),
        ),
      ),
      if (err != null) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 0, 6), child: InlineMessage(err, isError: true)),
      if (open) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 0, 8), child: CveList(cves: img.topCves, showImages: false)),
      const Divider(height: 1),
    ];
  }
}

class CveList extends StatelessWidget {
  final List<Cve> cves;
  final bool showImages;
  const CveList({super.key, required this.cves, this.showImages = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    if (cves.isEmpty) return const InlineMessage('No critical or high vulnerabilities reported.', icon: Icons.check_circle_outline);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final v in cves)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 4), child: SevDot(v.severity, size: 7)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SelectableText(v.id, style: monoStyle(context, size: 11.5).copyWith(fontWeight: FontWeight.w600)),
                  Text(v.package, style: theme.textTheme.bodySmall),
                  Text(v.fixed == null ? '${v.installed} · no fix yet' : '${v.installed} → ${v.fixed}', style: hint),
                ]),
                if (v.title.isNotEmpty) Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
                if (showImages && v.images.isNotEmpty)
                  Text('in ${v.images.take(3).join(', ')}${v.images.length > 3 ? ' +${v.images.length - 3}' : ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: hint?.copyWith(fontSize: 11)),
              ]),
            ),
          ]),
        ),
    ]);
  }
}
