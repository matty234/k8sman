import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'argo_common.dart';
import 'sync_windows.dart';
import '../../ui/widgets/atoms.dart';

class AppProjectPanel extends ResourcePanel {
  const AppProjectPanel();

  @override
  Set<String> get kinds => const {'argoproj.io/AppProject'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final roles = asMapList(spec['roles']);
    final windows = asMapList(spec['syncWindows']);
    final dests = asMapList(spec['destinations']);
    final repos = [for (final r in (spec['sourceRepos'] as List? ?? const [])) '$r'];
    return [
      DetailSection(title: 'Summary', icon: Icons.folder_special_outlined, card: true, child: ProjectSummary(ctx: ctx)),
      DetailSection(
        title: 'Applications',
        icon: Icons.apps,
        child: ProjectApps(key: ValueKey('apps-${ctx.uid}'), ctx: ctx),
      ),
      DetailSection(
        title: 'Source repositories',
        icon: Icons.source_outlined,
        trailing: Text('${repos.length}'),
        child: _SourceRepos(spec: spec),
      ),
      DetailSection(title: 'Destinations', icon: Icons.place_outlined, trailing: Text('${dests.length}'), child: DestinationsTable(dests)),
      DetailSection(title: 'Allowed resource kinds', icon: Icons.category_outlined, child: ResourceKindRules(spec: spec)),
      DetailSection(
        title: 'Sync windows',
        icon: Icons.schedule,
        trailing: Text('${windows.length}'),
        initiallyExpanded: windows.isNotEmpty,
        child: SyncWindowsView(windows),
      ),
      DetailSection(
        title: 'Roles',
        icon: Icons.badge_outlined,
        trailing: Text('${roles.length}'),
        initiallyExpanded: roles.isNotEmpty,
        child: RolesView(roles),
      ),
      DetailSection(title: 'Orphaned resources', icon: Icons.help_center_outlined, child: _Orphaned(asMap(spec['orphanedResources']))),
    ];
  }
}

bool _isWildcard(String s) => s == '*';

class ProjectSummary extends StatelessWidget {
  final PanelContext ctx;
  const ProjectSummary({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final spec = ctx.spec;
    final repos = [for (final r in (spec['sourceRepos'] as List? ?? const [])) '$r'];
    final dests = asMapList(spec['destinations']);
    final windows = asMapList(spec['syncWindows']);
    final active = windows.where((w) => windowState(w) == WindowState.active).toList();
    final unknown = windows.any((w) => windowState(w) == WindowState.unknown);
    final blockedNow = active.any((w) => w['kind'] == 'deny') ||
        (!unknown && windows.any((w) => w['kind'] == 'allow') && !active.any((w) => w['kind'] == 'allow'));
    final openSources = repos.any(_isWildcard);
    final openDests = dests.any((d) => _isWildcard('${d['server'] ?? d['name'] ?? ''}') && _isWildcard('${d['namespace'] ?? ''}'));
    final clusterAllow = asMapList(spec['clusterResourceWhitelist']);
    final anyClusterKind = clusterAllow.any((r) => r['group'] == '*' && r['kind'] == '*');
    final unrestricted = openSources && openDests && anyClusterKind;
    final desc = spec['description'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (desc != null && desc.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(desc, style: Theme.of(context).textTheme.bodySmall)),
      Wrap(spacing: 8, runSpacing: 6, children: [
        unrestricted
            ? ArgoBadge(ArgoStyle(Icons.lock_open, severityColor(context, Severity.warn), Severity.warn), 'Unrestricted', large: true,
                tooltip: 'Any repo, any destination, any kind (like the default project)')
            : ArgoBadge(ArgoStyle(Icons.lock_outline, severityColor(context, Severity.ok), Severity.ok), 'Restricted', large: true),
        if (windows.isNotEmpty)
          blockedNow
              ? ArgoBadge(ArgoStyle(Icons.block, severityColor(context, Severity.error), Severity.error), 'Sync window blocking', large: true,
                  tooltip: 'A deny window is active (or no allow window is open) for matching apps')
              : unknown
                  ? ArgoBadge(ArgoStyle(Icons.schedule, Theme.of(context).hintColor, Severity.neutral), 'Sync windows: partly unknown', large: true,
                      tooltip: 'Windows in a non-UTC time zone can\'t be evaluated here')
                  : ArgoBadge(ArgoStyle(Icons.schedule, severityColor(context, Severity.ok), Severity.ok), 'Syncs allowed now', large: true),
      ]),
      const SizedBox(height: 8),
      KeyValueTable([
        ('Sources', openSources ? 'any repository' : '${repos.length} repositor${repos.length == 1 ? 'y' : 'ies'}'),
        ('Destinations', openDests ? 'any cluster and namespace' : '${dests.length} rule${dests.length == 1 ? '' : 's'}'),
        ('Roles', '${asMapList(spec['roles']).length}'),
        ('Sync windows', windows.isEmpty ? 'none' : '${windows.length} (${active.length} active now)'),
        if (spec['permitOnlyProjectScopedClusters'] == true) ('Clusters', 'project-scoped clusters only'),
        if ((spec['sourceNamespaces'] as List?)?.isNotEmpty == true)
          ('App namespaces', InlineWrap([for (final n in spec['sourceNamespaces'] as List) Chipish(text: '$n')])),
      ], keyWidth: 110),
    ]);
  }
}

