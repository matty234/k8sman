import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../actions/actions.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'app_actions.dart';
import 'app_resources.dart';
import 'argo_common.dart';
import '../../ui/inspector/inspector.dart' show Callout;
import '../../ui/widgets/atoms.dart';

class ApplicationPanel extends ResourcePanel {
  const ApplicationPanel();

  @override
  Set<String> get kinds => const {'argoproj.io/Application'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => ctx.app.readOnly ? const [] : argoAppActions(ctx);

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final st = ctx.status;
    final op = asMap(st['operationState']);
    final sources = appSources(ctx.spec);
    final history = asMapList(st['history']);
    final resources = asMapList(st['resources']);
    final outOfSync = resources.where((r) => r['status'] != 'Synced').length;
    final refreshKey = [
      st['reconciledAt'],
      dig(st, ['health', 'status']),
      op['phase'],
      for (final r in resources) '${r['kind']}/${r['namespace']}/${r['name']}=${r['status']}',
    ].join('|');
    return [
      DetailSection(title: 'Status', icon: Icons.monitor_heart_outlined, card: true, child: AppStatusSummary(ctx: ctx)),
      if (op.isNotEmpty)
        DetailSection(
          title: 'Last operation',
          icon: Icons.sync,
          trailing: ArgoBadge.phase(context, op['phase'] as String?),
          child: OperationView(ctx: ctx, op: op),
        ),
      DetailSection(
        title: sources.length > 1 ? 'Sources (${sources.length})' : 'Source',
        icon: Icons.source_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (sources.isEmpty) const HintText('No source'),
          for (var i = 0; i < sources.length; i++)
            SourceView(
              source: sources[i],
              index: sources.length > 1 ? i : null,
              type: sources.length > 1 ? dig<String>(st, ['sourceTypes', i]) : st['sourceType'] as String?,
              revision: sources.length > 1 ? dig<String>(st, ['sync', 'revisions', i]) : dig<String>(st, ['sync', 'revision']),
            ),
        ]),
      ),
      DetailSection(title: 'Destination', icon: Icons.place_outlined, child: DestinationView(ctx: ctx)),
      DetailSection(
        title: 'Managed resources',
        icon: Icons.inventory_2_outlined,
        trailing: Text(outOfSync > 0 ? '$outOfSync of ${resources.length} out of sync' : '${resources.length}'),
        child: ManagedResourcesView(key: ValueKey('res-${ctx.uid}'), ctx: ctx, refreshKey: refreshKey),
      ),
      DetailSection(
        title: 'Sync history',
        icon: Icons.history,
        trailing: Text('${history.length}'),
        initiallyExpanded: history.isNotEmpty,
        child: SyncHistoryView(history: history),
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Status summary
// ---------------------------------------------------------------------------

class AppStatusSummary extends StatelessWidget {
  final PanelContext ctx;
  const AppStatusSummary({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final st = ctx.status;
    final spec = ctx.spec;
    final sync = dig<String>(st, ['sync', 'status']);
    final health = dig<String>(st, ['health', 'status']);
    final healthMsg = dig<String>(st, ['health', 'message']);
    final conds = asMapList(st['conditions']);
    final op = asMap(st['operationState']);
    final running = operationRunning(ctx.object);
    final sources = appSources(spec);
    final multi = sources.length > 1;
    final auto = autoSyncEnabled(spec);
    final automated = asMap(dig(spec, ['syncPolicy', 'automated']));
    final syncOptions = [for (final o in (dig<List>(spec, ['syncPolicy', 'syncOptions']) ?? const [])) '$o'];
    final retry = asMap(dig(spec, ['syncPolicy', 'retry']));
    final images = [for (final i in (dig<List>(st, ['summary', 'images']) ?? const [])) '$i'];
    final urls = [for (final i in (dig<List>(st, ['summary', 'externalURLs']) ?? const [])) '$i'];
    final readOnly = ctx.app.readOnly;

    final pills = Wrap(spacing: 8, runSpacing: 6, children: [
      ArgoBadge.sync(context, sync, large: true, tooltip: 'Sync status'),
      ArgoBadge.health(context, health, large: true, tooltip: 'Health status'),
      if (running) ArgoBadge.phase(context, 'Running', large: true),
    ]);
    final buttons = readOnly
        ? null
        : Wrap(spacing: 6, runSpacing: 6, children: [
            _SmallButton(icon: Icons.sync, label: 'Sync', filled: true, onPressed: () => showArgoSyncDialog(context, ctx)),
            _RefreshButton(ctx: ctx),
          ]);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, box) {
        if (buttons == null) return pills;
        if (box.maxWidth >= 380) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: pills), const SizedBox(width: 8), buttons]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [pills, const SizedBox(height: 8), buttons]);
      }),
      const SizedBox(height: 10),
      for (final c in conds)
        Callout(
          severity: argoConditionSeverity('${c['type']}'),
          icon: argoConditionSeverity('${c['type']}') == Severity.error ? Icons.error_outline : Icons.warning_amber_rounded,
          title: '${c['type']}',
          body: '${c['message'] ?? ''}',
        ),
      if (healthMsg != null && healthMsg.isNotEmpty && health != 'Healthy')
        Callout(severity: healthStyle(context, health).severity, icon: healthStyle(context, health).icon, title: healthMsg),
      if (running)
        Callout(
          severity: Severity.info,
          icon: Icons.sync,
          title: 'Sync running${parseTime(op['startedAt']) != null ? ' for ${elapsed(op['startedAt'], null)}' : ''}',
          body: '${op['message'] ?? 'Waiting for the application controller…'}',
          action: readOnly ? null : _SmallButton(icon: Icons.stop_circle_outlined, label: 'Terminate', onPressed: () => argoTerminate(context, ctx)),
        ),
      KeyValueTable([
        (
          multi ? 'Revisions' : 'Revision',
          _Revisions(
            revisions: multi
                ? [for (final r in (dig<List>(st, ['sync', 'revisions']) ?? const [])) '$r']
                : [if (dig<String>(st, ['sync', 'revision']) != null) dig<String>(st, ['sync', 'revision'])!],
            targets: [for (final s in sources) if (s['ref'] == null || !multi) '${s['targetRevision'] ?? 'HEAD'}' else '${s['targetRevision'] ?? 'HEAD'} (ref ${s['ref']})'],
          ),
        ),
        (
          'Sync policy',
          InlineWrap([
            FlagChip('Auto-sync', auto),
            if (auto) ...[
              FlagChip('Prune', automated['prune'] == true, tooltip: 'Delete resources removed from git automatically'),
              FlagChip('Self-heal', automated['selfHeal'] == true, tooltip: 'Revert changes made in the cluster'),
              if (automated['allowEmpty'] == true) const FlagChip('Allow empty', true),
            ],
          ]),
        ),
        if (syncOptions.isNotEmpty) ('Sync options', InlineWrap([for (final o in syncOptions) Chipish(text: o)])),
        if (retry.isNotEmpty)
          (
            'Retry',
            'up to ${retry['limit'] ?? 'unlimited'} retries'
                '${asMap(retry['backoff']).isEmpty ? '' : ', backoff ${dig(retry, ['backoff', 'duration']) ?? '5s'} ×${dig(retry, ['backoff', 'factor']) ?? 2} up to ${dig(retry, ['backoff', 'maxDuration']) ?? '3m'}'}',
          ),
        (
          'Last sync',
          op.isEmpty
              ? null
              : Row(children: [
                  ArgoBadge.phase(context, op['phase'] as String?),
                  const SizedBox(width: 8),
                  Flexible(child: AgeText(op['finishedAt'] ?? op['startedAt'], suffix: ' ago')),
                ]),
        ),
        ('Compared', st['reconciledAt'] == null ? null : AgeText(st['reconciledAt'], suffix: ' ago', style: theme.textTheme.bodySmall)),
        if (images.isNotEmpty) ('Images', InlineWrap([for (final i in images) CopyChip(i)])),
        if (urls.isNotEmpty) ('URLs', InlineWrap([for (final u in urls) _UrlChip(u)])),
      ], keyWidth: 100),
      ArgoUiLink(key: ValueKey('ui-${ctx.uid}'), ctx: ctx),
    ]);
  }
}

