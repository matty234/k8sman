import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'pod_containers.dart';
import 'pod_logic.dart';
import 'pod_logs.dart';
import 'pod_widgets.dart';

class PodPanel extends ResourcePanel {
  const PodPanel();

  @override
  Set<String> get kinds => {'/Pod'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final pod = ctx.object;
    final containers = podContainers(pod);
    final volumes = asMapList(ctx.spec['volumes']);
    final scheduling = _schedulingEntries(context, ctx);
    return [
      DetailSection(title: 'Status', icon: Icons.monitor_heart_outlined, child: _StatusSummary(ctx)),
      DetailSection(
        title: 'Containers',
        icon: Icons.view_in_ar_outlined,
        trailing: Hint(_containerCounts(containers)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in containers) ContainerCard(c, namespace: ctx.namespace),
          if (containers.isEmpty) const Hint('No containers'),
        ]),
      ),
      if (volumes.isNotEmpty)
        DetailSection(
          title: 'Volumes',
          icon: Icons.storage_outlined,
          trailing: Hint('${volumes.length}'),
          child: _Volumes(volumes, containers, ctx.namespace),
        ),
      if (scheduling.isNotEmpty)
        DetailSection(title: 'Scheduling', icon: Icons.account_tree_outlined, child: KeyValueTable(scheduling, keyWidth: 110)),
      DetailSection(title: 'Conditions', icon: Icons.fact_check_outlined, child: ConditionsTable(ctx.status['conditions'] as List?)),
    ];
  }

  @override
  List<PanelTab> tabs(PanelContext ctx) => [
        PanelTab(label: 'Logs', icon: Icons.notes, builder: (context, ctx) => PodLogsView(key: ValueKey('logs-${ctx.uid}'), ctx: ctx)),
      ];

  static String _containerCounts(List<PodContainer> cs) {
    final counts = <ContainerKind, int>{};
    for (final c in cs) {
      counts[c.kind] = (counts[c.kind] ?? 0) + 1;
    }
    return [
      if (counts[ContainerKind.init] != null) '${counts[ContainerKind.init]} init',
      if (counts[ContainerKind.sidecar] != null) '${counts[ContainerKind.sidecar]} sidecar',
      if (counts[ContainerKind.regular] != null) '${counts[ContainerKind.regular]} main',
      if (counts[ContainerKind.ephemeral] != null) '${counts[ContainerKind.ephemeral]} ephemeral',
    ].join(' · ');
  }

  List<(String, Object?)> _schedulingEntries(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final mono = monoStyle(context, size: 11);
    Widget lines(List<String> ls) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final l in ls) Padding(padding: const EdgeInsets.only(bottom: 2), child: SelectableText(l, style: mono)),
        ]);

    final aff = asMap(spec['affinity']);
    final na = asMap(aff['nodeAffinity']);
    final nodeAff = <String>[
      for (final t in asMapList(dig(na, ['requiredDuringSchedulingIgnoredDuringExecution', 'nodeSelectorTerms']))) 'required: ${nodeSelectorTermText(t)}',
      for (final p in asMapList(na['preferredDuringSchedulingIgnoredDuringExecution']))
        'preferred (w${p['weight']}): ${nodeSelectorTermText(asMap(p['preference']))}',
    ];
    List<String> podAff(Json a) => [
          for (final t in asMapList(a['requiredDuringSchedulingIgnoredDuringExecution'])) 'required: ${_podAffTerm(t)}',
          for (final p in asMapList(a['preferredDuringSchedulingIgnoredDuringExecution']))
            'preferred (w${p['weight']}): ${_podAffTerm(asMap(p['podAffinityTerm']))}',
        ];
    final pa = podAff(asMap(aff['podAffinity']));
    final paa = podAff(asMap(aff['podAntiAffinity']));

    final tols = asMapList(spec['tolerations']);
    final custom = tols.where((t) => !isDefaultToleration(t)).toList();
    final defaults = tols.length - custom.length;
    final tsc = asMapList(spec['topologySpreadConstraints']);
    final scheduler = spec['schedulerName'];

    return [
      if (asMap(spec['nodeSelector']).isNotEmpty) ('Node selector', LabelChips(asMap(spec['nodeSelector']))),
      if (nodeAff.isNotEmpty) ('Node affinity', lines(nodeAff)),
      if (pa.isNotEmpty) ('Pod affinity', lines(pa)),
      if (paa.isNotEmpty) ('Pod anti-affinity', lines(paa)),
      if (tols.isNotEmpty)
        (
          'Tolerations',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final t in custom) Padding(padding: const EdgeInsets.only(bottom: 2), child: SelectableText(tolerationText(t), style: mono)),
            if (defaults > 0)
              Tooltip(
                message: tols.where(isDefaultToleration).map(tolerationText).join('\n'),
                child: Hint('${custom.isEmpty ? '' : '+ '}$defaults default (not-ready / unreachable, NoExecute)'),
              ),
          ])
        ),
      if (tsc.isNotEmpty)
        (
          'Spread',
          lines([
            for (final t in tsc)
              'maxSkew ${t['maxSkew']} on ${t['topologyKey']} · ${t['whenUnsatisfiable']}'
                  '${selectorToString(t['labelSelector']).isEmpty ? '' : ' · ${selectorToString(t['labelSelector'])}'}'
                  '${t['minDomains'] != null ? ' · minDomains ${t['minDomains']}' : ''}',
          ])
        ),
      if (scheduler != null && scheduler != 'default-scheduler') ('Scheduler', Text('$scheduler', style: small)),
      if (spec['runtimeClassName'] != null) ('Runtime class', Text('${spec['runtimeClassName']}', style: small)),
      if (spec['hostname'] != null || spec['subdomain'] != null)
        ('Hostname', MonoValue([spec['hostname'] ?? ctx.name, if (spec['subdomain'] != null) spec['subdomain']].join('.'), size: 11)),
      if (spec['dnsPolicy'] != null && spec['dnsPolicy'] != 'ClusterFirst') ('DNS policy', Text('${spec['dnsPolicy']}', style: small)),
    ];
  }

  static String _podAffTerm(Json t) {
    final sel = selectorToString(t['labelSelector']);
    final ns = (t['namespaces'] as List?)?.join(',');
    return '${sel.isEmpty ? 'all pods' : sel} per ${t['topologyKey']}${ns != null ? ' in $ns' : ''}';
  }
}

