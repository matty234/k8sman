import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'application_panel.dart';
import 'argo_common.dart';

class ApplicationSetPanel extends ResourcePanel {
  const ApplicationSetPanel();

  @override
  Set<String> get kinds => const {'argoproj.io/ApplicationSet'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final generators = asMapList(spec['generators']);
    final generated = asMapList(ctx.status['resources']);
    final refreshKey = [for (final r in generated) '${r['name']}:${dig(r, ['health', 'status'])}:${r['status']}'].join('|');
    return [
      DetailSection(title: 'Status', icon: Icons.monitor_heart_outlined, card: true, child: AppSetSummary(ctx: ctx)),
      DetailSection(
        title: 'Generated applications',
        icon: Icons.apps,
        trailing: Text('${ctx.status['resourcesCount'] ?? generated.length}'),
        child: GeneratedApps(key: ValueKey('apps-${ctx.uid}'), ctx: ctx, refreshKey: refreshKey),
      ),
      DetailSection(
        title: generators.length == 1 ? 'Generator' : 'Generators (${generators.length})',
        icon: Icons.auto_awesome_motion_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (generators.isEmpty) const Hint('No generators'),
          for (final g in generators) GeneratorView(generator: g),
        ]),
      ),
      DetailSection(title: 'Template', icon: Icons.description_outlined, child: AppSetTemplateView(spec: spec)),
      DetailSection(title: 'Conditions', icon: Icons.checklist, child: AppSetConditions(asMapList(ctx.status['conditions']))),
    ];
  }
}

/// Condition severity for ApplicationSets (ErrorOccurred is bad when True).
Severity appSetConditionSeverity(Json c) {
  final type = '${c['type']}';
  final on = c['status'] == 'True';
  switch (type) {
    case 'ErrorOccurred':
      return on ? Severity.error : Severity.ok;
    case 'ParametersGenerated':
    case 'ResourcesUpToDate':
      return on ? Severity.ok : Severity.error;
    case 'RolloutProgressing':
      return on ? Severity.info : Severity.ok;
  }
  return on ? Severity.ok : Severity.warn;
}

/// The error message when an AppSet is failing, else null.
String? appSetError(Json status) {
  for (final c in asMapList(status['conditions'])) {
    if (appSetConditionSeverity(c) == Severity.error) return '${c['message'] ?? c['reason'] ?? c['type']}';
  }
  return null;
}

