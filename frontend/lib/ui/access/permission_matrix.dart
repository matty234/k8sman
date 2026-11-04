/// Resource × verb permission matrix: sticky verb header, rows grouped by
/// API group (empty groups collapse), filter, hover explanations.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'access_api.dart';
import 'rbac_model.dart';

/// One-line explanation of a grant path, e.g.
/// "RoleBinding demo/readers → ClusterRole view (via edit → view-core) · rule 2".
String pathLine(GrantPath p) {
  final parts = <String>[];
  if (!p.binding.isEmpty) parts.add('${p.binding.kind} ${p.binding.label}');
  var role = '${p.role.kind} ${p.role.name}';
  if (p.aggregated) role += ' (aggregates ${[...p.via, p.source.name].join(' → ')})';
  if (!p.role.isEmpty && p.role.kind != 'SelfSubjectRulesReview') parts.add(role);
  if (p.subject != null && p.subject!.kind == 'Group') parts.add('as member of ${p.subject!.name}');
  return parts.join(' → ');
}

/// Label for a full verb header.
String verbHeader(String v) => switch (v) {
      'deletecollection' => 'delcoll',
      'impersonate' => 'impers.',
      _ => v,
    };

class PermissionMatrix extends StatefulWidget {
  final PermissionMatrixData data;

  /// Case-insensitive substring over group, resource and kind.
  final String filter;

  /// Hide rows with no granted cell (and groups left empty).
  final bool hideEmpty;

  /// Narrow columns with abbreviated headers (inspector panels).
  final bool compact;

  /// Size to content (no internal vertical scroll), for scrolling panels.
  final bool shrinkWrap;

  /// Columns to show; defaults to [PermissionMatrixData.verbs].
  final List<String>? verbs;

  /// Selected cell: (row key, verb).
  final (String, String)? selected;
  final void Function(MatrixRow row, String verb)? onSelect;

  const PermissionMatrix({
    super.key,
    required this.data,
    this.filter = '',
    this.hideEmpty = true,
    this.compact = false,
    this.shrinkWrap = false,
    this.verbs,
    this.selected,
    this.onSelect,
  });

  @override
  State<PermissionMatrix> createState() => _PermissionMatrixState();
}

class _PermissionMatrixState extends State<PermissionMatrix> {
  /// Explicit group toggles (true = open).
  final Map<String, bool> _open = {};

  /// Column width, set per layout: wide columns with full verb names when
  /// there's room, down to compact ones with abbreviations.
  double _cellW = 54;
  bool get _narrow => widget.compact || _cellW < 50;
  double get _rowH => widget.compact ? 22 : 24;