class _Revisions extends StatelessWidget {
  final List<String> revisions;
  final List<String> targets;
  const _Revisions({required this.revisions, required this.targets});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = revisions.length > targets.length ? revisions.length : targets.length;
    if (n == 0) return const HintText('—');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < n; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (i < revisions.length && revisions[i].isNotEmpty)
              CopyChip(shortRevision(revisions[i]), copy: revisions[i], tooltip: 'Copy ${revisions[i]}')
            else
              const HintText('not compared'),
            if (i < targets.length) Text('target ${targets[i]}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ]),
        ),
    ]);
  }
}

class _SmallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onPressed;
  const _SmallButton({required this.icon, required this.label, required this.onPressed, this.filled = false});

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      iconSize: const WidgetStatePropertyAll(15),
    );
    return filled
        ? FilledButton.tonalIcon(style: style, onPressed: onPressed, icon: Icon(icon), label: Text(label))
        : OutlinedButton.icon(style: style, onPressed: onPressed, icon: Icon(icon), label: Text(label));
  }
}

/// Refresh with a menu for Hard refresh.
class _RefreshButton extends StatelessWidget {
  final PanelContext ctx;
  const _RefreshButton({required this.ctx});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _SmallButton(icon: Icons.refresh, label: 'Refresh', onPressed: () => argoRefresh(context, ctx)),
      PopupMenuButton<bool>(
            popUpAnimationStyle: AnimationStyle.noAnimation,
        tooltip: 'More refresh options',
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: const Icon(Icons.arrow_drop_down),
        onSelected: (hard) => argoRefresh(context, ctx, hard: hard),
        itemBuilder: (_) => const [
          PopupMenuItem(value: false, child: Text('Refresh')),
          PopupMenuItem(value: true, child: Text('Hard refresh (regenerate manifests)')),
        ],
      ),
    ]);
  }
}

