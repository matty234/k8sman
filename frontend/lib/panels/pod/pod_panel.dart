import '../../ui/portforward/quick_forward.dart';
import '../../ui/security/security_tab.dart' show securityTab;

import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/models.dart';
import '../../gpu/gpu_sections.dart';
import '../../prometheus/metric_history_chart.dart';
import '../../prometheus/prom_api.dart';
import '../../metrics/network_usage.dart';
import '../../ui/logs/open_logs.dart';
import '../../ui/terminal/open_terminal.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'pod_containers.dart';
import 'pod_logic.dart';
import '../../ui/inspector/inspector.dart';
import 'pod_status.dart';
import '../../util/text.dart';
import '../../ui/widgets/atoms.dart';

class PodPanel extends ResourcePanel {
  const PodPanel();

  @override
  Set<String> get kinds => {'/Pod'};

  @override
  bool get ownerInHeader => true;

  @override
  List<PanelTab> tabs(PanelContext ctx) => [securityTab(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final pod = ctx.object;
    final containers = podContainers(pod);
    final volumes = asMapList(ctx.spec['volumes']);
    final scheduling = _schedulingEntries(context, ctx);
    final conditions = asMapList(ctx.status['conditions']);
    final falseConds = [for (final c in conditions) if (c['status'] != 'True') '${c['type']}'];

    // Problems first (any kind), then the healthy main containers and
    // sidecars; healthy init and ephemeral containers go in quieter groups.
    final troubled = [for (final c in containers) if (c.hasProblem) c];
    final healthyMain = [for (final c in containers) if (!c.hasProblem && (c.kind == ContainerKind.regular || c.kind == ContainerKind.sidecar)) c];
    final healthyInit = [for (final c in containers) if (!c.hasProblem && c.kind == ContainerKind.init) c];
    final healthyEph = [for (final c in containers) if (!c.hasProblem && c.kind == ContainerKind.ephemeral) c];
    // While the history charts draw requests and limits, the container
    // details leave CPU and memory out (known once Prometheus was asked).
    final charted = PromApi.of(ctx.api).knownHasPrometheus == true;
    // One forward per port (only while the container runs).
    Widget Function(Json)? forward(PodContainer c) => c.isRunning
        ? (p) => QuickForwardButton(
              api: ctx.api,
              app: ctx.app,
              namespace: ctx.namespace ?? 'default',
              kind: 'pod',
              name: ctx.name,
              port: '${p['containerPort']}',
              protocol: p['protocol'] as String?,
            )
        : null;
    Widget row(PodContainer c, {bool quiet = false}) => ContainerRow(
      c,
      key: ValueKey('container-${ctx.uid}/${c.name}'),
      podUid: ctx.uid,
      namespace: ctx.namespace,
      quiet: quiet,
      onViewLogs: (context, previous) => openPodLogs(context, ctx.object, container: c.name, previous: previous),
      onOpenTerminal: ctx.app.readOnly ? null : (context) => openPodTerminal(context, ctx.object, container: c.name),
      miniUsage: c.isRunning ? ContainerMiniUsage(pod: ctx.object, container: c.name, spec: c.spec) : null,
      volumes: volumes,
      portAction: forward(c),
      showRestarts: containers.length > 1,
      pod: pod,
      showResources: !charted,
    );

    // One long-running container: shown inline, its init and ephemeral
    // containers (if any) as rows under it.
    final single = singleMainContainer(containers);
    final Widget containersSection;
    if (single != null) {
      final initRows = [for (final c in containers) if (c.kind == ContainerKind.init) row(c, quiet: !c.hasProblem)];
      final ephRows = [for (final c in containers) if (c.kind == ContainerKind.ephemeral) row(c, quiet: !c.hasProblem)];
      containersSection = InspectorSection(
        id: 'container',
        title: 'Container',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: SectionSummary(single.name)),
          if (single.isRunning) ...[const SizedBox(width: 8), ContainerMiniUsage(pod: pod, container: single.name, spec: single.spec)],
        ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InlineContainer(single,
              key: ValueKey('inline-container-${ctx.uid}'), namespace: ctx.namespace, volumes: volumes, portAction: forward(single), pod: pod, showResources: !charted),
          if (initRows.isNotEmpty) ...[const _GroupLabel('Init'), ...initRows],
          if (ephRows.isNotEmpty) ...[const _GroupLabel('Ephemeral'), ...ephRows],
        ]),
      );
    } else {
      containersSection = InspectorSection(
        id: 'containers',
        title: 'Containers',
        trailing: SectionSummary(_containerCounts(containers)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in troubled) row(c),
            for (final c in healthyMain) row(c),
            if (healthyInit.isNotEmpty) ...[const _GroupLabel('Init'), for (final c in healthyInit) row(c, quiet: true)],
            if (healthyEph.isNotEmpty) ...[const _GroupLabel('Ephemeral'), for (final c in healthyEph) row(c, quiet: true)],
            if (containers.isEmpty) const HintText('No containers'),
          ],
        ),
      );
    }

    return [
      // Is this pod OK, and if not, why?
      PodStatusHeader(ctx),
      // What it runs (the spec), then the live data.
      containersSection,
      // Reference detail: collapsed by default, a one-line summary in the
      // header; opening one keeps it open for the next pod.
      if (volumes.isNotEmpty)
        InspectorSection(
          id: 'volumes',
          title: 'Volumes',
          initiallyExpanded: false,
          trailing: SectionSummary(_volumeSummary(volumes)),
          child: _Volumes(volumes, containers, ctx.namespace, ctx.name),
        ),
      if (scheduling.isNotEmpty)
        InspectorSection(
          id: 'scheduling',
          title: 'Scheduling',
          initiallyExpanded: false,
          trailing: SectionSummary(_schedulingSummary(ctx.spec)),
          child: KeyValueTable(scheduling, keyWidth: 110),
        ),
      InspectorSection(
        id: 'configuration',
        title: 'Configuration',
        initiallyExpanded: false,
        trailing: SectionSummary(_configSummary(ctx)),
        child: _Configuration(ctx),
      ),
      // CPU / memory history (hidden when Prometheus isn't available).
      podHistory(ctx),
      // Live network from the kubelet when there is no Prometheus.
      liveNetworkSection(ctx),
      gpuPodSection(ctx),
      InspectorSection(
        id: 'conditions',
        title: 'Conditions',
        initiallyExpanded: false,
        trailing: SectionSummary(
          conditions.isEmpty ? 'none' : (falseConds.isEmpty ? 'all ${conditions.length} true' : '${falseConds.join(', ')} false'),
          color: falseConds.isEmpty ? null : severityColor(context, Severity.warn),
        ),
        child: ConditionsTable(ctx.status['conditions'] as List?),
      ),
    ];
  }

  /// "1 PVC, 2 ConfigMaps, 1 emptyDir" (the service account token aside).
  static String _volumeSummary(List<Json> volumes) {
    final counts = <String, int>{};
    for (final v in volumes) {
      if (_Volumes._isDefaultToken(v)) continue;
      final type = v.keys.firstWhere((k) => k != 'name', orElse: () => 'unknown');
      final label = switch (type) {
        'persistentVolumeClaim' || 'ephemeral' => 'PVC',
        'configMap' => 'ConfigMap',
        'secret' => 'Secret',
        final t => t,
      };
      counts[label] = (counts[label] ?? 0) + 1;
    }
    if (counts.isEmpty) return 'service account token';
    final n = counts.values.fold<int>(0, (a, b) => a + b);
    String name(String label, int c) => c == 1 || !RegExp(r'^[A-Z]').hasMatch(label) ? label : '${label}s';
    return '$n · ${counts.entries.map((e) => '${e.value} ${name(e.key, e.value)}').join(', ')}';
  }

  static String _schedulingSummary(Json spec) {
    final aff = asMap(spec['affinity']);
    final tols = asMapList(spec['tolerations']);
    final custom = tols.where((t) => !isDefaultToleration(t)).length;
    return [
      if (asMap(spec['nodeSelector']).isNotEmpty) 'node selector',
      if (aff['nodeAffinity'] != null) 'node affinity',
      if (aff['podAffinity'] != null) 'pod affinity',
      if (aff['podAntiAffinity'] != null) 'anti-affinity',
      if (asMapList(spec['topologySpreadConstraints']).isNotEmpty) 'spread',
      if (custom > 0) plural(custom, 'toleration'),
      if (custom == 0 && tols.isNotEmpty) 'default tolerations',
    ].join(' · ');
  }

  static String _configSummary(PanelContext ctx) {
    final qos = ctx.status['qosClass'] as String?;
    final pc = ctx.spec['priorityClassName'] as String?;
    return [?qos, ?pc, '${ctx.spec['restartPolicy'] ?? 'Always'}'].join(' · ');
  }

  /// Logs open in the bottom dock (not a sidebar tab) so they keep
  /// streaming while the user navigates.
  @override
  List<ResourceAction> actions(PanelContext ctx) => [podLogsAction(ctx), podTerminalAction(ctx)];

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
    Widget lines(List<String> ls) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in ls)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(l, style: mono),
          ),
      ],
    );

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
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final t in custom)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(tolerationText(t), style: mono),
                ),
              if (defaults > 0)
                Tooltip(
                  message: tols.where(isDefaultToleration).map(tolerationText).join('\n'),
                  child: HintText('${custom.isEmpty ? '' : '+ '}$defaults default (not-ready / unreachable, NoExecute)'),
                ),
            ],
          ),
        ),
      if (tsc.isNotEmpty)
        (
          'Spread',
          lines([
            for (final t in tsc)
              'maxSkew ${t['maxSkew']} on ${t['topologyKey']} · ${t['whenUnsatisfiable']}'
                  '${selectorToString(t['labelSelector']).isEmpty ? '' : ' · ${selectorToString(t['labelSelector'])}'}'
                  '${t['minDomains'] != null ? ' · minDomains ${t['minDomains']}' : ''}',
          ]),
        ),
      if (scheduler != null && scheduler != 'default-scheduler') ('Scheduler', Text('$scheduler', style: small)),
      if (spec['runtimeClassName'] != null) ('Runtime class', Text('${spec['runtimeClassName']}', style: small)),
      if (spec['hostname'] != null || spec['subdomain'] != null)
        ('Hostname', MonoText([spec['hostname'] ?? ctx.name, if (spec['subdomain'] != null) spec['subdomain']].join('.'), size: 11)),
      if (spec['dnsPolicy'] != null && spec['dnsPolicy'] != 'ClusterFirst') ('DNS policy', Text('${spec['dnsPolicy']}', style: small)),
    ];
  }

  static String _podAffTerm(Json t) {
    final sel = selectorToString(t['labelSelector']);
    final ns = (t['namespaces'] as List?)?.join(',');
    return '${sel.isEmpty ? 'all pods' : sel} per ${t['topologyKey']}${ns != null ? ' in $ns' : ''}';
  }
}

