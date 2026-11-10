/// Plugin panel blocks (docs/PLUGINS.md §4) drawn with the app's own
/// widgets. The backend resolves every expression; a block here is plain
/// JSON: `{type, …values}`, or `{type: "error", message}`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../metrics/quantity_cell.dart' show UsageBar;
import '../ui/inspector/callout.dart' show Callout;
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'plugin_icons.dart';

/// One plugin section as a [DetailSection].
class PluginSectionView extends StatelessWidget {
  final Json section;
  const PluginSectionView(this.section, {super.key});

  @override
  Widget build(BuildContext context) {
    final blocks = asMapList(section['blocks']);
    return DetailSection(
      title: '${section['title'] ?? ''}',
      icon: pluginIcon(section['icon'] as String?) ?? Icons.extension_outlined,
      initiallyExpanded: section['collapsed'] != true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, b) in blocks.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 10), child: PluginBlock(b)),
        if (blocks.isEmpty) Text('—', style: TextStyle(color: Theme.of(context).hintColor)),
      ]),
    );
  }
}

/// One block.
class PluginBlock extends StatelessWidget {
  final Json block;
  const PluginBlock(this.block, {super.key});

  @override
  Widget build(BuildContext context) {
    final b = block;
    final theme = Theme.of(context);
    final empty = '${b['empty'] ?? 'None'}';
    Widget hint(String t) => Text(t, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    switch (b['type']) {
      case 'fields':
        final items = asMapList(b['items']);
        return KeyValueTable([
          for (final it in items)
            ('${it['label'] ?? ''}', it['error'] != null ? PluginErrorText('${it['error']}') : pluginValue(context, it['value'], type: it['type'] as String?, link: it['link'], copy: it['copy'] == true, mono: it['mono'] == true)),
        ]);
      case 'settings':
        return PluginSettingsRows(b);
      case 'badges':
        final items = asMapList(b['items']);
        if (items.isEmpty) return hint(empty);
        return Wrap(spacing: 6, runSpacing: 4, children: [
          for (final it in items)
            it['error'] != null ? PluginErrorText('${it['error']}') : StatusBadge('${it['text'] ?? ''}', severity: severityNamed(it['severity'] as String?)),
        ]);
      case 'chips':
        final v = b['items'];
        if (v is Map) return LabelChips(Map<String, dynamic>.from(v), emptyText: empty);
        final list = v is List ? v : const [];
        if (list.isEmpty) return hint(empty);
        return Wrap(spacing: 4, runSpacing: 4, children: [for (final x in list) Chipish(text: '$x', copyValue: '$x')]);
      case 'conditions':
        return ConditionsTable(b['conditions'] is List ? b['conditions'] as List : const []);
      case 'links':
        final refs = [for (final r in asMapList(b['items'])) ?refOf(r)];
        if (refs.isEmpty) return hint(empty);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in refs) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: ResourceLink(r)),
        ]);
      case 'table':
        return PluginTable(b);
      case 'bar':
        return _Bar(b);
      case 'code':
        final v = b['value'];
        return CodeBlock(v is String ? v : const JsonEncoder.withIndent('  ').convert(v));
      case 'json':
        return JsonTree(b['value']);
      case 'message':
        return PluginMessage('${b['text'] ?? ''}', severity: '${b['severity'] ?? 'info'}', title: b['title'] as String?);
      case 'error':
        return PluginErrorText('${b['message'] ?? ''}');
    }
    return hint('This section needs a newer version of k8sman (block "${b['type']}").');
  }
}

/// [name] (info, warning, error, ok, …) as a [Severity]; null = infer.
Severity? severityNamed(String? name) => switch (name) {
      'error' || 'critical' => Severity.error,
      'warning' || 'warn' => Severity.warn,
      'ok' || 'success' => Severity.ok,
      'info' => Severity.info,
      'neutral' => Severity.neutral,
      _ => null,
    };

/// A Ref (`{group, kind, namespace, name}`) as an [ObjectRef].
ObjectRef? refOf(Object? v) {
  final m = asMap(v);
  final name = '${m['name'] ?? ''}', kind = '${m['kind'] ?? ''}';
  if (name.isEmpty || kind.isEmpty) return null;
  final ns = '${m['namespace'] ?? ''}';
  return ObjectRef(group: '${m['group'] ?? ''}', kind: kind, name: name, namespace: ns.isEmpty ? null : ns);
}