class _UrlChip extends StatelessWidget {
  final String url;
  const _UrlChip(this.url);
  @override
  Widget build(BuildContext context) => Hoverable(
        onTap: () => launchUrl(Uri.parse(url)),
        builder: (h) => Text(url,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary, decoration: h ? TextDecoration.underline : null)),
      );
}

/// "Open in Argo CD" when argocd-cm has a `url` (fetched once).
class ArgoUiLink extends StatefulWidget {
  final PanelContext ctx;
  const ArgoUiLink({super.key, required this.ctx});

  @override
  State<ArgoUiLink> createState() => _ArgoUiLinkState();
}

class _ArgoUiLinkState extends State<ArgoUiLink> {
  late final Future<String?> _url = _load();

  Future<String?> _load() async {
    final ns = widget.ctx.status['controllerNamespace'] as String? ?? widget.ctx.namespace ?? 'argocd';
    try {
      final cm = await widget.ctx.api.object(const ResourceRef(resource: 'configmaps'), namespace: ns, name: 'argocd-cm');
      final url = dig<String>(cm, ['data', 'url']);
      return url == null || url.isEmpty ? null : url.replaceFirst(RegExp(r'/+$'), '');
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: _url,
        builder: (context, snap) {
          final base = snap.data;
          if (base == null) return const SizedBox.shrink();
          final link = '$base/applications/${widget.ctx.namespace ?? 'argocd'}/${widget.ctx.name}';
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                onPressed: () => launchUrl(Uri.parse(link)),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('Open in Argo CD'),
              ),
            ),
          );
        },
      );
}

// ---------------------------------------------------------------------------
// Last operation
// ---------------------------------------------------------------------------

/// syncResult resources that did not apply cleanly.
List<Json> failedSyncResources(Json op) => [
      for (final r in asMapList(dig(op, ['syncResult', 'resources'])))
        if (r['status'] == 'SyncFailed' || r['hookPhase'] == 'Failed' || r['hookPhase'] == 'Error') r,
    ];

String initiatorOf(Json initiatedBy) {
  if (initiatedBy['automated'] == true) return 'automated (auto-sync)';
  final user = initiatedBy['username'] as String?;
  return user == null || user.isEmpty ? 'unknown' : user;
}