/// A quiet caption over a group of healthy init or ephemeral containers.
class _GroupLabel extends StatelessWidget {
  final String text;
  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 0, 2),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
    );
  }
}

/// Pod-level settings that rarely explain a problem: QoS, priority, restart
/// policy and grace period, start time and the pod security context.
class _Configuration extends StatelessWidget {
  final PanelContext ctx;
  const _Configuration(this.ctx);

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final spec = ctx.spec;
    final status = ctx.status;
    final qos = status['qosClass'] as String?;
    final started = parseTime(status['startTime']);
    return KeyValueTable(keyWidth: 110, [
      if (qos != null) ('QoS class', InlineWrap([Text(qos, style: small), HintText(_qosHint(qos))])),
      (
        'Priority',
        InlineWrap([
          Text('${spec['priority'] ?? 0}', style: small),
          if (spec['priorityClassName'] != null) HintText('class ${spec['priorityClassName']}'),
          if (spec['preemptionPolicy'] == 'Never') const HintText('never preempts'),
        ]),
      ),
      ('Restart policy', Text('${spec['restartPolicy'] ?? 'Always'} · grace ${spec['terminationGracePeriodSeconds'] ?? 30}s', style: small)),
      if (started != null) ('Started', InlineWrap([Text(started.toLocal().toString().split('.').first, style: small), AgeText(status['startTime'], suffix: ' ago')])),
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
  final String pod;
  const _Volumes(this.volumes, this.containers, this.namespace, this.pod);

  /// The token volume Kubernetes adds to every pod (`kube-api-access-*`:
  /// a service account token, kube-root-ca.crt and the namespace): shown
  /// as one footer line rather than a full entry.
  static bool _isDefaultToken(Json v) {
    if (!'${v['name']}'.startsWith('kube-api-access-')) return false;
    final sources = asMapList(dig(v, ['projected', 'sources']));
    return sources.isNotEmpty && sources.any((s) => s['serviceAccountToken'] is Map);
  }

  @override
  Widget build(BuildContext context) {
    final shown = [for (final v in volumes) if (!_isDefaultToken(v)) v];
    final token = volumes.where(_isDefaultToken).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final v in shown) Padding(padding: const EdgeInsets.only(bottom: 8), child: _volume(context, v)),
        if (token != null)
          Tooltip(
            message: 'Added by Kubernetes: a service account token, kube-root-ca.crt and the namespace\n${_mountsOf('${token['name']}').join('\n')}',
            child: HintText('+ service account token (${token['name']})'),
          ),
      ],
    );
  }

  List<String> _mountsOf(String volume) => [
    for (final c in containers)
      for (final m in asMapList(c.spec['volumeMounts']))
        if (m['name'] == volume) '${c.name}:${m['mountPath']}${m['readOnly'] == true ? ' (ro)' : ''}',
  ];

  /// Mounts grouped by path: "/csi (a, b, c)", or just "/csi" when the pod
  /// has a single container.
  String _mountSummary(String volume) {
    final byPath = <String, List<String>>{};
    for (final c in containers) {
      for (final m in asMapList(c.spec['volumeMounts'])) {
        if (m['name'] != volume) continue;
        byPath.putIfAbsent('${m['mountPath']}${m['readOnly'] == true ? ' (ro)' : ''}', () => []).add(c.name);
      }
    }
    final single = containers.length < 2;
    return byPath.entries.map((e) => single ? e.key : '${e.key} (${e.value.join(', ')})').join(' · ');
  }

  Widget _volume(BuildContext context, Json v) {
    final theme = Theme.of(context);
    final name = '${v['name']}';
    final type = v.keys.firstWhere((k) => k != 'name', orElse: () => 'unknown');
    final src = asMap(v[type]);
    final mounts = _mountSummary(name);
    // A claim leads with its own name (what the PVC list and env vars
    // say), the volume's name quiet after it.
    final claim = switch (type) {
      'persistentVolumeClaim' => '${src['claimName']}',
      'ephemeral' => '$pod-$name',
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: claim != null
              ? [
                  _link('PersistentVolumeClaim', claim, label: claim),
                  if (claim != name) HintText('vol $name'),
                  _source(context, type, src, name),
                ]
              : [
                  Text(name, style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600)),
                  Chipish(text: type),
                  _source(context, type, src, name),
                ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: mounts.isEmpty
              ? const HintText('not mounted')
              : Text('→ $mounts', style: monoStyle(context, size: 10.5, color: theme.hintColor)),
        ),
      ],
    );
  }

  Widget _link(String kind, String? name, {String? label}) => ResourceLink(
    ObjectRef(kind: kind, name: name ?? '', namespace: namespace),
    label: label ?? '$kind/$name',
  );

  Widget _items(BuildContext context, Json src) {
    final items = asMapList(src['items']);
    if (items.isEmpty) return const SizedBox.shrink();
    return Text(items.map((i) => '${i['key']} → ${i['path']}').join(', '), style: monoStyle(context, size: 10.5, color: Theme.of(context).hintColor));
  }

  Widget _source(BuildContext context, String type, Json src, String volume) {
    final opt = src['optional'] == true ? const HintText('optional') : null;
    switch (type) {
      case 'configMap':
        return InlineWrap([_link('ConfigMap', src['name'] as String?, label: '${src['name']}'), ?opt, _items(context, src)]);
      case 'secret':
        return InlineWrap([_link('Secret', src['secretName'] as String?, label: '${src['secretName']}'), ?opt, _items(context, src)]);
      case 'persistentVolumeClaim':
        // The claim leads the line (see _volume).
        return src['readOnly'] == true ? const HintText('read-only') : const SizedBox.shrink();
      case 'emptyDir':
        return HintText([src['medium'] == 'Memory' ? 'tmpfs (memory-backed)' : 'node disk', if (src['sizeLimit'] != null) 'limit ${src['sizeLimit']}'].join(' · '));
      case 'hostPath':
        final hostType = '${src['type'] ?? ''}';
        return InlineWrap([
          MonoText('${src['path']}', size: 11),
          // Directory / DirectoryOrCreate are the norm; name the rest (File, Socket, …).
          if (!const {'', 'Directory', 'DirectoryOrCreate'}.contains(hostType)) HintText(hostType),
        ]);
      case 'downwardAPI':
        return _downward(context, src);
      case 'projected':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final s in asMapList(src['sources'])) Padding(padding: const EdgeInsets.only(bottom: 2), child: _projectedSource(context, s))],
        );
      case 'ephemeral':
        // Kubernetes names the claim <pod>-<volume> and deletes it with the pod.
        final t = asMap(dig(src, ['volumeClaimTemplate', 'spec']));
        return InlineWrap([
          HintText(
            [
              'ephemeral, deleted with the pod',
              if (t['storageClassName'] != null) 'class ${t['storageClassName']}',
              if (dig(t, ['resources', 'requests', 'storage']) != null) '${dig(t, ['resources', 'requests', 'storage'])}',
              if (t['accessModes'] is List) (t['accessModes'] as List).join(','),
            ].join(' · '),
          ),
          if (t['volumeMode'] == 'Block') const HintText('block device'),
        ]);
      case 'csi':
        return InlineWrap([HintText('driver ${src['driver']}'), for (final e in asMap(src['volumeAttributes']).entries) Chipish(text: '${e.key}=${e.value}')]);
      case 'nfs':
        return MonoText('${src['server']}:${src['path']}${src['readOnly'] == true ? ' (ro)' : ''}', size: 11);
      case 'image':
        return InlineWrap([
          Chipish(text: '${src['reference']}', copyValue: '${src['reference']}'),
          if (src['pullPolicy'] != null) HintText('pull ${src['pullPolicy']}'),
        ]);
      default:
        return HintText(src.entries.map((e) => '${e.key}: ${e.value}').join(' · '));
    }
  }

  Widget _downward(BuildContext context, Json src) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final i in asMapList(src['items']))
        Text(
          '${i['path']} ← ${dig(i, ['fieldRef', 'fieldPath']) ?? dig(i, ['resourceFieldRef', 'resource']) ?? '?'}',
          style: monoStyle(context, size: 10.5, color: Theme.of(context).hintColor),
        ),
    ],
  );

  Widget _projectedSource(BuildContext context, Json s) {
    if (s['configMap'] is Map) {
      final cm = asMap(s['configMap']);
      return InlineWrap([const HintText('configMap'), _link('ConfigMap', cm['name'] as String?, label: '${cm['name']}'), _items(context, cm)]);
    }
    if (s['secret'] is Map) {
      final sec = asMap(s['secret']);
      return InlineWrap([const HintText('secret'), _link('Secret', sec['name'] as String?, label: '${sec['name']}'), _items(context, sec)]);
    }
    if (s['serviceAccountToken'] is Map) {
      final t = asMap(s['serviceAccountToken']);
      return HintText(
        [
          'serviceAccountToken at ${t['path']}',
          if (t['expirationSeconds'] != null) 'expires ${formatDuration(Duration(seconds: (t['expirationSeconds'] as num).toInt()))}',
          if (t['audience'] != null) 'aud ${t['audience']}',
        ].join(' · '),
      );
    }
    if (s['downwardAPI'] is Map) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HintText('downwardAPI  '),
          Flexible(child: _downward(context, asMap(s['downwardAPI']))),
        ],
      );
    }
    if (s['clusterTrustBundle'] is Map) {
      final b = asMap(s['clusterTrustBundle']);
      return HintText('clusterTrustBundle ${b['name'] ?? b['signerName'] ?? ''} at ${b['path']}');
    }
    return HintText(s.keys.join(', '));
  }
}