class _SourceRepos extends StatelessWidget {
  final Json spec;
  const _SourceRepos({required this.spec});

  @override
  Widget build(BuildContext context) {
    final repos = [for (final r in (spec['sourceRepos'] as List? ?? const [])) '$r'];
    final keys = asMapList(spec['signatureKeys']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (repos.isEmpty) const HintText('None: no application can deploy from this project'),
      for (final r in repos)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Icon(r.startsWith('!') ? Icons.block : Icons.check, size: 13, color: severityColor(context, r.startsWith('!') ? Severity.error : Severity.ok)),
            const SizedBox(width: 6),
            Flexible(child: r == '*' ? const Text('* (any repository)') : CopyChip(r)),
          ]),
        ),
      if (keys.isNotEmpty) ...[
        const SizedBox(height: 4),
        Row(children: [
          const HintText('Commits must be signed by  '),
          Flexible(child: InlineWrap([for (final k in keys) Chipish(text: '${k['keyID']}')])),
        ]),
      ],
    ]);
  }
}

/// Destinations as a server/name → namespace table. `!` negates.
class DestinationsTable extends StatelessWidget {
  final List<Json> dests;
  const DestinationsTable(this.dests, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (dests.isEmpty) return const HintText('None: no application can deploy from this project');
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600);
    return Table(
      columnWidths: const {0: FixedColumnWidth(22), 1: FlexColumnWidth(3), 2: FlexColumnWidth(2)},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(children: [const SizedBox(), Text('Cluster', style: head), Text('Namespace', style: head)]),
        for (final d in dests)
          () {
            final cluster = destinationCluster(d);
            final ns = '${d['namespace'] ?? '*'}';
            final deny = cluster.startsWith('!') || ns.startsWith('!');
            return TableRow(children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Icon(deny ? Icons.block : Icons.check, size: 13, color: severityColor(context, deny ? Severity.error : Severity.ok)),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: '${d['server'] ?? d['name'] ?? '*'}',
                  child: Text(cluster == '*' ? '* (any)' : cluster, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5)),
                ),
              ),
              Text(ns == '*' ? '* (any)' : ns, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5)),
            ]);
          }(),
      ],
    );
  }
}

String _gk(Json r) {
  final g = '${r['group'] ?? ''}';
  final k = '${r['kind'] ?? '*'}';
  if (g == '*' && k == '*') return 'everything';
  return g.isEmpty ? k : '$k.$g';
}

/// Cluster/namespace resource allow and deny lists, with Argo's defaults
/// spelled out (no cluster-scoped allow list = none allowed).
class ResourceKindRules extends StatelessWidget {
  final Json spec;
  const ResourceKindRules({super.key, required this.spec});