String _text(Object? v) => switch (v) {
      null => '',
      List l => l.map(_text).join(', '),
      Map m => jsonEncode(m),
      double d when d == d.roundToDouble() && d.abs() < 1e15 => d.toInt().toString(),
      _ => '$v',
    };

/// A value drawn by its value type (fields and table cells); [mono] in the
/// monospace font.
Widget pluginValue(BuildContext context, Object? v, {String? type, Object? link, bool copy = false, bool dense = false, bool mono = false}) {
  final theme = Theme.of(context);
  final style = mono ? monoStyle(context, size: 11) : theme.textTheme.bodySmall;
  final text = _text(v);
  Widget w;
  switch (type) {
    case 'status':
      w = Align(alignment: Alignment.centerLeft, child: StatusBadge(text, dense: dense));
    case 'bool':
      w = Text(v == true ? 'Yes' : (v == false ? 'No' : text), style: style);
    case 'age':
      w = AgeText(v, suffix: dense ? '' : ' ago', style: style);
    case 'until':
      w = UntilText(v, style: style);
    case 'timestamp':
      final t = parseTime(v);
      w = Text(t == null ? text : formatLocal(t), style: style);
    case 'labels':
      w = v is Map ? LabelChips(Map<String, dynamic>.from(v)) : Text(text, style: style);
    case 'url':
      w = Hoverable(
        onTap: () => openUrl(text),
        builder: (h) => Text(text, style: style?.copyWith(color: theme.colorScheme.primary, decoration: h ? TextDecoration.underline : null)),
      );
    case 'code':
      w = CodeBlock(text);
    case 'number' || 'quantity':
      w = Text(text, style: style?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
    default:
      w = Text(text, style: style);
  }
  final ref = refOf(link);
  if (ref != null && const {null, 'text', 'number', 'quantity'}.contains(type)) {
    w = ResourceLink(ref, label: text, singleLine: dense);
  }
  if (copy) {
    w = Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: w),
      IconButton(
        iconSize: 13,
        visualDensity: VisualDensity.compact,
        tooltip: 'Copy',
        icon: const Icon(Icons.copy_rounded),
        onPressed: () => copyToClipboard(context, text),
      ),
    ]);
  }
  return w;
}

/// Time left until a timestamp, ticking; red once it has passed.
class UntilText extends StatefulWidget {
  final Object? timestamp;
  final TextStyle? style;
  const UntilText(this.timestamp, {super.key, this.style});

  @override
  State<UntilText> createState() => _UntilTextState();
}

class _UntilTextState extends State<UntilText> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 30), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = parseTime(widget.timestamp);
    if (t == null) return Text(_text(widget.timestamp), style: widget.style);
    final passed = t.isBefore(DateTime.now());
    return Tooltip(
      message: formatLocal(t),
      child: Text(formatUntil(t), style: (widget.style ?? const TextStyle()).copyWith(color: passed ? severityColor(context, Severity.error) : null)),
    );
  }
}

/// A message block: info quiet, warnings and errors in their colour; with
/// a [title], a warning or error is a [Callout] titled with it.
class PluginMessage extends StatelessWidget {
  final String text;
  final String severity;
  final String? title;
  const PluginMessage(this.text, {super.key, this.severity = 'info', this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sev = severityNamed(severity) ?? Severity.info;
    final title = this.title;
    if (title != null && title.isNotEmpty && sev != Severity.info) return Callout(severity: sev, title: title, body: text);
    if (sev == Severity.info) return InlineMessage(text);
    final c = severityColor(context, sev);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withValues(alpha: 0.35))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(sev == Severity.error ? Icons.error_outline : Icons.warning_amber_rounded, size: 15, color: c),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ]),
    );
  }
}