  List<Object> _items() {
    final q = widget.filter.trim().toLowerCase();
    bool match(MatrixRow r) => q.isEmpty || r.resource.contains(q) || r.groupLabel.contains(q) || r.kind.toLowerCase().contains(q);
    final byGroup = <String, List<MatrixRow>>{};
    for (final r in widget.data.rows) {
      if (!match(r)) continue;
      if (widget.hideEmpty && r.cells.isEmpty) continue;
      byGroup.putIfAbsent(r.group, () => []).add(r);
    }
    final out = <Object>[];
    for (final e in byGroup.entries) {
      final granted = e.value.where((r) => r.cells.isNotEmpty).length;
      // Groups without grants start collapsed; searching opens everything.
      final open = q.isNotEmpty || (_open[e.key] ?? granted > 0);
      out.add(_Group(e.key, granted, e.value.length, open));
      if (open) out.addAll(e.value);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final verbs = widget.verbs ?? widget.data.verbs;
    final items = _items();
    final theme = Theme.of(context);
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(widget.filter.isEmpty ? 'No permissions on API resources.' : 'Nothing matches “${widget.filter}”.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      );
    }
    return LayoutBuilder(builder: (context, box) {
      final minRes = widget.compact ? 150.0 : 170.0;
      final avail = box.maxWidth.isFinite ? box.maxWidth : minRes + verbs.length * 54;
      _cellW = widget.compact ? 34 : ((avail - minRes) / math.max(1, verbs.length)).clamp(36.0, 54.0);
      final resW = math.max(minRes, math.min(avail - verbs.length * _cellW, widget.compact ? 260.0 : 340.0));
      final width = resW + verbs.length * _cellW;
      final header = _header(context, verbs, resW);
      Widget item(Object it, int i) => it is _Group ? _groupRow(context, it, width) : _row(context, it as MatrixRow, verbs, resW, i);
      final Widget body;
      if (widget.shrinkWrap) {
        body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, for (final (i, it) in items.indexed) item(it, i)]);
      } else {
        body = SizedBox(
          height: box.maxHeight,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header,
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemExtent: _rowH,
                itemBuilder: (context, i) => item(items[i], i),
              ),
            ),
          ]),
        );
      }
      final sized = SizedBox(width: width, child: body);
      if (width <= avail) return Align(alignment: Alignment.topLeft, child: sized);
      return Scrollbar(
        child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: sized),
      );
    });
  }

  Widget _header(BuildContext context, List<String> verbs, double resW) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600, fontSize: _narrow ? 10 : 11);
    return Container(
      height: widget.compact ? 22 : 26,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.of(context).separator))),
      child: Row(children: [
        SizedBox(width: resW, child: Padding(padding: const EdgeInsets.only(left: 4), child: Text('Resource', style: style))),
        for (final v in verbs)
          SizedBox(
            width: _cellW,
            child: Tooltip(
              message: v == '*' ? 'Wildcard verb (*): every verb, including future ones' : v,
              waitDuration: const Duration(milliseconds: 400),
              child: Center(child: Text(_narrow ? verbAbbrev(v) : verbHeader(v), style: style, maxLines: 1, overflow: TextOverflow.clip)),
            ),
          ),
      ]),
    );
  }

  Widget _groupRow(BuildContext context, _Group g, double width) {
    final theme = Theme.of(context);
    final faint = AppColors.of(context).faint;
    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: () => setState(() => _open[g.group] = !g.open),
      builder: (h) => Container(
        height: _rowH,
        padding: const EdgeInsets.only(left: 2),
        color: h ? AppColors.of(context).hover : null,
        child: Row(children: [
          Icon(g.open ? Icons.expand_more : Icons.chevron_right, size: 14, color: theme.hintColor),
          const SizedBox(width: 2),
          Text(g.group.isEmpty ? 'core' : g.group, style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Text(g.granted == 0 ? 'no access' : '${g.granted} of ${g.total}', style: theme.textTheme.labelSmall?.copyWith(color: faint)),
        ]),
      ),
    );
  }

  Widget _row(BuildContext context, MatrixRow r, List<String> verbs, double resW, int index) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final sub = r.isSubresource;
    final parts = r.resource.split('/');
    final label = Text.rich(
      TextSpan(children: [
        if (sub) TextSpan(text: '${parts.first}/', style: TextStyle(color: colors.faint)),
        TextSpan(text: sub ? parts.sublist(1).join('/') : r.resource),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: monoStyle(context, size: widget.compact ? 11 : 11.5).copyWith(color: r.cells.isEmpty ? theme.hintColor : null),
    );
    return Container(
      height: _rowH,
      color: index.isOdd ? colors.stripe : null,
      child: Row(children: [
        SizedBox(
          width: resW,
          child: Tooltip(
            message: [
              '${r.groupLabel}/${r.resource}',
              if (r.kind.isNotEmpty) r.kind,
              r.virtual ? 'not served by the API (named by a rule)' : (r.namespaced ? 'namespaced' : 'cluster-scoped'),
            ].join(' · '),
            waitDuration: const Duration(milliseconds: 600),
            child: Padding(padding: EdgeInsets.only(left: sub ? 22 : 12, right: 6), child: Align(alignment: Alignment.centerLeft, child: label)),
          ),
        ),
        for (final v in verbs) SizedBox(key: ValueKey('cell-${r.key}-$v'), width: _cellW, child: _cell(context, r, v)),
      ]),
    );
  }

  Widget _cell(BuildContext context, MatrixRow r, String verb) {
    final theme = Theme.of(context);
    final c = r.cells[verb];
    final selected = widget.selected == (r.key, verb);
    final onTap = widget.onSelect == null ? null : () => widget.onSelect!(r, verb);
    if (c == null) {
      if (!r.supports(verb)) return const SizedBox.shrink();
      return Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: onTap,
        builder: (h) => Center(
          child: Container(
            width: selected ? 12 : 3,
            height: selected ? 12 : 3,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? null : AppColors.of(context).faint.withValues(alpha: h ? 0.9 : 0.45),
              border: selected ? Border.all(color: theme.colorScheme.primary, width: 1.5) : null,
            ),
          ),
        ),
      );
    }
    final danger = c.danger != null;
    final color = danger ? severityColor(context, Severity.warn) : theme.colorScheme.primary;
    final marker = Container(
      width: 11,
      height: 11,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.limited ? null : color.withValues(alpha: 0.85),
        border: c.limited ? Border.all(color: color, width: 1.6) : null,
      ),
    );
    return Tooltip(
      richMessage: _tooltip(context, r, verb, c),
      waitDuration: const Duration(milliseconds: 250),
      child: Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: onTap,
        builder: (h) => Center(
          child: Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? theme.colorScheme.onSurface : (h ? color.withValues(alpha: 0.5) : Colors.transparent), width: 1.2),
            ),
            child: marker,
          ),
        ),
      ),
    );
  }

  InlineSpan _tooltip(BuildContext context, MatrixRow r, String verb, MatrixCell c) {
    final paths = [for (final i in c.paths) if (i < widget.data.paths.length) widget.data.paths[i]];
    const bold = TextStyle(fontWeight: FontWeight.w600);
    final what = verb == '*' ? 'every verb on ${r.resource}' : '$verb ${r.resource}';
    return TextSpan(children: [
      TextSpan(text: c.limited ? 'Can $what, only: ${c.names.join(', ')}' : 'Can $what', style: bold),
      if (c.danger != null) TextSpan(text: '\n⚠ ${c.danger}'),
      for (final p in paths.take(4)) TextSpan(text: '\n• ${pathLine(p)}${pathLine(p).isEmpty ? '' : ': '}${p.rule.summary}'),
      if (paths.length > 4) TextSpan(text: '\n+ ${paths.length - 4} more'),
      if (widget.onSelect != null) const TextSpan(text: '\nClick for details'),
    ]);
  }
}