class OperationView extends StatelessWidget {
  final PanelContext ctx;
  final Json op;
  const OperationView({super.key, required this.ctx, required this.op});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = op['phase'] as String?;
    final operation = asMap(op['operation']);
    final sync = asMap(operation['sync']);
    final failed = failedSyncResources(op);
    final total = asMapList(dig(op, ['syncResult', 'resources'])).length;
    final rev = (dig<String>(op, ['syncResult', 'revision']) ?? sync['revision']) as String?;
    final revs = [for (final r in (dig<List>(op, ['syncResult', 'revisions']) ?? sync['revisions'] as List? ?? const [])) '$r'];
    final bad = phase == 'Failed' || phase == 'Error';
    final flags = [
      if (sync['prune'] == true) 'prune',
      if (sync['dryRun'] == true) 'dry run',
      for (final o in (sync['syncOptions'] as List? ?? const [])) '$o',
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if ((op['message'] ?? '').toString().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text('${op['message']}',
              style: theme.textTheme.bodySmall?.copyWith(color: bad ? severityColor(context, Severity.error) : null)),
        ),
      KeyValueTable([
        ('Initiated by', initiatorOf(asMap(operation['initiatedBy']))),
        ('Started', op['startedAt'] == null ? null : AgeText(op['startedAt'], suffix: ' ago', style: theme.textTheme.bodySmall)),
        (
          'Finished',
          op['finishedAt'] == null
              ? (phase == 'Running' ? 'running for ${elapsed(op['startedAt'], null) ?? '?'}' : null)
              : Row(children: [
                  AgeText(op['finishedAt'], suffix: ' ago', style: theme.textTheme.bodySmall),
                  Text('  ·  took ${elapsed(op['startedAt'], op['finishedAt']) ?? '?'}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                ]),
        ),
        (
          'Revision',
          revs.isNotEmpty
              ? InlineWrap([for (final r in revs) CopyChip(shortRevision(r), copy: r)])
              : (rev == null || rev.isEmpty ? null : InlineWrap([CopyChip(shortRevision(rev), copy: rev)])),
        ),
        if (flags.isNotEmpty) ('Options', InlineWrap([for (final f in flags) Chipish(text: f)])),
        if ((op['retryCount'] ?? 0) != 0) ('Retries', '${op['retryCount']}'),
        if (total > 0) ('Resources', '$total applied${failed.isEmpty ? '' : ', ${failed.length} failed'}'),
      ], keyWidth: 100),
      if (failed.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text('Failed resources', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        for (final r in failed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.cancel, size: 13, color: severityColor(context, Severity.error)),
                const SizedBox(width: 6),
                Text('${r['kind']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                const SizedBox(width: 6),
                Expanded(
                  child: OneLineRef(ObjectRef(
                    group: '${r['group'] ?? ''}',
                    kind: '${r['kind']}',
                    name: '${r['name']}',
                    namespace: (r['namespace'] as String?)?.isEmpty == true ? null : r['namespace'] as String?,
                  )),
                ),
              ]),
              if ((r['message'] ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 19),
                  child: Text('${r['message']}', style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.error))),
                ),
            ]),
          ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Source(s)
// ---------------------------------------------------------------------------

class SourceView extends StatelessWidget {
  final Json source;
  final int? index;
  final String? type;
  final String? revision;
  const SourceView({super.key, required this.source, this.index, this.type, this.revision});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final helm = asMap(source['helm']);
    final kustomize = asMap(source['kustomize']);
    final directory = asMap(source['directory']);
    final plugin = asMap(source['plugin']);
    final repo = '${source['repoURL'] ?? ''}';
    final chart = source['chart'] as String?;
    final rows = <(String, Object?)>[
      ('Repository', repo.isEmpty ? null : CopyChip(repo, tooltip: 'Copy $repo')),
      if (chart != null) ('Chart', CopyChip(chart)) else ('Path', source['path'] == null ? null : CopyChip('${source['path']}')),
      ('Target', '${source['targetRevision'] ?? 'HEAD'}'),
      if (revision != null && revision!.isNotEmpty && revision != source['targetRevision']) ('Resolved to', CopyChip(shortRevision(revision), copy: revision)),
      if (source['ref'] != null) ('Ref', Text('\$${source['ref']}  (referenced by other sources)', style: monoStyle(context, size: 11.5))),
      if (source['name'] != null) ('Name', '${source['name']}'),
      if (type != null && type!.isNotEmpty) ('Type', type),
    ];
    if (helm.isNotEmpty) rows.addAll(_helmRows(context, helm));
    if (kustomize.isNotEmpty) rows.addAll(_kustomizeRows(context, kustomize));
    if (directory.isNotEmpty) {
      rows.addAll([
        if (directory['recurse'] == true) ('Recurse', 'yes'),
        if (directory['include'] != null) ('Include', CopyChip('${directory['include']}')),
        if (directory['exclude'] != null) ('Exclude', CopyChip('${directory['exclude']}')),
        if (asMap(directory['jsonnet']).isNotEmpty) ('Jsonnet', CodeBlock(const JsonEncoder.withIndent('  ').convert(directory['jsonnet']))),
      ]);
    }
    if (plugin.isNotEmpty) {
      rows.addAll([
        ('Plugin', '${plugin['name'] ?? '(discovered)'}'),
        for (final e in asMapList(plugin['env'])) ('  env ${e['name']}', '${e['value']}'),
      ]);
    }

    final body = KeyValueTable(rows, keyWidth: 100);
    if (index == null) return body;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.of(context).separator),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Source ${index! + 1}${source['ref'] != null ? ' · values ref' : ''}',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        body,
      ]),
    );
  }

  List<(String, Object?)> _helmRows(BuildContext context, Json helm) {
    final params = asMapList(helm['parameters']);
    final fileParams = asMapList(helm['fileParameters']);
    final valueFiles = [for (final v in (helm['valueFiles'] as List? ?? const [])) '$v'];
    final values = helm['values'] is String && (helm['values'] as String).trim().isNotEmpty
        ? (helm['values'] as String).trimRight()
        : (helm['valuesObject'] != null ? const JsonEncoder.withIndent('  ').convert(helm['valuesObject']) : null);
    return [
      if (helm['releaseName'] != null) ('Release', '${helm['releaseName']}'),
      if (helm['version'] != null) ('Helm', '${helm['version']}'),
      if (valueFiles.isNotEmpty) ('Value files', InlineWrap([for (final v in valueFiles) CopyChip(v)])),
      if (params.isNotEmpty) ('Parameters', _ParamTable([for (final p in params) ('${p['name']}', '${p['value'] ?? ''}', p['forceString'] == true)])),
      if (fileParams.isNotEmpty) ('File params', _ParamTable([for (final p in fileParams) ('${p['name']}', '${p['path'] ?? ''}', false)])),
      if (values != null) ('Values', CodeBlock(values)),
      if (helm['skipCrds'] == true) ('Skip CRDs', 'yes'),
      if (helm['passCredentials'] == true) ('Pass creds', 'yes'),
    ];
  }

  List<(String, Object?)> _kustomizeRows(BuildContext context, Json k) {
    final images = [for (final i in (k['images'] as List? ?? const [])) '$i'];
    final patches = asMapList(k['patches']);
    final labels = asMap(k['commonLabels']);
    final annotations = asMap(k['commonAnnotations']);
    final replicas = asMapList(k['replicas']);
    return [
      if (images.isNotEmpty) ('Images', InlineWrap([for (final i in images) CopyChip(i)])),
      if (k['namePrefix'] != null) ('Name prefix', CopyChip('${k['namePrefix']}')),
      if (k['nameSuffix'] != null) ('Name suffix', CopyChip('${k['nameSuffix']}')),
      if (k['namespace'] != null) ('Namespace', '${k['namespace']}'),
      if (labels.isNotEmpty) ('Labels', LabelChips(labels)),
      if (annotations.isNotEmpty) ('Annotations', LabelChips(annotations)),
      if (replicas.isNotEmpty) ('Replicas', InlineWrap([for (final r in replicas) Chipish(text: '${r['name']}=${r['count']}')])),
      if (k['version'] != null) ('Kustomize', '${k['version']}'),
      if (patches.isNotEmpty)
        (
          'Patches',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final p in patches)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: CodeBlock(
                  [
                    if (asMap(p['target']).isNotEmpty) '# target: ${asMap(p['target']).entries.map((e) => '${e.key}=${e.value}').join(', ')}',
                    if (p['path'] != null) '# file: ${p['path']}',
                    if (p['patch'] != null) '${p['patch']}'.trimRight(),
                  ].join('\n'),
                ),
              ),
          ]),
        ),
    ];
  }
}

