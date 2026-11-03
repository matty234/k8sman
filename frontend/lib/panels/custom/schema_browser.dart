import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';

/// One field in an OpenAPI v3 schema tree.
class SchemaField {
  final String name;
  final String path;
  final Json schema;
  final bool required;
  final int depth;
  final List<SchemaField> children;
  SchemaField(this.name, this.path, this.schema, this.required, this.depth, this.children);
}

/// Unwraps arrays (`items`) to the schema whose properties are the children.
Json _container(Json s) {
  var cur = s;
  var guard = 0;
  while (cur['type'] == 'array' && cur['items'] is Map && guard++ < 8) {
    cur = asMap(cur['items']);
  }
  return cur;
}

List<SchemaField> buildSchemaFields(Json schema, {String path = '', int depth = 0, bool hideEnvelope = false}) {
  if (depth > 40) return const [];
  final c = _container(schema);
  final required = {...?(c['required'] as List?)?.map((e) => '$e')};
  final out = <SchemaField>[];
  final props = asMap(c['properties']);
  for (final e in props.entries) {
    if (hideEnvelope && const {'apiVersion', 'kind', 'metadata'}.contains(e.key)) continue;
    final s = asMap(e.value);
    final p = path.isEmpty ? e.key : '$path.${e.key}';
    out.add(SchemaField(e.key, p, s, required.contains(e.key), depth, buildSchemaFields(s, path: p, depth: depth + 1)));
  }
  final addl = c['additionalProperties'];
  if (addl is Map) {
    final s = asMap(addl);
    final kids = buildSchemaFields(s, path: '$path.<key>', depth: depth + 1);
    if (kids.isNotEmpty) out.add(SchemaField('<key>', '$path.<key>', s, false, depth, kids));
  }
  return out;
}

String schemaTypeLabel(Json s) {
  if (s['x-kubernetes-int-or-string'] == true) return 'int|string';
  final t = s['type'];
  if (t == 'array') return '[]${schemaTypeLabel(asMap(s['items']))}';
  if (t == 'object' && s['additionalProperties'] is Map && s['properties'] == null) {
    return 'map[string]${schemaTypeLabel(asMap(s['additionalProperties']))}';
  }
  if (t == null) return s['x-kubernetes-preserve-unknown-fields'] == true ? 'any' : (s['properties'] != null ? 'object' : 'any');
  final f = s['format'];
  return f is String && f.isNotEmpty ? '$t($f)' : '$t';
}

/// Collapsible, searchable tree of an `openAPIV3Schema`.
class SchemaBrowser extends StatefulWidget {
  final Json schema;
  const SchemaBrowser(this.schema, {super.key});

  @override
  State<SchemaBrowser> createState() => _SchemaBrowserState();
}

class _SchemaBrowserState extends State<SchemaBrowser> {
  static const _maxRows = 400;
  final _search = TextEditingController();
  Set<String> _expanded = {'spec', 'status'};
  late List<SchemaField> _fields;
  late String _schemaKey;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(SchemaBrowser old) {
    super.didUpdateWidget(old);
    if (jsonEncode(old.schema) != _schemaKey) _rebuild();
  }

  void _rebuild() {
    _schemaKey = jsonEncode(widget.schema);
    _fields = buildSchemaFields(widget.schema, hideEnvelope: true);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Iterable<SchemaField> _all(List<SchemaField> fs) sync* {
    for (final f in fs) {
      yield f;
      yield* _all(f.children);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _search.text.trim().toLowerCase();
    final total = _all(_fields).length;

    // While searching: show matches plus their ancestors (expanded).
    Set<String>? visible;
    Set<String> expanded = _expanded;
    var matchCount = 0;
    if (q.isNotEmpty) {
      visible = {};
      expanded = {};
      for (final f in _all(_fields)) {
        if (f.path.toLowerCase().contains(q)) {
          matchCount++;
          visible.add(f.path);
          final parts = f.path.split('.');
          for (var i = 1; i < parts.length; i++) {
            final anc = parts.sublist(0, i).join('.');
            visible.add(anc);
            expanded.add(anc);
          }
        }
      }
    }

    final rows = <Widget>[];
    var truncated = false;
    void walk(List<SchemaField> fs) {
      for (final f in fs) {
        if (visible != null && !visible.contains(f.path)) continue;
        if (rows.length >= _maxRows) {
          truncated = true;
          return;
        }
        final open = expanded.contains(f.path);
        rows.add(_SchemaRow(
          field: f,
          open: open,
          highlight: q.isNotEmpty && f.path.toLowerCase().contains(q),
          onToggle: f.children.isEmpty
              ? null
              : () => setState(() {
                    if (q.isNotEmpty) return;
                    _expanded = {..._expanded};
                    open ? _expanded.remove(f.path) : _expanded.add(f.path);
                  }),
        ));
        if (open) walk(f.children);
      }
    }

    walk(_fields);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: SizedBox(
            height: 32,
            child: TextField(
              controller: _search,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                hintText: 'Filter $total fields (e.g. spec.owner)',
                prefixIcon: const Icon(Icons.search, size: 16),
                prefixIconConstraints: const BoxConstraints(minWidth: 30),
                suffixIcon: q.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 14),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(_search.clear),
                      ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Expand all',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.unfold_more),
          onPressed: () => setState(() => _expanded = {for (final f in _all(_fields)) if (f.children.isNotEmpty) f.path}),
        ),
        IconButton(
          tooltip: 'Collapse all',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.unfold_less),
          onPressed: () => setState(() => _expanded = {}),
        ),
      ]),
      if (q.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(matchCount == 0 ? 'No fields match "$q"' : '$matchCount matching ${matchCount == 1 ? 'field' : 'fields'}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        ),
      const SizedBox(height: 6),
      ...rows,
      if (truncated) InlineMessage('Showing the first $_maxRows fields; refine the filter to see more.'),
      if (_fields.isEmpty) const InlineMessage('Schema has no declared properties.'),
    ]);
  }
}

