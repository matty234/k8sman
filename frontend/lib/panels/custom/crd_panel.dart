import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/group_icon.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'health.dart';
import 'schema_browser.dart';
import '../../ui/inspector/inspector.dart' show Callout;
import '../../ui/widgets/atoms.dart';

/// apiextensions.k8s.io/CustomResourceDefinition: names, versions, conversion,
/// storage migration state, instances and a searchable schema browser.
class CrdPanel extends ResourcePanel {
  const CrdPanel();

  @override
  Set<String> get kinds => const {'apiextensions.k8s.io/CustomResourceDefinition'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final versions = asMapList(spec['versions']);
    final conds = asMapList(ctx.status['conditions']);
    return [
      CoreSection('definition', DetailSection(title: 'Definition', icon: Icons.extension_outlined, child: _definition(context, ctx))),
      if (conds.isNotEmpty) CoreSection('conditions', DetailSection(title: 'Conditions', icon: Icons.checklist, child: ConditionsTable(conds))),
      CoreSection('versions', DetailSection(
        title: 'Versions',
        icon: Icons.layers_outlined,
        trailing: _count(context, versions.length),
        child: _versions(context, versions),
      )),
      CoreSection('instances', DetailSection(
        title: 'Instances',
        icon: Icons.inventory_2_outlined,
        child: CrdInstances(
          key: ValueKey('instances/${ctx.uid}'),
          api: ctx.api,
          app: ctx.app,
          group: '${spec['group'] ?? ''}',
          kind: '${dig(spec, ['names', 'kind']) ?? ''}',
          plural: '${dig(spec, ['names', 'plural']) ?? ''}',
          namespaced: spec['scope'] != 'Cluster',
        ),
      )),
      CoreSection('schema', DetailSection(
        title: 'Schema',
        icon: Icons.account_tree_outlined,
        child: _SchemaSection(key: ValueKey('schema/${ctx.uid}'), versions: versions),
      )),
    ];
  }