class AppSetSummary extends StatelessWidget {
  final PanelContext ctx;
  const AppSetSummary({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final spec = ctx.spec;
    final st = ctx.status;
    final error = appSetError(st);
    final health = dig<String>(st, ['health', 'status']) ?? (error == null ? 'Healthy' : 'Degraded');
    final policy = asMap(spec['syncPolicy']);
    final appsSync = policy['applicationsSync'] as String?;
    final strategy = asMap(spec['strategy']);
    final steps = asMapList(dig(strategy, ['rollingSync', 'steps']));
    final count = st['resourcesCount'] ?? asMapList(st['resources']).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 6, children: [
        ArgoBadge.health(context, error != null ? 'Degraded' : health, large: true, tooltip: 'ApplicationSet health'),
        ArgoBadge(ArgoStyle(Icons.apps, Theme.of(context).colorScheme.primary, Severity.info), '$count application${count == 1 ? '' : 's'}', large: true),
      ]),
      const SizedBox(height: 10),
      if (error != null) ArgoCallout(severity: Severity.error, icon: Icons.error_outline, title: 'Generation failed', message: error),
      KeyValueTable([
        ('Generators', generatorSummary(asMapList(spec['generators']))),
        (
          'Apps sync',
          Text.rich(TextSpan(children: [
            TextSpan(text: appsSync ?? 'sync'),
            TextSpan(
              text: '  ${_appsSyncHelp(appsSync)}',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ])),
        ),
        (
          'On deletion',
          policy['preserveResourcesOnDeletion'] == true
              ? 'Preserve: deleting the set keeps the apps\' resources'
              : 'Cascade: deleting the set deletes its apps and their resources',
        ),
        if (spec['goTemplate'] == true)
          ('Templating', 'Go templates${(spec['goTemplateOptions'] as List?)?.isNotEmpty == true ? ' (${(spec['goTemplateOptions'] as List).join(', ')})' : ''}')
        else
          ('Templating', 'fasttemplate ({{param}})'),
        if (strategy.isNotEmpty) ('Strategy', steps.isEmpty ? '${strategy['type'] ?? '?'}' : '${strategy['type'] ?? 'RollingSync'}: ${steps.length} steps'),
        if (asMapList(spec['ignoreApplicationDifferences']).isNotEmpty) ('Ignored diffs', '${asMapList(spec['ignoreApplicationDifferences']).length} rules'),
      ], keyWidth: 100),
      if (steps.isNotEmpty) ...[
        const SizedBox(height: 4),
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(left: 100, bottom: 2),
            child: Text(
              'Step ${i + 1}: ${asMapList(steps[i]['matchExpressions']).map((e) => '${e['key']} ${e['operator']} ${(e['values'] as List?)?.join(',') ?? ''}').join(' & ')}'
              '${steps[i]['maxUpdate'] != null ? ' · max ${steps[i]['maxUpdate']}' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    ]);
  }

  static String _appsSyncHelp(String? policy) => switch (policy) {
        'create-only' => 'never updates or deletes apps',
        'create-update' => 'never deletes apps',
        'create-delete' => 'never updates apps',
        _ => 'creates, updates and deletes apps',
      };
}

String _generatorKey(Json g) => g.keys.firstWhere((k) => k != 'selector' && k != 'values', orElse: () => '?');

/// `list, matrix(git+clusters)`.
String generatorSummary(List<Json> gens) => gens
    .map((g) {
      final k = _generatorKey(g);
      if (k == 'matrix' || k == 'merge') return '$k(${asMapList(dig(g, [k, 'generators'])).map(_generatorKey).join(' + ')})';
      return k;
    })
    .join(', ');

const _generatorTitles = {
  'list': 'List',
  'clusters': 'Clusters',
  'git': 'Git',
  'matrix': 'Matrix',
  'merge': 'Merge',
  'scmProvider': 'SCM provider',
  'pullRequest': 'Pull requests',
  'clusterDecisionResource': 'Cluster decision resource',
  'plugin': 'Plugin',
};

/// One generator, readable; matrix/merge render their children nested.
class GeneratorView extends StatelessWidget {
  final Json generator;
  final int depth;
  const GeneratorView({super.key, required this.generator, this.depth = 0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = _generatorKey(generator);
    final g = asMap(generator[key]);
    final selector = asMap(generator['selector']);
    final body = <Widget>[];
    String subtitle = '';
    switch (key) {
      case 'list':
        final elements = asMapList(g['elements']);
        subtitle = '${elements.length} element${elements.length == 1 ? '' : 's'}';
        body.add(_ElementsTable(elements));
        if (g['elementsYaml'] != null) body.add(CodeBlock('${g['elementsYaml']}'));
      case 'clusters':
        final sel = asMap(g['selector']);
        subtitle = sel.isEmpty ? 'every registered cluster' : 'clusters matching a selector';
        body.add(KeyValueTable([
          if (sel.isNotEmpty) ('Selector', LabelChips(asMap(sel['matchLabels']).isEmpty ? {'selector': selectorToString(sel)} : asMap(sel['matchLabels']))),
          if (asMap(g['values']).isNotEmpty) ('Values', LabelChips(asMap(g['values']))),
        ], keyWidth: 90));
      case 'git':
        final dirs = asMapList(g['directories']);
        final files = asMapList(g['files']);
        subtitle = dirs.isNotEmpty ? 'one app per directory' : (files.isNotEmpty ? 'one app per config file' : '');
        body.add(KeyValueTable([
          ('Repository', CopyChip('${g['repoURL'] ?? ''}')),
          ('Revision', '${g['revision'] ?? 'HEAD'}'),
          if (dirs.isNotEmpty)
            ('Directories', Chips([for (final d in dirs) Chipish(text: d['exclude'] == true ? '✗ ${d['path']}' : '${d['path']}')])),
          if (files.isNotEmpty) ('Files', Chips([for (final f in files) Chipish(text: '${f['path']}')])),
          if (g['pathParamPrefix'] != null) ('Param prefix', '${g['pathParamPrefix']}'),
          if (g['requeueAfterSeconds'] != null) ('Requeue', '${g['requeueAfterSeconds']}s'),
          if (asMap(g['values']).isNotEmpty) ('Values', LabelChips(asMap(g['values']))),
        ], keyWidth: 90));
      case 'matrix':
      case 'merge':
        final children = asMapList(g['generators']);
        subtitle = key == 'matrix' ? 'every combination of ${children.length} generators' : 'merged on ${(g['mergeKeys'] as List?)?.join(', ') ?? '?'}';
        for (final c in children) {
          body.add(GeneratorView(generator: c, depth: depth + 1));
        }
      case 'scmProvider':
        final provider = g.keys.firstWhere((k) => !const {'cloneProtocol', 'filters', 'requeueAfterSeconds', 'template', 'values'}.contains(k), orElse: () => '?');
        final p = asMap(g[provider]);
        subtitle = provider;
        body.add(KeyValueTable([
          ('Owner', p['organization'] ?? p['group'] ?? p['owner'] ?? p['workspace'] ?? p['project']),
          if (p['api'] != null) ('API', '${p['api']}'),
          if (g['cloneProtocol'] != null) ('Clone', '${g['cloneProtocol']}'),
          if (asMapList(g['filters']).isNotEmpty) ('Filters', '${asMapList(g['filters']).length}'),
        ], keyWidth: 90));
      case 'pullRequest':
        final provider = g.keys.firstWhere((k) => !const {'filters', 'requeueAfterSeconds', 'template', 'continueOnRepoNotFoundError'}.contains(k), orElse: () => '?');
        final p = asMap(g[provider]);
        subtitle = provider;
        body.add(KeyValueTable([
          ('Repository', '${p['owner'] ?? p['project'] ?? ''}/${p['repo'] ?? p['repository'] ?? ''}'),
          if (p['labels'] != null) ('Labels', Chips([for (final l in p['labels'] as List) Chipish(text: '$l')])),
          if (g['requeueAfterSeconds'] != null) ('Requeue', '${g['requeueAfterSeconds']}s'),
        ], keyWidth: 90));
      default:
        body.add(JsonTree(g));
    }
    if (selector.isNotEmpty) {
      body.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [
          const Hint('Post-filter  '),
          Flexible(child: Chipish(text: selectorToString(selector))),
        ]),
      ));
    }
    if (g['template'] != null && asMap(g['template']).isNotEmpty) {
      body.add(const Padding(padding: EdgeInsets.only(top: 4), child: Hint('Overrides parts of the template')));
    }
    return Container(
      margin: EdgeInsets.only(bottom: 6, left: depth == 0 ? 0 : 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.of(context).separator),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text.rich(TextSpan(children: [
          TextSpan(text: _generatorTitles[key] ?? key, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          if (subtitle.isNotEmpty) TextSpan(text: '  ·  $subtitle', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ])),
        const SizedBox(height: 4),
        ...body,
      ]),
    );
  }
}

/// List generator elements as a small table (columns = union of keys).
class _ElementsTable extends StatelessWidget {
  final List<Json> elements;
  const _ElementsTable(this.elements);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (elements.isEmpty) return const Hint('No elements');
    final keys = <String>[];
    for (final e in elements) {
      for (final k in e.keys) {
        if (!keys.contains(k)) keys.add(k);
      }
    }
    String cell(dynamic v) => v == null ? '' : (v is String ? v : jsonEncode(v));
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600);
    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder(horizontalInside: BorderSide(color: AppColors.of(context).separator, width: 0.5)),
      children: [
        TableRow(children: [for (final k in keys) Padding(padding: const EdgeInsets.only(bottom: 3, right: 8), child: Text(k, style: head))]),
        for (final e in elements)
          TableRow(children: [
            for (final k in keys)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3).copyWith(right: 8),
                child: Text(cell(e[k]), maxLines: 2, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5)),
              ),
          ]),
      ],
    );
  }
}