class _ParamTable extends StatelessWidget {
  final List<(String, String, bool)> rows;
  const _ParamTable(this.rows);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (k, v, force) in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: k, style: monoStyle(context, size: 11.5, color: theme.hintColor)),
              TextSpan(text: ' = ', style: monoStyle(context, size: 11.5, color: theme.hintColor)),
              TextSpan(text: v, style: monoStyle(context, size: 11.5)),
              if (force) TextSpan(text: '  (string)', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Destination
// ---------------------------------------------------------------------------

class DestinationView extends StatelessWidget {
  final PanelContext ctx;
  const DestinationView({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final dest = asMap(ctx.spec['destination']);
    final ns = dest['namespace'] as String?;
    final cluster = destinationCluster(dest);
    final local = cluster == 'in-cluster';
    final project = '${ctx.spec['project'] ?? 'default'}';
    final projectNs = ctx.status['controllerNamespace'] as String? ?? ctx.namespace;
    final ignore = asMapList(ctx.spec['ignoreDifferences']);
    final managedNs = asMap(dig(ctx.spec, ['syncPolicy', 'managedNamespaceMetadata']));
    return KeyValueTable([
      (
        'Cluster',
        local
            ? Text('in-cluster  (${dest['server'] ?? dest['name']})', style: Theme.of(context).textTheme.bodySmall)
            : CopyChip('${dest['name'] ?? dest['server']}', mono: dest['name'] == null),
      ),
      (
        'Namespace',
        ns == null || ns.isEmpty
            ? const HintText('— (from the manifests)')
            : (local ? ResourceLink(ObjectRef(kind: 'Namespace', name: ns), label: ns) : Text(ns, style: Theme.of(context).textTheme.bodySmall)),
      ),
      ('Project', ResourceLink(ObjectRef(group: argoGroup, kind: 'AppProject', name: project, namespace: projectNs), label: project)),
      if (managedNs.isNotEmpty) ('Namespace metadata', LabelChips({...asMap(managedNs['labels']), ...asMap(managedNs['annotations'])})),
      if (ignore.isNotEmpty)
        (
          'Ignored diffs',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final i in ignore)
              Text(
                '${i['group'] == null || i['group'] == '' ? '' : '${i['group']}/'}${i['kind']}${i['name'] != null ? ' ${i['name']}' : ''}: '
                '${[...(i['jsonPointers'] as List? ?? const []), ...(i['jqPathExpressions'] as List? ?? const []), ...(i['managedFieldsManagers'] as List? ?? const [])].join(', ')}',
                style: monoStyle(context, size: 11),
              ),
          ]),
        ),
      if (ctx.spec['revisionHistoryLimit'] != null) ('History limit', '${ctx.spec['revisionHistoryLimit']}'),
    ], keyWidth: 100);
  }
}