  @override
  Widget build(BuildContext context) {
    final cAllow = asMapList(spec['clusterResourceWhitelist']);
    final cDeny = asMapList(spec['clusterResourceBlacklist']);
    final nAllow = asMapList(spec['namespaceResourceWhitelist']);
    final nDeny = asMapList(spec['namespaceResourceBlacklist']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _RuleBlock(
        title: 'Cluster-scoped',
        allow: cAllow,
        deny: cDeny,
        emptyAllow: 'none (no cluster-scoped resources allowed)',
      ),
      const SizedBox(height: 8),
      _RuleBlock(
        title: 'Namespaced',
        allow: nAllow,
        deny: nDeny,
        emptyAllow: 'all kinds',
      ),
    ]);
  }
}

class _RuleBlock extends StatelessWidget {
  final String title;
  final List<Json> allow;
  final List<Json> deny;
  final String emptyAllow;
  const _RuleBlock({required this.title, required this.allow, required this.deny, required this.emptyAllow});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget list(List<Json> rules, bool isDeny) => InlineWrap([
          for (final r in rules)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: severityColor(context, isDeny ? Severity.error : Severity.ok).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(_gk(r), style: monoStyle(context, size: 11.5)),
            ),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
      const SizedBox(height: 3),
      KeyValueTable([
        ('Allow', allow.isEmpty ? HintText(emptyAllow) : list(allow, false)),
        ('Deny', deny.isEmpty ? const HintText('nothing') : list(deny, true)),
      ], keyWidth: 60),
    ]);
  }
}

class SyncWindowsView extends StatelessWidget {
  final List<Json> windows;
  const SyncWindowsView(this.windows, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (windows.isEmpty) return const HintText('No sync windows: syncs are allowed at any time');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final w in windows)
        () {
          final deny = w['kind'] == 'deny';
          final state = windowState(w);
          final scope = [
            if ((w['applications'] as List?)?.isNotEmpty == true) 'apps ${(w['applications'] as List).join(', ')}',
            if ((w['namespaces'] as List?)?.isNotEmpty == true) 'namespaces ${(w['namespaces'] as List).join(', ')}',
            if ((w['clusters'] as List?)?.isNotEmpty == true) 'clusters ${(w['clusters'] as List).join(', ')}',
          ];
          final stateBadge = switch (state) {
            WindowState.active => StatusBadge('active now', severity: deny ? Severity.error : Severity.ok),
            WindowState.inactive => const StatusBadge('inactive', severity: Severity.neutral),
            WindowState.unknown => Tooltip(
                message: (w['timeZone'] ?? '') != '' ? 'Can\'t evaluate the ${w['timeZone']} time zone here' : 'Unrecognised schedule',
                child: const StatusBadge('active: ?', severity: Severity.neutral),
              ),
          };
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            decoration: BoxDecoration(
              border: Border.all(color: state == WindowState.active ? severityColor(context, deny ? Severity.error : Severity.ok).withValues(alpha: 0.5) : AppColors.of(context).separator),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                StatusBadge(deny ? 'deny' : 'allow', severity: deny ? Severity.error : Severity.ok),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${w['schedule']}  for ${w['duration']}${(w['timeZone'] ?? '') != '' ? '  (${w['timeZone']})' : '  (UTC)'}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5)),
                ),
                const SizedBox(width: 6),
                stateBadge,
              ]),
              const SizedBox(height: 3),
              Text(
                [
                  scope.isEmpty ? 'matches no applications' : scope.join(' · '),
                  if (w['manualSync'] == true) 'manual syncs allowed',
                  if (w['andOperator'] == true) 'all selectors must match',
                ].join('  ·  '),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
              if ((w['description'] ?? '').toString().isNotEmpty) Text('${w['description']}', style: theme.textTheme.bodySmall),
            ]),
          );
        }(),
    ]);
  }
}

/// `p, proj:x:ci, applications, sync, x/*, allow` → its parts.
List<String> parsePolicy(String line) => line.split(',').map((s) => s.trim()).toList();