class AppSetTemplateView extends StatelessWidget {
  final Json spec;
  const AppSetTemplateView({super.key, required this.spec});

  @override
  Widget build(BuildContext context) {
    final tmpl = asMap(spec['template']);
    final meta = asMap(tmpl['metadata']);
    final tspec = asMap(tmpl['spec']);
    final dest = asMap(tspec['destination']);
    final sources = appSources(tspec);
    final automated = asMap(dig(tspec, ['syncPolicy', 'automated']));
    final auto = autoSyncEnabled(tspec);
    final syncOptions = [for (final o in (dig<List>(tspec, ['syncPolicy', 'syncOptions']) ?? const [])) '$o'];
    final labels = asMap(meta['labels']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      KeyValueTable([
        ('Name', meta['name'] == null ? null : CopyChip('${meta['name']}')),
        if (meta['namespace'] != null) ('App namespace', '${meta['namespace']}'),
        ('Project', CopyChip('${tspec['project'] ?? 'default'}')),
        ('Destination', '${destinationCluster(dest)} / ${dest['namespace'] ?? '—'}'),
        (
          'Sync policy',
          Chips([
            FlagChip('Auto-sync', auto),
            if (auto) ...[FlagChip('Prune', automated['prune'] == true), FlagChip('Self-heal', automated['selfHeal'] == true)],
          ]),
        ),
        if (syncOptions.isNotEmpty) ('Sync options', Chips([for (final o in syncOptions) Chipish(text: o)])),
        if (labels.isNotEmpty) ('Labels', LabelChips(labels)),
      ], keyWidth: 100),
      const SizedBox(height: 6),
      for (var i = 0; i < sources.length; i++) SourceView(source: sources[i], index: sources.length > 1 ? i : null),
      if (spec['templatePatch'] != null) ...[
        const SizedBox(height: 6),
        const Hint('Template patch'),
        const SizedBox(height: 2),
        CodeBlock('${spec['templatePatch']}'.trimRight()),
      ],
    ]);
  }
}