// ---------------------------------------------------------------------------
// Sync history
// ---------------------------------------------------------------------------

class SyncHistoryView extends StatelessWidget {
  final List<Json> history;
  const SyncHistoryView({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (history.isEmpty) return const HintText('Never synced');
    final sorted = [...history]..sort((a, b) => ((b['id'] as num?) ?? 0).compareTo((a['id'] as num?) ?? 0));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < sorted.length; i++)
        () {
          final h = sorted[i];
          final revs = [for (final r in (h['revisions'] as List? ?? const [])) '$r'];
          if (revs.isEmpty && h['revision'] != null) revs.add('${h['revision']}');
          final sources = h['sources'] != null ? asMapList(h['sources']) : [asMap(h['source'])];
          final where = sources
              .where((s) => s.isNotEmpty && s['ref'] == null)
              .map((s) => '${shortRepo(s['repoURL'] as String?)}${s['path'] != null ? '/${s['path']}' : ''}${s['chart'] != null ? ' ${s['chart']}' : ''} @ ${s['targetRevision'] ?? 'HEAD'}')
              .join(', ');
          final initiated = asMap(h['initiatedBy']);
          final current = i == 0;
          return Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
            decoration: BoxDecoration(
              color: current ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: current ? theme.colorScheme.primary.withValues(alpha: 0.4) : AppColors.of(context).separator),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                SizedBox(
                  width: 34,
                  child: Text('#${h['id']}', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700, color: current ? theme.colorScheme.primary : theme.hintColor)),
                ),
                Expanded(child: InlineWrap([for (final r in revs) CopyChip(shortRevision(r), copy: r)])),
                if (current) ...[const StatusBadge('current', severity: Severity.info, dense: true), const SizedBox(width: 8)],
                AgeText(h['deployedAt'], suffix: ' ago'),
              ]),
              Padding(
                padding: const EdgeInsets.only(left: 34, top: 2),
                child: Text(
                  [
                    if (where.isNotEmpty) where,
                    if (initiated.isNotEmpty) 'by ${initiatorOf(initiated)}',
                    if (elapsed(h['deployStartedAt'], h['deployedAt']) != null && h['deployStartedAt'] != null) 'took ${elapsed(h['deployStartedAt'], h['deployedAt'])}',
                  ].join('  ·  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
              ),
            ]),
          );
        }(),
    ]);
  }
}