class RolesView extends StatelessWidget {
  final List<Json> roles;
  const RolesView(this.roles, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (roles.isEmpty) return const HintText('No project roles');
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in roles)
        () {
          final policies = [for (final p in (r['policies'] as List? ?? const [])) parsePolicy('$p')];
          final groups = [for (final g in (r['groups'] as List? ?? const [])) '$g'];
          final tokens = asMapList(r['jwtTokens']);
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            decoration: BoxDecoration(border: Border.all(color: AppColors.of(context).separator), borderRadius: BorderRadius.circular(6)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: '${r['name']}', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                if ((r['description'] ?? '').toString().isNotEmpty)
                  TextSpan(text: '  ·  ${r['description']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              ])),
              if (groups.isNotEmpty || tokens.isNotEmpty) ...[
                const SizedBox(height: 3),
                InlineWrap([
                  for (final g in groups) Chipish(text: 'group $g'),
                  if (tokens.isNotEmpty) Chipish(text: '${tokens.length} token${tokens.length == 1 ? '' : 's'}'),
                ]),
              ],
              if (policies.isNotEmpty) ...[
                const SizedBox(height: 4),
                Table(
                  columnWidths: const {0: FlexColumnWidth(2.2), 1: FlexColumnWidth(1.4), 2: FlexColumnWidth(2.4), 3: FixedColumnWidth(48)},
                  children: [
                    TableRow(children: [Text('Resource', style: head), Text('Action', style: head), Text('Object', style: head), Text('Effect', style: head)]),
                    for (final p in policies)
                      TableRow(children: [
                        for (final i in [2, 3, 4])
                          Padding(
                            padding: const EdgeInsets.only(top: 2, right: 6),
                            child: Text(p.length > i ? p[i] : '', maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11)),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(p.length > 5 ? p[5] : '',
                              style: monoStyle(context, size: 11, color: severityColor(context, p.length > 5 && p[5] == 'deny' ? Severity.error : Severity.ok))),
                        ),
                      ]),
                  ],
                ),
              ],
            ]),
          );
        }(),
    ]);
  }
}

class _Orphaned extends StatelessWidget {
  final Json orphaned;
  const _Orphaned(this.orphaned);

  @override
  Widget build(BuildContext context) {
    if (orphaned.isEmpty) return const HintText('Not monitored');
    final ignore = asMapList(orphaned['ignore']);
    return KeyValueTable([
      ('Monitoring', orphaned['warn'] == true ? 'on, apps get an OrphanedResourceWarning' : 'on (no warning condition)'),
      (
        'Ignored',
        ignore.isEmpty
            ? const HintText('nothing')
            : InlineWrap([for (final i in ignore) Chipish(text: '${_gk({'group': i['group'] ?? '', 'kind': i['kind'] ?? '*'})}${i['name'] != null ? ' ${i['name']}' : ''}')]),
      ),
    ], keyWidth: 100);
  }
}

/// Applications whose spec.project is this project (all namespaces).
class ProjectApps extends StatefulWidget {
  final PanelContext ctx;
  const ProjectApps({super.key, required this.ctx});

  @override
  State<ProjectApps> createState() => _ProjectAppsState();
}

class _ProjectAppsState extends State<ProjectApps> {
  late final Future<List<Json>> _future = _load();

  Future<List<Json>> _load() async {
    final all = await widget.ctx.api.items(applicationsRef);
    return [for (final a in all) if ((dig<String>(a, ['spec', 'project']) ?? 'default') == widget.ctx.name) a]..sort(compareAppsWorstFirst);
  }

  @override
  Widget build(BuildContext context) => KeepingAsync<List<Json>>(
        future: _future,
        builder: (context, apps) {
          if (apps.isEmpty) return const HintText('No applications use this project');
          final synced = apps.where((a) => dig(a, ['status', 'sync', 'status']) == 'Synced').length;
          final healthy = apps.where((a) => dig(a, ['status', 'health', 'status']) == 'Healthy').length;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            HintText('${apps.length} apps · $synced synced · $healthy healthy'),
            const SizedBox(height: 4),
            for (final a in apps) AppRow(a),
          ]);
        },
      );
}