class _StatusSummary extends StatelessWidget {
  final PanelContext ctx;
  const _StatusSummary(this.ctx);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final pod = ctx.object;
    final spec = ctx.spec;
    final status = ctx.status;
    final effective = podEffectiveStatus(pod);
    final phase = '${status['phase'] ?? ''}';
    final containers = podContainers(pod);
    final main = containers.where((c) => c.kind == ContainerKind.regular || c.kind == ContainerKind.sidecar).toList();
    final readyCount = main.where((c) => c.ready).length;
    final restarts = containers.fold<int>(0, (a, c) => a + c.restarts);
    final insights = podInsights(pod);
    final ips = [for (final i in asMapList(status['podIPs'])) '${i['ip']}'];
    if (ips.isEmpty && status['podIP'] != null) ips.add('${status['podIP']}');
    final node = spec['nodeName'] as String?;
    final sa = (spec['serviceAccountName'] ?? spec['serviceAccount']) as String?;
    final qos = status['qosClass'] as String?;
    final podSc = asMap(spec['securityContext']);
    final hostNs = [
      if (spec['hostNetwork'] == true) 'hostNetwork',
      if (spec['hostPID'] == true) 'hostPID',
      if (spec['hostIPC'] == true) 'hostIPC',
    ];
    final inits = containers.where((c) => c.kind == ContainerKind.init).toList();
    final initsDone = inits.where((c) => c.isTerminated && c.terminated['exitCode'] == 0).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        StatusBadge(effective),
        if (effective != phase && phase.isNotEmpty) Hint('phase $phase'),
        StatusBadge('$readyCount/${main.length} ready',
            severity: phase == 'Succeeded' ? Severity.neutral : (readyCount == main.length ? Severity.ok : Severity.error)),
        if (inits.isNotEmpty)
          StatusBadge('init $initsDone/${inits.length}', severity: initsDone == inits.length ? Severity.ok : Severity.warn),
        StatusBadge('$restarts restart${restarts == 1 ? '' : 's'}', severity: restarts > 0 ? Severity.warn : Severity.neutral),
      ]),
      const SizedBox(height: 10),
      if (insights.isNotEmpty)
        InsightList(insights)
      else if (phase == 'Running')
        InsightList([PodInsight(Severity.ok, 'Healthy: all ${main.length} container${main.length == 1 ? '' : 's'} running and ready')])
      else if (phase == 'Succeeded')
        const InsightList([PodInsight(Severity.ok, 'Completed: all containers exited successfully')]),
      const SizedBox(height: 4),
      KeyValueTable(keyWidth: 110, [
        (
          'Node',
          node == null
              ? Text(status['nominatedNodeName'] != null ? 'unscheduled (nominated ${status['nominatedNodeName']})' : 'unscheduled',
                  style: small?.copyWith(color: severityColor(context, Severity.warn)))
              : ResourceLink(ObjectRef(kind: 'Node', name: node), label: node),
        ),
        if (ips.isNotEmpty) ('Pod IP', InlineWrap([for (final ip in ips) Chipish(text: ip, copyValue: ip)])),
        if (status['hostIP'] != null) ('Host IP', InlineWrap([Chipish(text: '${status['hostIP']}', copyValue: '${status['hostIP']}')])),
        if (status['startTime'] != null)
          (
            'Started',
            InlineWrap([AgeText(status['startTime'], suffix: ' ago', style: small), Hint(parseTime(status['startTime'])!.toLocal().toString().split('.').first)])
          ),
        if (qos != null) ('QoS class', InlineWrap([Text(qos, style: small), Hint(_qosHint(qos))])),
        (
          'Priority',
          InlineWrap([
            Text('${spec['priority'] ?? 0}', style: small),
            if (spec['priorityClassName'] != null) Hint('class ${spec['priorityClassName']}'),
            if (spec['preemptionPolicy'] == 'Never') const Hint('never preempts'),
          ])
        ),
        if (sa != null)
          ('Service account', ResourceLink(ObjectRef(kind: 'ServiceAccount', name: sa, namespace: ctx.namespace), label: sa)),
        ('Restart policy', Text('${spec['restartPolicy'] ?? 'Always'} · grace ${spec['terminationGracePeriodSeconds'] ?? 30}s', style: small)),
        if (hostNs.isNotEmpty)
          ('Host namespaces', InlineWrap([for (final h in hostNs) Chipish(text: h, color: severityColor(context, Severity.warn))])),
        if (podSc.isNotEmpty) ('Pod security', securityChips(context, podSc)),
      ]),
    ]);
  }

  static String _qosHint(String q) => switch (q) {
        'BestEffort' => 'no requests/limits · evicted first',
        'Burstable' => 'requests < limits',
        'Guaranteed' => 'requests = limits · evicted last',
        _ => '',
      };
}