/// An evaluation or compile error in a plugin, with its place in
/// plugin.yaml ("plugin.yaml:12:5: …"), shown where the value would be.
class PluginErrorText extends StatelessWidget {
  final String message;
  const PluginErrorText(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = severityColor(context, Severity.error);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.bug_report_outlined, size: 13, color: c)),
      const SizedBox(width: 5),
      Expanded(child: Text(message, style: monoStyle(context, size: 11, color: c))),
    ]);
  }
}

/// A settings block: an object flattened by the backend into `path →
/// value` rows, references as links (their name and key: never a value).
class PluginSettingsRows extends StatelessWidget {
  final Json block;
  const PluginSettingsRows(this.block, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final rows = asMapList(block['rows']);
    final total = (block['total'] as num?)?.toInt() ?? rows.length;
    if (rows.isEmpty) return Text('${block['empty'] ?? 'None'}', style: hint);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      KeyValueTable([
        for (final r in rows) ('${r['label'] ?? ''}', pluginValue(context, r['value'], link: r['link'])),
      ], keyWidth: 150),
      if (total > rows.length) Padding(padding: const EdgeInsets.only(top: 4), child: Text('and ${total - rows.length} more (YAML tab)', style: hint)),
    ]);
  }
}

/// A table block: the first `limit` rows, "Show all" for the rest.
class PluginTable extends StatefulWidget {
  final Json block;
  const PluginTable(this.block, {super.key});

  @override
  State<PluginTable> createState() => _PluginTableState();
}

class _PluginTableState extends State<PluginTable> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = widget.block;
    final cols = asMapList(b['columns']);
    final rows = b['rows'] is List ? b['rows'] as List : const [];
    final total = (b['total'] as num?)?.toInt() ?? rows.length;
    final limit = (b['limit'] as num?)?.toInt() ?? 20;
    if (rows.isEmpty) return Text('${b['empty'] ?? 'None'}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    final shown = _all ? rows : rows.take(limit).toList();
    final head = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w500);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: {for (var i = 0; i < cols.length; i++) i: const FlexColumnWidth()},
        children: [
          TableRow(children: [
            for (final c in cols) Padding(padding: const EdgeInsets.only(bottom: 4, right: 8), child: Text('${c['name'] ?? ''}', style: head)),
          ]),
          for (final r in shown)
            TableRow(children: [
              for (var i = 0; i < cols.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 3, bottom: 3, right: 8),
                  child: () {
                    final cell = i < (r as List).length ? asMap(r[i]) : const <String, dynamic>{};
                    if (cell['error'] != null) return PluginErrorText('${cell['error']}');
                    return pluginValue(context, cell['value'], type: cols[i]['type'] as String?, link: cell['link'], dense: true, mono: cols[i]['mono'] == true);
                  }(),
                ),
            ]),
        ],
      ),
      if (rows.length > limit || total > rows.length)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: rows.length > limit ? () => setState(() => _all = !_all) : null,
            child: Text(_all ? 'Show fewer' : 'Show all ($total)'),
          ),
        ),
    ]);
  }
}

/// A bar block: value of max, amber from 80% and red from 90%.
class _Bar extends StatelessWidget {
  final Json block;
  const _Bar(this.block);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = (block['value'] as num?)?.toDouble();
    final max = (block['max'] as num?)?.toDouble();
    if (v == null || max == null || max <= 0) return const SizedBox.shrink();
    final frac = (v / max).clamp(0.0, 1.0);
    final pct = v / max * 100;
    final sev = pct >= 90 ? Severity.error : (pct >= 80 ? Severity.warn : Severity.ok);
    String fmt(double x) => switch (block['format']) {
          'percent' => '${x.toStringAsFixed(0)}%',
          'quantity' => x >= 1000 ? '${(x / 1000).toStringAsFixed(1)}k' : _text(x),
          _ => _text(double.parse(x.toStringAsFixed(2))),
        };
    return Row(children: [
      SizedBox(width: 140, child: Text('${block['label'] ?? ''}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
      Expanded(child: SizedBox(height: 10, child: UsageBar(frac: frac, color: severityColor(context, sev)))),
      const SizedBox(width: 10),
      Text(block['format'] == 'percent' ? fmt(v) : '${fmt(v)} / ${fmt(max)}  (${pct.toStringAsFixed(0)}%)', style: theme.textTheme.bodySmall),
    ]);
  }
}
