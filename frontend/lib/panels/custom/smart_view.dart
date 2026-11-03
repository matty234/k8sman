import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import 'crd_schema.dart';
import 'humanize.dart';
import 'refs.dart';

bool _isScalar(dynamic v) => v == null || v is String || v is num || v is bool;

/// Renders arbitrary JSON (spec, status, data, …) as readable key/values:
/// humanised labels (raw path + schema description on hover), scalar arrays
/// as chips, homogeneous object arrays as compact tables, long strings as
/// code blocks, references as [ResourceLink]s, and deep nesting collapsible.
class SmartObjectView extends StatelessWidget {
  final dynamic value;
  final RefResolver refs;

  /// OpenAPI schema for [value], if known (descriptions become tooltips).
  final Json? schema;

  /// Dotted path of [value], e.g. `spec` (shown in label tooltips).
  final String path;
  final int depth;

  /// Extra widgets shown after the value of a direct child field (by key),
  /// e.g. a scale control beside `replicas`.
  final Map<String, Widget> trailing;

  const SmartObjectView(this.value,
      {super.key, this.refs = const RefResolver(), this.schema, this.path = '', this.depth = 0, this.trailing = const {}});

  @override
  Widget build(BuildContext context) {
    final v = value;
    if (v is Map) {
      final m = asMap(v);
      if (m.isEmpty) return _muted(context, 'empty');
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final e in m.entries) _entry(context, e.key, e.value),
      ]);
    }
    if (v is List) return _list(context, '', v, schema, path);
    return _scalar(context, '', v);
  }

  double get _keyWidth => (150 - depth * 14).clamp(96, 150).toDouble();

  String _childPath(String key) => path.isEmpty ? key : '$path.$key';

  Widget _entry(BuildContext context, String key, dynamic v) {
    final childSchema = schemaChild(schema, key);
    final childPath = _childPath(key);
    final label = FieldLabel(key: ValueKey('label:$childPath'), field: key, path: childPath, description: schemaDescription(childSchema));

    if (v is Map) {
      final m = asMap(v);
      final ref = refs.fromMap(key, m);
      if (ref != null) return _row(label, _refWithExtras(context, ref, m));
      if (m.isEmpty) return _row(label, _muted(context, 'empty'));
      final allScalar = m.values.every(_isScalar);
      return _Collapsible(
        title: label,
        summary: '${m.length} ${m.length == 1 ? 'field' : 'fields'}',
        initiallyOpen: depth < 2 || (allScalar && m.length <= 6),
        child: SmartObjectView(m, refs: refs, schema: childSchema, path: childPath, depth: depth + 1),
      );
    }
    if (v is List) {
      if (v.isEmpty) return _row(label, _muted(context, 'none'));
      final refList = refs.fromList(key, v);
      if (refList != null) {
        return _row(label, Wrap(spacing: 10, runSpacing: 2, children: [for (final r in refList) ResourceLink(r, label: refs.label(r))]));
      }
      if (v.every(_isScalar)) return _row(label, _chips(context, v));
      return _Collapsible(
        title: label,
        summary: '${v.length} ${v.length == 1 ? 'item' : 'items'}',
        initiallyOpen: depth < 3,
        child: _list(context, key, v, childSchema, childPath),
      );
    }
    final ref = refs.fromScalar(key, v);
    if (ref != null) return _row(label, ResourceLink(ref, label: refs.label(ref)));
    if (v is String && _isLong(v)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          label,
          const SizedBox(height: 3),
          CodeBlock(v, maxLines: '\n'.allMatches(v).length > 14 ? 14 : null),
        ]),
      );
    }
    final extra = trailing[key];
    if (extra != null) {
      return _row(label, Row(children: [Flexible(child: _scalar(context, key, v)), const SizedBox(width: 8), extra]));
    }
    return _row(label, _scalar(context, key, v));
  }

  static bool _isLong(String s) => s.length > 120 || s.contains('\n');

  Widget _row(Widget label, Widget value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: _keyWidth, child: Padding(padding: const EdgeInsets.only(right: 8), child: label)),
          Expanded(child: value),
        ]),
      );

  Widget _refWithExtras(BuildContext context, ObjectRef ref, Json m) {
    const identity = {'name', 'kind', 'apiVersion', 'apiGroup', 'group', 'namespace', 'uid', 'resourceVersion'};
    final extras = [
      for (final e in m.entries)
        if (!identity.contains(e.key)) '${e.key}: ${_isScalar(e.value) ? e.value : jsonEncode(e.value)}',
    ];
    final link = ResourceLink(ref, label: refs.label(ref));
    if (extras.isEmpty) return Align(alignment: Alignment.centerLeft, child: link);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
      link,
      Text(extras.join(' · '), style: monoStyle(context, size: 11, color: Theme.of(context).hintColor)),
    ]);
  }

  Widget _list(BuildContext context, String key, List v, Json? listSchema, String listPath) {
    if (v.isEmpty) return _muted(context, 'none');
    if (v.every(_isScalar)) return _chips(context, v);
    final itemSchema = schemaItems(listSchema);
    if (v.every((e) => e is Map)) {
      final items = asMapList(v);
      if (key == 'conditions' && items.every((c) => c.containsKey('type') && c.containsKey('status'))) return ConditionsTable(items);
      final cols = _tableColumns(items);
      if (cols != null) {
        return CompactTable(
          headers: [
            for (final c in cols)
              FieldLabel(field: c, path: '$listPath[].$c', description: schemaDescription(schemaChild(itemSchema, c)), header: true),
          ],
          rows: [
            for (final item in items) [for (final c in cols) _cell(context, c, item[c])],
          ],
        );
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < v.length; i++)
        v[i] is Map || v[i] is List
            ? _Collapsible(
                title: Text(_itemTitle(v[i], i), style: monoStyle(context, size: 12, color: Theme.of(context).colorScheme.primary)),
                summary: v[i] is Map ? '${(_withoutTitleKey(v[i]) as Map).length} fields' : '${(v[i] as List).length} items',
                initiallyOpen: v.length <= 3,
                child: SmartObjectView(_withoutTitleKey(v[i]), refs: refs, schema: itemSchema, path: '$listPath[$i]', depth: depth + 1),
              )
            : _scalar(context, '', v[i]),
    ]);
  }

  static const _titleKeys = ['name', 'type', 'id', 'key', 'path', 'host', 'port'];

  static String? _titleKey(dynamic item) {
    if (item is! Map) return null;
    for (final k in _titleKeys) {
      if (_isScalar(item[k]) && item[k] != null) return k;
    }
    return null;
  }

  /// `name` items are titled by the bare value; other title keys keep a prefix.
  static String _itemTitle(dynamic item, int i) {
    final k = _titleKey(item);
    if (k == null) return '#${i + 1}';
    return k == 'name' ? '${item[k]}' : '$k: ${item[k]}';
  }

  /// The item without the field already shown as its title.
  static dynamic _withoutTitleKey(dynamic item) {
    final k = _titleKey(item);
    if (k == null || item is! Map || item.length < 2) return item;
    return {for (final e in item.entries) if (e.key != k) e.key: e.value};
  }

  /// Columns if [items] are homogeneous flat objects that fit a table.
  List<String>? _tableColumns(List<Json> items) {
    final cols = <String>[];
    for (final it in items) {
      for (final k in it.keys) {
        if (!cols.contains(k)) cols.add(k);
      }
    }
    if (cols.isEmpty || cols.length > 5) return null;
    for (final it in items) {
      for (final e in it.entries) {
        final v = e.value;
        final ok = _isScalar(v) ||
            (v is List && v.every(_isScalar) && v.length <= 8) ||
            (v is Map && (v.isEmpty || refs.fromMap(e.key, asMap(v)) != null));
        if (!ok) return null;
      }
    }
    return cols;
  }

  Widget _cell(BuildContext context, String key, dynamic v) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    if (v == null) return Text('—', style: style?.copyWith(color: theme.hintColor));
    if (v is Map) {
      final ref = refs.fromMap(key, asMap(v));
      return ref != null ? ResourceLink(ref, label: refs.label(ref)) : Text('—', style: style?.copyWith(color: theme.hintColor));
    }
    if (v is List) return Text(v.map((e) => e == '' ? '""' : '$e').join(', '), style: monoStyle(context, size: 11));
    final ref = refs.fromScalar(key, v);
    if (ref != null) return ResourceLink(ref, label: v.toString());
    if (looksLikeTimestamp(v)) return AgeText(v, suffix: ' ago', style: style);
    if (v is bool) return _bool(context, v);
    if (v is num) return Text('$v', style: monoStyle(context, size: 11));
    final s = '$v';
    final text = Text(s, style: style, maxLines: 3, overflow: TextOverflow.ellipsis);
    return s.length > 60 ? Tooltip(message: s, child: text) : text;
  }

  Widget _chips(BuildContext context, List v) {
    const max = 40;
    return Wrap(spacing: 4, runSpacing: 4, children: [
      for (final s in v.take(max)) Chipish(text: s is String ? s : jsonEncode(s), copyValue: '$s'),
      if (v.length > max) _muted(context, '+${v.length - max} more'),
    ]);
  }

  Widget _scalar(BuildContext context, String key, dynamic v) {
    final theme = Theme.of(context);
    if (v == null) return _muted(context, 'null');
    if (v is bool) return _bool(context, v);
    if (v is num) return SelectableText('$v', style: monoStyle(context, color: theme.colorScheme.tertiary));
    final s = '$v';
    if (looksLikeTimestamp(s)) {
      return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
        AgeText(s, suffix: ' ago', style: theme.textTheme.bodySmall),
        Text(s, style: monoStyle(context, size: 11, color: theme.hintColor)),
      ]);
    }
    if (_isLong(s)) return CodeBlock(s);
    return SelectableText(s, style: theme.textTheme.bodySmall);
  }

  static Widget _bool(BuildContext context, bool v) => Text(
        v ? 'true' : 'false',
        style: monoStyle(context, size: 12, color: v ? severityColor(context, Severity.ok) : Theme.of(context).hintColor),
      );

  static Widget _muted(BuildContext context, String s) =>
      Text(s, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor, fontStyle: FontStyle.italic));
}