class _Volumes extends StatelessWidget {
  final List<Json> volumes;
  final List<PodContainer> containers;
  final String? namespace;
  const _Volumes(this.volumes, this.containers, this.namespace);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, v) in volumes.indexed) ...[
        if (i > 0) Divider(height: 12, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
        _volume(context, v),
      ],
    ]);
  }

  Widget _volume(BuildContext context, Json v) {
    final theme = Theme.of(context);
    final name = '${v['name']}';
    final type = v.keys.firstWhere((k) => k != 'name', orElse: () => 'unknown');
    final src = asMap(v[type]);
    final mounts = [
      for (final c in containers)
        for (final m in asMapList(c.spec['volumeMounts']))
          if (m['name'] == name) '${c.name}:${m['mountPath']}${m['readOnly'] == true ? ' (ro)' : ''}',
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Flexible(child: SelectableText(name, maxLines: 1, style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600))),
        const SizedBox(width: 8),
        Chipish(text: type),
      ]),
      const SizedBox(height: 3),
      Padding(padding: const EdgeInsets.only(left: 8), child: _source(context, type, src)),
      if (mounts.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 8, top: 2),
          child: Text('mounted by ${mounts.join(', ')}', style: monoStyle(context, size: 10.5, color: theme.hintColor)),
        )
      else
        const Padding(padding: EdgeInsets.only(left: 8, top: 2), child: Hint('not mounted by any container')),
    ]);
  }

  Widget _link(String kind, String? name, {String? label}) =>
      ResourceLink(ObjectRef(kind: kind, name: name ?? '', namespace: namespace), label: label ?? '$kind/$name');

  Widget _items(BuildContext context, Json src) {
    final items = asMapList(src['items']);
    if (items.isEmpty) return const SizedBox.shrink();
    return Text(items.map((i) => '${i['key']} → ${i['path']}').join(', '), style: monoStyle(context, size: 10.5, color: Theme.of(context).hintColor));
  }

  Widget _source(BuildContext context, String type, Json src) {
    final opt = src['optional'] == true ? const Hint('optional') : null;
    switch (type) {
      case 'configMap':
        return InlineWrap([_link('ConfigMap', src['name'] as String?), ?opt, _items(context, src)]);
      case 'secret':
        return InlineWrap([_link('Secret', src['secretName'] as String?), ?opt, _items(context, src)]);
      case 'persistentVolumeClaim':
        return InlineWrap([
          _link('PersistentVolumeClaim', src['claimName'] as String?, label: 'pvc/${src['claimName']}'),
          if (src['readOnly'] == true) const Hint('read-only'),
        ]);
      case 'emptyDir':
        return Hint([
          src['medium'] == 'Memory' ? 'tmpfs (memory-backed)' : 'node disk',
          if (src['sizeLimit'] != null) 'limit ${src['sizeLimit']}',
        ].join(' · '));
      case 'hostPath':
        return InlineWrap([MonoValue('${src['path']}', size: 11), if (src['type'] != null && src['type'] != '') Hint('${src['type']}')]);
      case 'downwardAPI':
        return _downward(context, src);
      case 'projected':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final s in asMapList(src['sources'])) Padding(padding: const EdgeInsets.only(bottom: 2), child: _projectedSource(context, s)),
        ]);
      case 'ephemeral':
        final t = asMap(dig(src, ['volumeClaimTemplate', 'spec']));
        return Hint([
          'generic ephemeral PVC',
          if (t['storageClassName'] != null) 'class ${t['storageClassName']}',
          if (dig(t, ['resources', 'requests', 'storage']) != null) '${dig(t, ['resources', 'requests', 'storage'])}',
          if (t['accessModes'] is List) (t['accessModes'] as List).join(','),
        ].join(' · '));
      case 'csi':
        return InlineWrap([
          Hint('driver ${src['driver']}'),
          for (final e in asMap(src['volumeAttributes']).entries) Chipish(text: '${e.key}=${e.value}'),
        ]);
      case 'nfs':
        return MonoValue('${src['server']}:${src['path']}${src['readOnly'] == true ? ' (ro)' : ''}', size: 11);
      case 'image':
        return InlineWrap([Chipish(text: '${src['reference']}', copyValue: '${src['reference']}'), if (src['pullPolicy'] != null) Hint('pull ${src['pullPolicy']}')]);
      default:
        return Hint(src.entries.map((e) => '${e.key}: ${e.value}').join(' · '));
    }
  }

  Widget _downward(BuildContext context, Json src) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final i in asMapList(src['items']))
          Text(
            '${i['path']} ← ${dig(i, ['fieldRef', 'fieldPath']) ?? dig(i, ['resourceFieldRef', 'resource']) ?? '?'}',
            style: monoStyle(context, size: 10.5, color: Theme.of(context).hintColor),
          ),
      ]);

  Widget _projectedSource(BuildContext context, Json s) {
    if (s['configMap'] is Map) {
      final cm = asMap(s['configMap']);
      return InlineWrap([const Hint('configMap'), _link('ConfigMap', cm['name'] as String?, label: '${cm['name']}'), _items(context, cm)]);
    }
    if (s['secret'] is Map) {
      final sec = asMap(s['secret']);
      return InlineWrap([const Hint('secret'), _link('Secret', sec['name'] as String?, label: '${sec['name']}'), _items(context, sec)]);
    }
    if (s['serviceAccountToken'] is Map) {
      final t = asMap(s['serviceAccountToken']);
      return Hint([
        'serviceAccountToken at ${t['path']}',
        if (t['expirationSeconds'] != null) 'expires ${formatDuration(Duration(seconds: (t['expirationSeconds'] as num).toInt()))}',
        if (t['audience'] != null) 'aud ${t['audience']}',
      ].join(' · '));
    }
    if (s['downwardAPI'] is Map) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Hint('downwardAPI  '),
        Flexible(child: _downward(context, asMap(s['downwardAPI']))),
      ]);
    }
    if (s['clusterTrustBundle'] is Map) {
      final b = asMap(s['clusterTrustBundle']);
      return Hint('clusterTrustBundle ${b['name'] ?? b['signerName'] ?? ''} at ${b['path']}');
    }
    return Hint(s.keys.join(', '));
  }
}