  static Widget _count(BuildContext context, int n) =>
      Text('$n', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor));

  Widget _chips(List? v) => v == null || v.isEmpty
      ? const SizedBox.shrink()
      : Wrap(spacing: 4, runSpacing: 4, children: [for (final s in v) Chipish(text: '$s', copyValue: '$s')]);

  Widget _definition(BuildContext context, PanelContext ctx) {
    final theme = Theme.of(context);
    final spec = ctx.spec;
    final status = ctx.status;
    final names = asMap(spec['names']);
    final accepted = asMap(status['acceptedNames']);
    final conds = asMapList(status['conditions']);
    final stored = (status['storedVersions'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    final storage = asMapList(spec['versions']).where((v) => v['storage'] == true).map((v) => '${v['name']}').firstOrNull;

    // Headline badges.
    final badges = <Widget>[];
    for (final type in const ['Established', 'NamesAccepted']) {
      final c = conds.where((c) => c['type'] == type).firstOrNull;
      if (c == null) {
        badges.add(StatusBadge('$type: ?', severity: Severity.warn));
      } else {
        badges.add(StatusBadge(c['status'] == 'True' ? type : '$type: ${c['status']}', severity: conditionSeverity(c)));
      }
    }
    final nonStructural = conds.where((c) => c['type'] == 'NonStructuralSchema' && c['status'] == 'True').firstOrNull;
    if (nonStructural != null) badges.add(const StatusBadge('Non-structural schema', severity: Severity.error));
    final terminating = conds.where((c) => c['type'] == 'Terminating' && c['status'] == 'True').isNotEmpty;
    if (terminating) badges.add(const StatusBadge('Terminating', severity: Severity.warn));
    badges.add(StatusBadge(spec['scope'] == 'Cluster' ? 'Cluster-scoped' : 'Namespaced', severity: Severity.info, dense: false));

    // Accepted names vs spec names.
    final diffs = <String>[
      for (final k in {...names.keys, ...accepted.keys})
        if (jsonEncode(names[k]) != jsonEncode(accepted[k])) k,
    ];
    final Widget acceptedW = accepted.isEmpty
        ? Text('not yet accepted', style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn)))
        : diffs.isEmpty
            ? Text('match spec', style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.ok)))
            : Text('differ from spec: ${[for (final k in diffs) '$k=${jsonEncode(accepted[k])}'].join(', ')}',
                style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn)));

    // Conversion.
    final conv = asMap(spec['conversion']);
    final strategy = '${conv['strategy'] ?? 'None'}';
    final cc = asMap(dig(conv, ['webhook', 'clientConfig']));
    final svc = asMap(cc['service']);
    final reviewVersions = dig<List>(conv, ['webhook', 'conversionReviewVersions']);
    Widget conversion = Text(strategy, style: theme.textTheme.bodySmall);
    if (strategy == 'Webhook') {
      conversion = Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('Webhook via', style: theme.textTheme.bodySmall),
        if (svc['name'] != null)
          ResourceLink(
            ObjectRef(kind: 'Service', name: '${svc['name']}', namespace: svc['namespace'] as String?),
            label: 'Service/${svc['namespace']}/${svc['name']}${svc['port'] != null ? ':${svc['port']}' : ''}${svc['path'] ?? ''}',
          ),
        if (cc['url'] != null) Text('${cc['url']}', style: monoStyle(context, size: 11)),
        if (reviewVersions != null) Text('review ${reviewVersions.join(', ')}', style: hintMono(context)),
        if (cc['caBundle'] == null && svc.isNotEmpty) Text('no caBundle', style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn))),
      ]);
    }

    final storedW = Wrap(spacing: 4, runSpacing: 4, children: [
      for (final v in stored) Chipish(text: v == storage ? '$v (storage)' : v, color: v == storage ? null : severityColor(context, Severity.warn)),
    ]);

    final group = '${spec['group'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (group.isNotEmpty) ...[GroupIcon(group: group, size: 28), const SizedBox(width: 10)],
        Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: badges)),
      ]),
      const SizedBox(height: 8),
      KeyValueTable([
        ('Group', Text('${spec['group'] ?? ''}', style: monoStyle(context, size: 12))),
        ('Kind', Text('${names['kind'] ?? ''}', style: monoStyle(context, size: 12))),
        ('Plural / singular', Text('${names['plural'] ?? ''} / ${names['singular'] ?? ''}', style: monoStyle(context, size: 12))),
        ('List kind', names['listKind'] == null ? null : Text('${names['listKind']}', style: monoStyle(context, size: 12))),
        ('Short names', (names['shortNames'] as List?)?.isNotEmpty == true ? _chips(names['shortNames'] as List) : null),
        ('Categories', (names['categories'] as List?)?.isNotEmpty == true ? _chips(names['categories'] as List) : null),
        ('Accepted names', acceptedW),
        ('Conversion', conversion),
        ('Stored versions', stored.isEmpty ? null : storedW),
      ], keyWidth: 120),
      if (stored.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _warnBox(
            context,
            'Storage migration pending: objects may still be persisted as ${stored.where((v) => v != storage).join(', ')}. '
            'Rewrite all objects at the storage version ($storage), then drop the old entries from status.storedVersions.',
          ),
        ),
      if (nonStructural != null)
        Padding(padding: const EdgeInsets.only(top: 6), child: _warnBox(context, '${nonStructural['message'] ?? 'Schema is not structural'}', error: true)),
    ]);
  }

  static Widget _warnBox(BuildContext context, String text, {bool error = false}) =>
      Callout(severity: error ? Severity.error : Severity.warn, icon: Icons.warning_amber_rounded, title: text);

  Widget _versions(BuildContext context, List<Json> versions) {
    final theme = Theme.of(context);
    if (versions.isEmpty) return const InlineMessage('No versions');
    Widget yes(bool v, String label, Severity sev) =>
        v ? StatusBadge(label, severity: sev, dense: true) : Text('—', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));

    final table = CompactTable(
      headers: CompactTable.textHeaders(context, ['Version', 'Served', 'Storage', 'Deprecated', 'Subresources']),
      rows: [
        for (final v in versions)
          [
            Text('${v['name']}', style: monoStyle(context).copyWith(fontWeight: FontWeight.w600)),
            v['served'] == true ? const StatusBadge('served', severity: Severity.ok, dense: true) : const StatusBadge('no', severity: Severity.neutral, dense: true),
            yes(v['storage'] == true, 'storage', Severity.info),
            yes(v['deprecated'] == true, 'deprecated', Severity.warn),
            Wrap(spacing: 4, runSpacing: 2, children: [
              for (final k in asMap(v['subresources']).keys) Chipish(text: k),
              if (asMap(v['subresources']).isEmpty) Text('—', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ],
      ],
    );

    final details = <Widget>[];
    for (final v in versions) {
      final name = '${v['name']}';
      if (v['deprecated'] == true) {
        details.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _warnBox(context, '$name is deprecated${v['deprecationWarning'] != null ? ': ${v['deprecationWarning']}' : ''}'),
        ));
      }
      final scale = asMap(dig(v, ['subresources', 'scale']));
      if (scale.isNotEmpty) {
        details.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('$name scale: ${[for (final e in scale.entries) '${e.key}=${e.value}'].join('  ')}', style: hintMono(context)),
        ));
      }
    }

    // Printer columns, grouped when identical across versions.
    final groups = <String, List<String>>{};
    final colsByKey = <String, List<Json>>{};
    for (final v in versions) {
      final cols = asMapList(v['additionalPrinterColumns']);
      final key = jsonEncode(cols);
      (groups[key] ??= []).add('${v['name']}');
      colsByKey[key] = cols;
    }
    for (final e in groups.entries) {
      final cols = colsByKey[e.key]!;
      final which = versions.length == 1 ? '' : (e.value.length == versions.length ? ' (all versions)' : ' (${e.value.join(', ')})');
      details.add(Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text('Printer columns$which', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
      ));
      if (cols.isEmpty) {
        details.add(Text('none (Name and Age only)', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)));
        continue;
      }
      final hasPriority = cols.any((c) => (c['priority'] ?? 0) != 0);
      details.add(CompactTable(
        headers: CompactTable.textHeaders(context, ['Name', 'Type', 'JSONPath', if (hasPriority) 'Priority']),
        rows: [
          for (final c in cols)
            [
              Tooltip(
                message: '${c['description'] ?? c['name']}',
                child: Text('${c['name']}', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Text('${c['type'] ?? ''}${c['format'] != null ? '(${c['format']})' : ''}', style: hintMono(context)),
              Text('${c['jsonPath'] ?? ''}', style: monoStyle(context, size: 11)),
              if (hasPriority) Text('${c['priority'] ?? 0}', style: monoStyle(context, size: 11)),
            ],
        ],
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [table, ...details]);
  }
}

/// Counts instances of the CRD's kind and offers to open them in the table.
class CrdInstances extends StatefulWidget {
  final ApiClient api;
  final AppState app;
  final String group;
  final String kind;
  final String plural;
  final bool namespaced;
  const CrdInstances({
    super.key,
    required this.api,
    required this.app,
    required this.group,
    required this.kind,
    required this.plural,
    required this.namespaced,
  });

  @override
  State<CrdInstances> createState() => _CrdInstancesState();
}

class _CrdInstancesState extends State<CrdInstances> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void didUpdateWidget(CrdInstances old) {
    super.didUpdateWidget(old);
    if (old.group != widget.group || old.plural != widget.plural) _future = _fetch();
  }

  Future<List<Json>> _fetch() => widget.api.items(ResourceRef(group: widget.group, resource: widget.plural));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = widget.app.typeFor(widget.group, widget.kind);
    return AsyncSection<List<Json>>(
      future: _future,
      builder: (context, items) {
        final byNs = <String, int>{};
        for (final i in items) {
          final ns = dig<String>(i, ['metadata', 'namespace']) ?? '';
          byNs[ns] = (byNs[ns] ?? 0) + 1;
        }
        final sorted = [...items]..sort((a, b) => '${dig(a, ['metadata', 'name'])}'.compareTo('${dig(b, ['metadata', 'name'])}'));
        const shown = 8;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('${items.length}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${items.length == 1 ? widget.kind : widget.plural}'
                '${widget.namespaced && items.isNotEmpty ? ' in ${byNs.length} namespace${byNs.length == 1 ? '' : 's'}' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ),
            Tooltip(
              message: type == null ? 'Type not served (yet) by the API server' : 'Switch the main table to ${widget.kind}',
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: theme.textTheme.labelMedium),
                onPressed: type == null ? null : () => widget.app.selectType(type),
                icon: const Icon(Icons.table_rows_outlined, size: 14),
                label: Text('Show ${widget.plural}'),
              ),
            ),
          ]),
          if (widget.namespaced && byNs.length > 1) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final e in (byNs.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))) Chipish(text: '${e.key}: ${e.value}'),
            ]),
          ],
          if (items.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 12, runSpacing: 4, children: [
              for (final i in sorted.take(shown))
                ResourceLink(
                  ObjectRef(
                    group: widget.group,
                    kind: widget.kind,
                    name: '${dig(i, ['metadata', 'name'])}',
                    namespace: dig<String>(i, ['metadata', 'namespace']),
                  ),
                  label: [dig<String>(i, ['metadata', 'namespace']), dig<String>(i, ['metadata', 'name'])].whereType<String>().join('/'),
                ),
              if (items.length > shown) Text('+${items.length - shown} more', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ],
        ]);
      },
    );
  }
}