/// A humanised field label. Hover shows the raw path and the schema
/// description; labels with a description get a dotted underline.
class FieldLabel extends StatelessWidget {
  final String field;
  final String path;
  final String? description;
  final bool header;
  const FieldLabel({super.key, required this.field, required this.path, this.description, this.header = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(
      color: header ? theme.colorScheme.onSurfaceVariant : theme.hintColor,
      fontWeight: header ? FontWeight.w600 : null,
      decoration: description != null ? TextDecoration.underline : null,
      decorationStyle: TextDecorationStyle.dotted,
      decorationColor: theme.hintColor.withValues(alpha: 0.6),
    );
    final text = humanize(field);
    return Tooltip(
      message: description == null ? path : '$path\n\n$description',
      waitDuration: const Duration(milliseconds: 400),
      constraints: const BoxConstraints(maxWidth: 420),
      child: Text(text, style: base, softWrap: true),
    );
  }
}

/// Collapsible nested block with an indented, left-ruled body.
class _Collapsible extends StatefulWidget {
  final Widget title;
  final String summary;
  final bool initiallyOpen;
  final Widget child;
  const _Collapsible({required this.title, required this.summary, required this.initiallyOpen, required this.child});

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Icon(_open ? Icons.arrow_drop_down : Icons.arrow_right, size: 16, color: theme.hintColor),
              Flexible(child: DefaultTextStyle.merge(style: const TextStyle(fontWeight: FontWeight.w600), child: widget.title)),
              const SizedBox(width: 6),
              Text(widget.summary, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor.withValues(alpha: 0.7))),
            ]),
          ),
        ),
        if (_open)
          Container(
            margin: const EdgeInsets.only(left: 7, top: 2, bottom: 2),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)))),
            child: widget.child,
          ),
      ]),
    );
  }
}

/// Dense table: header row + rows of widgets. Columns size to content and
/// shrink (wrapping) when space is tight.
class CompactTable extends StatelessWidget {
  final List<Widget> headers;
  final List<List<Widget>> rows;
  const CompactTable({super.key, required this.headers, required this.rows});

  /// Convenience for plain-string headers.
  static List<Widget> textHeaders(BuildContext context, List<String> h) {
    final theme = Theme.of(context);
    return [
      for (final s in h)
        Text(s, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45));
    Widget pad(Widget w) => Padding(padding: const EdgeInsets.fromLTRB(0, 4, 12, 4), child: Align(alignment: Alignment.centerLeft, child: w));
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        TableRow(decoration: BoxDecoration(border: Border(bottom: line)), children: [for (final h in headers) pad(h)]),
        for (var i = 0; i < rows.length; i++)
          TableRow(
            decoration: BoxDecoration(border: i == rows.length - 1 ? null : Border(bottom: line.copyWith(color: line.color.withValues(alpha: 0.2)))),
            children: [for (final c in rows[i]) pad(c)],
          ),
      ],
    );
  }
}