class AppSetConditions extends StatelessWidget {
  final List<Json> conditions;
  const AppSetConditions(this.conditions, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (conditions.isEmpty) return const Hint('No conditions');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in conditions)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Row(children: [
                  Flexible(child: Text('${c['type']}', overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500))),
                  const SizedBox(width: 10),
                  StatusBadge('${c['status']}', dense: true, severity: appSetConditionSeverity(c)),
                  if (c['reason'] != null) ...[
                    const SizedBox(width: 8),
                    Flexible(child: Text('${c['reason']}', overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
                  ],
                ]),
              ),
              const SizedBox(width: 8),
              AgeText(c['lastTransitionTime'], suffix: ' ago'),
            ]),
            if ((c['message'] ?? '').toString().isNotEmpty)
              SelectableText('${c['message']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ]),
        ),
    ]);
  }
}

/// Applications owned by the set, fetched once per change of status.resources.
class GeneratedApps extends StatefulWidget {
  final PanelContext ctx;
  final String refreshKey;
  const GeneratedApps({super.key, required this.ctx, required this.refreshKey});

  @override
  State<GeneratedApps> createState() => _GeneratedAppsState();
}

class _GeneratedAppsState extends State<GeneratedApps> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(GeneratedApps old) {
    super.didUpdateWidget(old);
    if (old.refreshKey != widget.refreshKey) _future = _load();
  }

  Future<List<Json>> _load() async {
    final ctx = widget.ctx;
    final names = {for (final r in asMapList(ctx.status['resources'])) '${r['namespace'] ?? ctx.namespace}/${r['name']}'};
    final all = await ctx.api.items(applicationsRef);
    final owned = [
      for (final a in all)
        if (asMapList(dig(a, ['metadata', 'ownerReferences'])).any((o) => o['uid'] == ctx.uid) ||
            names.contains('${dig(a, ['metadata', 'namespace'])}/${dig(a, ['metadata', 'name'])}'))
          a,
    ];
    return owned..sort(compareAppsWorstFirst);
  }

  @override
  Widget build(BuildContext context) => KeptFuture<List<Json>>(
        future: _future,
        builder: (context, apps) {
          if (apps.isEmpty) return const Hint('No applications generated');
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final a in apps) AppRow(a)]);
        },
      );
}