class _SchemaSection extends StatefulWidget {
  final List<Json> versions;
  const _SchemaSection({super.key, required this.versions});

  @override
  State<_SchemaSection> createState() => _SchemaSectionState();
}

class _SchemaSectionState extends State<_SchemaSection> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final versions = widget.versions;
    if (versions.isEmpty) return const InlineMessage('No versions');
    final names = versions.map((v) => '${v['name']}').toList();
    final storage = versions.where((v) => v['storage'] == true).map((v) => '${v['name']}').firstOrNull ?? names.first;
    final sel = names.contains(_selected) ? _selected! : storage;
    final v = versions.firstWhere((v) => v['name'] == sel);
    final schema = dig<Map>(v, ['schema', 'openAPIV3Schema']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (names.length > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            for (final n in names)
              ChoiceChip(
                label: Text(n == storage ? '$n (storage)' : n),
                selected: n == sel,
                visualDensity: VisualDensity.compact,
                labelStyle: monoStyle(context, size: 11),
                onSelected: (_) => setState(() => _selected = n),
              ),
          ]),
        ),
      if (schema == null)
        const InlineMessage('No openAPIV3Schema for this version.')
      else
        SchemaBrowser(asMap(schema), key: ValueKey('schema-$sel')),
    ]);
  }
}