class _SchemaRow extends StatelessWidget {
  final SchemaField field;
  final bool open;
  final bool highlight;
  final VoidCallback? onToggle;
  const _SchemaRow({required this.field, required this.open, required this.highlight, this.onToggle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = field.schema;
    final hint = theme.hintColor;
    final chips = <Widget>[];
    void chip(String text, {Color? color, String? tooltip}) {
      final w = Chipish(text: text, color: color);
      chips.add(tooltip == null ? w : Tooltip(message: tooltip, child: w));
    }

    // Flags on array items are shown on the array field itself.
    final flagSrc = s['type'] == 'array' && s['items'] is Map ? {...asMap(s['items']), ...s} : s;
    final warn = severityColor(context, Severity.warn);
    final info = severityColor(context, Severity.info);
    if (s['enum'] is List) chip('enum: ${(s['enum'] as List).map((e) => e is String ? e : jsonEncode(e)).join(' | ')}');
    if (s.containsKey('default')) chip('default: ${jsonEncode(s['default'])}');
    final min = s['minimum'] ?? s['minLength'] ?? s['minItems'] ?? s['minProperties'];
    final max = s['maximum'] ?? s['maxLength'] ?? s['maxItems'] ?? s['maxProperties'];
    if (min != null || max != null) {
      final what = s.containsKey('minLength') || s.containsKey('maxLength')
          ? 'len '
          : (s.containsKey('minItems') || s.containsKey('maxItems') ? 'items ' : '');
      chip('$what${min ?? ''}..${max ?? ''}');
    }
    if (s['pattern'] is String) chip('/${s['pattern']}/');
    if (s['nullable'] == true) chip('nullable');
    if (flagSrc['x-kubernetes-preserve-unknown-fields'] == true) chip('preserve-unknown-fields', color: warn);
    if (flagSrc['x-kubernetes-int-or-string'] == true) chip('int-or-string', color: info);
    if (flagSrc['x-kubernetes-embedded-resource'] == true) chip('embedded-resource', color: info);
    if (s['x-kubernetes-list-type'] is String) {
      final keys = (s['x-kubernetes-list-map-keys'] as List?)?.join(',');
      chip('list-type: ${s['x-kubernetes-list-type']}${keys != null ? ' [$keys]' : ''}', color: info);
    }
    if (s['x-kubernetes-map-type'] is String) chip('map-type: ${s['x-kubernetes-map-type']}', color: info);
    final validations = asMapList(s['x-kubernetes-validations']);
    if (validations.any((v) => '${v['rule']}'.replaceAll(' ', '') == 'self==oldSelf')) chip('immutable', color: warn);

    final desc = s['description'] is String ? (s['description'] as String).trim() : '';
    final indent = field.depth * 14.0;
    return Container(
      color: highlight ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
      padding: EdgeInsets.only(left: indent, top: 3, bottom: 3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: onToggle,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 16,
              child: onToggle == null ? null : Icon(open ? Icons.arrow_drop_down : Icons.arrow_right, size: 16, color: hint),
            ),
            Expanded(
              child: Wrap(spacing: 6, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text.rich(TextSpan(children: [
                  TextSpan(text: field.name, style: monoStyle(context, color: theme.colorScheme.primary).copyWith(fontWeight: FontWeight.w600)),
                  if (field.required) TextSpan(text: ' *', style: monoStyle(context, color: severityColor(context, Severity.error))),
                ])),
                Text(schemaTypeLabel(s), style: monoStyle(context, size: 11, color: hint)),
                ...chips,
              ]),
            ),
          ]),
        ),
        if (desc.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 2),
            child: Text(desc, style: theme.textTheme.bodySmall?.copyWith(color: hint.withValues(alpha: 0.85), height: 1.3)),
          ),
        for (final v in validations)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.rule, size: 12, color: info)),
              const SizedBox(width: 4),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${v['rule']}', style: monoStyle(context, size: 11, color: info)),
                  if (v['message'] != null || v['messageExpression'] != null)
                    TextSpan(text: '  — ${v['message'] ?? v['messageExpression']}', style: theme.textTheme.bodySmall?.copyWith(color: hint)),
                ])),
              ),
            ]),
          ),
      ]),
    );
  }
}