class _Group {
  final String group;
  final int granted;
  final int total;
  final bool open;
  const _Group(this.group, this.granted, this.total, this.open);
}

/// Lays bare rules (a Role's .rules) out as a matrix, client-side: one row
/// per resource the rules name (wildcards as "*" rows). Used by the
/// inspector panels and the role editor's live preview.
PermissionMatrixData matrixFromRules(List<Json> rules, {RbacRef role = const RbacRef('', '')}) {
  final paths = <GrantPath>[];
  final rows = <String, (String, String, Map<String, MatrixCell>)>{};
  final verbsUsed = <String>{};
  for (final (i, rj) in rules.indexed) {
    final r = PolicyRuleData.fromJson(rj);
    if (r.nonResourceURLs.isNotEmpty || r.resources.isEmpty) continue;
    final pi = paths.length;
    paths.add(GrantPath(binding: const RbacRef('', ''), role: role, scope: 'cluster', rule: r, source: role, index: i));
    final verbs = r.verbs.contains('*') ? [...standardVerbs, '*'] : r.verbs;
    verbsUsed.addAll(verbs);
    for (final g in r.apiGroups) {
      for (final res in r.resources) {
        final key = '$g/$res';
        final row = rows.putIfAbsent(key, () => (g, res, <String, MatrixCell>{}));
        for (final v in verbs) {
          final prev = row.$3[v];
          final unrestricted = r.resourceNames.isEmpty || (prev != null && !prev.limited);
          final names = unrestricted ? <String>[] : {...?prev?.names, ...r.resourceNames}.toList();
          row.$3[v] = MatrixCell(paths: [...?prev?.paths, pi], names: names, danger: _ruleDanger(g, res, v));
        }
      }
    }
  }
  final order = [...standardVerbs, ...specialVerbs, '*'];
  final verbs = [for (final v in order) if (verbsUsed.contains(v)) v, for (final v in verbsUsed) if (!order.contains(v)) v];
  final sorted = rows.values.toList()
    ..sort((a, b) {
      final g = (a.$1.isEmpty ? '' : '~${a.$1}').compareTo(b.$1.isEmpty ? '' : '~${b.$1}');
      return g != 0 ? g : a.$2.compareTo(b.$2);
    });
  return PermissionMatrixData(
    verbs: verbs,
    paths: paths,
    rows: [for (final (g, res, cells) in sorted) MatrixRow(group: g, resource: res, cells: cells)],
    fullWildcard: paths.any((p) => p.fullWildcard),
  );
}

String? _ruleDanger(String g, String res, String v) {
  final r = EditableRule(apiGroups: [g], resources: [res], verbs: [v]);
  final d = editableRuleDangers(r);
  return d.isEmpty ? null : d.first;
}

/// Compact matrix of a role's rules for the inspector: only the verbs used.
class RoleRulesMatrix extends StatelessWidget {
  final List<Json> rules;
  final RbacRef role;
  const RoleRulesMatrix({super.key, required this.rules, this.role = const RbacRef('', '')});

  @override
  Widget build(BuildContext context) {
    final data = matrixFromRules(rules, role: role);
    if (data.rows.isEmpty) return const SizedBox.shrink();
    return PermissionMatrix(data: data, compact: true, shrinkWrap: true);
  }
}
