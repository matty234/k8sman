import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../network/widgets.dart';
import '../panel.dart';
import '../pod/pod_widgets.dart';
import 'es_common.dart';

/// ExternalSecret: sync status, the store and target Secret, the data
/// mapping and the template.
class ExternalSecretPanel extends ResourcePanel {
  const ExternalSecretPanel();

  @override
  Set<String> get kinds => {'$esGroup/ExternalSecret'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => [
        ResourceAction(
          id: 'externalsecrets-refresh',
          label: 'Refresh now',
          icon: Icons.sync,
          tooltip: 'Set the force-sync annotation so the operator re-reads the provider',
          run: (c) => runResourceAction(c, ctx, 'externalsecrets-refresh', confirm: false, title: 'Refresh ${ctx.name}'),
        ),
      ];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final status = ctx.status;
    final ns = ctx.namespace;
    final target = asMap(spec['target']);
    final targetName = (target['name'] as String?) ?? ctx.name;
    final refreshTime = parseTime(status['refreshTime']);
    final policy = spec['refreshPolicy'] as String?;
    final data = asMapList(spec['data']);
    final dataFrom = asMapList(spec['dataFrom']);
    final template = target['template'];
    return [
      DetailSection(
        title: 'Sync status',
        icon: Icons.sync_alt,
        card: true,
        trailing: readyBadge(status),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ReadyCallout(status),
          KeyValueTable([
            ('Last refresh', refreshTime == null ? null : Text('${status['refreshTime']} (${formatAge(refreshTime)} ago)')),
            ('Refresh interval', policy != null && policy != 'Periodic' ? policy : '${spec['refreshInterval'] ?? '1h'}'),
            ('Synced version', status['syncedResourceVersion'] == null ? null : MonoValue('${status['syncedResourceVersion']}', size: 11)),
          ], keyWidth: 110),
        ]),
      ),
      DetailSection(
        title: 'Store and target',
        icon: Icons.link,
        child: KeyValueTable([
          ('Store', asMap(spec['secretStoreRef']).isEmpty ? null : storeLink(asMap(spec['secretStoreRef']), ns)),
          (
            'Target Secret',
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InlineWrap([
                ResourceLink(secretRef(targetName, ns), label: 'Secret/$targetName'),
                Chipish(text: 'create: ${target['creationPolicy'] ?? 'Owner'}'),
                Chipish(text: 'delete: ${target['deletionPolicy'] ?? 'Retain'}'),
              ]),
              _MissingTarget(key: ValueKey('${ctx.uid}/target/$targetName'), ctx: ctx, name: targetName),
            ])
          ),
        ], keyWidth: 110),
      ),
      if (data.isNotEmpty || dataFrom.isNotEmpty)
        DetailSection(
          title: 'Data mapping',
          icon: Icons.table_rows_outlined,
          trailing: Hint('${data.length + dataFrom.length}'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (data.isNotEmpty) _DataTable(data),
            for (final f in dataFrom) Padding(padding: const EdgeInsets.only(top: 4), child: _DataFromLine(f)),
          ]),
        ),
      if (template is Map && template.isNotEmpty)
        DetailSection(title: 'Template', icon: Icons.description_outlined, initiallyExpanded: false, child: JsonTree(template)),
    ];
  }
}

/// A warning when the target Secret does not exist (404). Reads the Secret
/// once per ExternalSecret and target name; other errors say nothing.
class _MissingTarget extends StatelessWidget {
  final PanelContext ctx;
  final String name;
  const _MissingTarget({super.key, required this.ctx, required this.name});

  @override
  Widget build(BuildContext context) => NetFetch<bool>(
        fetchKey: name,
        load: () => ctx.api
            .object(const ResourceRef(resource: 'secrets'), namespace: ctx.namespace, name: name)
            .then((_) => false)
            .catchError((Object e) => e is ApiException && e.status == 404),
        builder: (context, snap, _) => snap.data == true
            ? const Padding(padding: EdgeInsets.only(top: 4), child: InlineMessage('The target Secret does not exist yet.', isError: true))
            : const SizedBox.shrink(),
      );
}

class _DataTable extends StatelessWidget {
  final List<Json> data;
  const _DataTable(this.data);

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor);
    Widget head(String t) => Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(t, style: hint));
    Widget cell(String? t) => Padding(padding: const EdgeInsets.only(bottom: 3, right: 8), child: MonoValue(t ?? '', size: 11));
    return Table(
      columnWidths: const {0: FlexColumnWidth(1.2), 1: FlexColumnWidth(1.6), 2: FlexColumnWidth(1), 3: FlexColumnWidth(0.6)},
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        TableRow(children: [head('Secret key'), head('Remote key'), head('Property'), head('Version')]),
        for (final d in data)
          TableRow(children: [
            cell('${d['secretKey'] ?? ''}'),
            cell('${dig(d, ['remoteRef', 'key']) ?? ''}'),
            cell(dig<String>(d, ['remoteRef', 'property'])),
            cell(dig<String>(d, ['remoteRef', 'version'])),
          ]),
      ],
    );
  }
}

/// One `dataFrom` entry on a line: extract, find, rewrite or a generator.
class _DataFromLine extends StatelessWidget {
  final Json f;
  const _DataFromLine(this.f);

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    final extract = asMap(f['extract']);
    if (extract.isNotEmpty) {
      parts.add('extract ${extract['key'] ?? ''}${extract['property'] != null ? ' · ${extract['property']}' : ''}${extract['version'] != null ? ' @ ${extract['version']}' : ''}');
    }
    final find = asMap(f['find']);
    if (find.isNotEmpty) {
      final tags = asMap(find['tags']);
      parts.add('find ${[
        if (dig<String>(find, ['name', 'regexp']) != null) 'name ~ ${dig<String>(find, ['name', 'regexp'])}',
        if (find['path'] != null) 'path ${find['path']}',
        if (tags.isNotEmpty) 'tags ${tags.entries.map((e) => '${e.key}=${e.value}').join(',')}',
      ].join(' · ')}');
    }
    for (final r in asMapList(f['rewrite'])) {
      final re = asMap(r['regexp']);
      parts.add(re.isEmpty ? 'rewrite ${r.keys.join(',')}' : 'rewrite ${re['source']} → ${re['target']}');
    }
    final gen = asMap(dig(f, ['sourceRef', 'generatorRef']));
    if (gen.isNotEmpty) parts.add('generator ${gen['kind']}/${gen['name']}');
    final store = asMap(dig(f, ['sourceRef', 'storeRef']));
    if (store.isNotEmpty) parts.add('store ${store['kind'] ?? 'SecretStore'}/${store['name']}');
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('dataFrom  ', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
      Expanded(child: MonoValue(parts.isEmpty ? '(empty)' : parts.join('  |  '), size: 11)),
    ]);
  }
}
