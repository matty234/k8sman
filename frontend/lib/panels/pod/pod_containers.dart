import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../metrics/pod_usage.dart';
import '../../metrics/quantity.dart' show formatPercent;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import 'pod_logic.dart';
import '../../ui/inspector/inspector.dart';
import '../../util/text.dart';
import '../../ui/widgets/atoms.dart';
import '../../ui/widgets/editorial.dart' show HairlineBar;

/// The token volume Kubernetes adds to every pod (`kube-api-access-*`).
bool isDefaultTokenMount(Json m) => '${m['name']}'.startsWith('kube-api-access-') && '${m['mountPath']}' == '/var/run/secrets/kubernetes.io/serviceaccount';

/// "registry.example.com/team/app:1.2" → "app:1.2"; digests shortened.
String shortImage(String image) {
  var s = image.split('/').last;
  final at = s.indexOf('@');
  if (at >= 0 && s.length > at + 20) s = '${s.substring(0, at + 20)}…';
  return s;
}

/// The full image with a digest cut to its first 12 hex digits:
/// "registry.example.com/app:1.2@sha256:65645c7bb6a0…".
String displayImage(String image) {
  final m = RegExp(r'@(sha256:)?([0-9a-f]{12})[0-9a-f]{4,}$').firstMatch(image);
  return m == null ? image : '${image.substring(0, m.start)}@${m[1] ?? ''}${m[2]}…';
}

/// One container as a compact row: state dot, name, short image and state,
/// restarts, usage mini-bars and its actions (logs, previous logs,
/// terminal; on hover, or always while it has a problem). Click to expand
/// the details. Containers with problems start expanded.
///
/// With [template] (a workload's pod template) the container has no live
/// state: no status, restarts, usage or actions, just what its spec says.
class ContainerRow extends StatelessWidget {
  final PodContainer c;
  final String? namespace;

  /// Remembers the expanded state for the session (with the container name).
  final String podUid;

  /// Init and ephemeral containers: drawn quieter.
  final bool quiet;

  /// Opens this container's logs in the dock (`previous` = the last
  /// terminated instance). Null hides the log actions.
  final void Function(BuildContext context, bool previous)? onViewLogs;

  /// Opens a terminal in this container (dock tab). Null hides it; it only
  /// shows while the container is running.
  final void Function(BuildContext context)? onOpenTerminal;

  /// Small CPU/memory bars for the row, or null.
  final Widget? miniUsage;

  /// The pod's volumes, so mounts can link to what backs them.
  final List<Json> volumes;

  /// Optional per-port trailing action (e.g. one-click port-forward).
  final Widget Function(Json port)? portAction;

  /// A pod template's container: the spec only.
  final bool template;

  /// Shows this container's restart count beside it: only worth it when
  /// the pod has several containers (else the header's figure says it).
  final bool showRestarts;

  /// The pod, so env vars from fields resolve and mounts name their claims.
  final Json? pod;

  /// Shows requests and limits in the details (false while the pod's
  /// history charts draw them).
  final bool showResources;
  const ContainerRow(
    this.c, {
    super.key,
    required this.podUid,
    this.namespace,
    this.quiet = false,
    this.onViewLogs,
    this.onOpenTerminal,
    this.miniUsage,
    this.volumes = const [],
    this.portAction,
    this.template = false,
    this.showRestarts = true,
    this.pod,
    this.showResources = true,
  });

  bool get _canTerminal => onOpenTerminal != null && c.isRunning && c.kind != ContainerKind.init;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = !template;
    final sev = live ? c.severity : Severity.neutral;
    final problem = live && c.hasProblem;
    final onSurface = theme.colorScheme.onSurface;
    final name = Text(
      c.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: monoStyle(context, size: 12.5, color: quiet ? onSurface.withValues(alpha: onSurface.a * 0.7) : onSurface).copyWith(fontWeight: FontWeight.w600),
    );
    final image = '${c.spec['image'] ?? ''}';
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final stateColor = sev == Severity.error || sev == Severity.warn ? severityColor(context, sev) : theme.hintColor;
    final state = !live || (c.isRunning && c.kind != ContainerKind.init)
        ? null
        : Text(c.stateLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: stateColor, fontWeight: problem ? FontWeight.w600 : null));
    final showKind = c.kind == ContainerKind.sidecar || ((problem || template) && c.kind != ContainerKind.regular);
    // Done (an init container that exited 0) shows hollow, like no status.
    final done = sev == Severity.ok && c.isTerminated;
    final tip = [c.stateLabel, if (c.hasStatus && c.kind != ContainerKind.init && c.kind != ContainerKind.ephemeral) c.ready ? 'ready' : 'not ready'].join(' · ');
    final actions = <Widget>[
      if (live && onViewLogs != null)
        RowAction(key: ValueKey('view-logs-${c.name}'), icon: Icons.notes, tooltip: 'View logs', onTap: () => onViewLogs!(context, false)),
      if (live && onViewLogs != null && (c.restarts > 0 || c.lastTerminated.isNotEmpty))
        RowAction(
          key: ValueKey('view-previous-logs-${c.name}'),
          icon: Icons.history,
          tooltip: 'Logs of the previous (terminated) instance',
          onTap: () => onViewLogs!(context, true),
        ),
      if (live && _canTerminal)
        RowAction(key: ValueKey('open-terminal-${c.name}'), icon: Icons.terminal, tooltip: 'Open a shell in ${c.name} (bottom panel)', onTap: () => onOpenTerminal!(context)),
    ];

    return InspectorRow(
      key: ValueKey('container-row-${c.name}'),
      memoryId: 'container:$podUid/${c.name}',
      dot: done ? Severity.neutral : sev,
      dotTooltip: live ? tip : null,
      problem: problem,
      title: Row(children: [
        Flexible(child: Tooltip(message: c.name, waitDuration: const Duration(milliseconds: 600), child: name)),
        if (showKind) ...[
          const SizedBox(width: 6),
          Text(c.kind.label.toLowerCase(), style: hint?.copyWith(fontSize: 11)),
        ],
      ]),
      // The state (when not plainly running) leads, so a narrow row
      // shortens the image rather than the reason.
      subtitle: LayoutBuilder(
        builder: (context, box) => Row(children: [
          if (state != null) ...[ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth * 0.7), child: state), Text('  ·  ', style: hint)],
          Flexible(
            child: Tooltip(
              message: image,
              waitDuration: const Duration(milliseconds: 400),
              child: Text(shortImage(image), maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: theme.hintColor)),
            ),
          ),
        ]),
      ),
      // Open, the details show the full image: the subtitle keeps the state.
      openSubtitle: () => state,
      trailing: [
        if (live && showRestarts && c.restarts > 0) _restartBadge(context, small),
        if (live && miniUsage != null) Padding(padding: const EdgeInsets.only(left: 2, top: 3), child: miniUsage!),
      ],
      actions: actions,
      details: (_) => ContainerDetails(c,
          namespace: namespace, volumes: volumes, portAction: live ? portAction : null, template: template, pod: pod, showResources: showResources),
    );
  }

  /// "↻ 3" in the restart pattern's colour (grey for clean exits).
  Widget _restartBadge(BuildContext context, TextStyle? small) {
    final sev = restartKind(c)?.severity ?? Severity.warn;
    final color = sev == Severity.info ? Theme.of(context).hintColor : severityColor(context, sev);
    return Tooltip(
      message: '${plural(c.restarts, 'restart')}${restartKind(c) == null ? '' : ' · ${restartKind(c)!.short}'}',
      child: Row(key: ValueKey('container-restarts-${c.name}'), mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.replay, size: 12, color: color),
        const SizedBox(width: 2),
        Text('${c.restarts}', style: small?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// A single-container pod's container, inline: no row to open, no actions
/// (the header has Logs and Terminal; the restart insight has Previous
/// logs), just its details.
class InlineContainer extends StatelessWidget {
  final PodContainer c;
  final String? namespace;
  final List<Json> volumes;
  final Widget Function(Json port)? portAction;
  final Json pod;
  final bool showResources;
  const InlineContainer(this.c, {super.key, this.namespace, this.volumes = const [], this.portAction, required this.pod, this.showResources = true});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, right: 6),
        child: ContainerDetails(c, namespace: namespace, volumes: volumes, portAction: portAction, pod: pod, showResources: showResources),
      );
}

/// A pod template's containers (init and sidecars, then the rest) as
/// [ContainerRow]s without live state.
class TemplateContainers extends StatelessWidget {
  /// `spec.template` (with `metadata` and `spec`).
  final Json template;
  final String? namespace;

  /// Keys which rows are open for the session, e.g. the workload's uid.
  final String memoryKey;
  const TemplateContainers({super.key, required this.template, required this.namespace, required this.memoryKey});

  @override
  Widget build(BuildContext context) {
    final spec = asMap(template['spec']);
    final volumes = asMapList(spec['volumes']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in podContainers({'spec': spec}))
        ContainerRow(c, podUid: 'template:$memoryKey', namespace: namespace, volumes: volumes, quiet: c.kind == ContainerKind.init, template: true),
    ]);
  }
}

/// CPU and memory as two short stacked bars against the container's limit
/// (else its request); grey unless close to the limit. The tooltip spells
/// out usage, request and limit.
class ContainerMiniUsage extends StatelessWidget {
  final Json pod;
  final String container;
  final Json spec;
  const ContainerMiniUsage({super.key, required this.pod, required this.container, required this.spec});

  /// "CPU 12m · 6% of 200m limit · 50m request".
  static String usageLine(String label, double used, double? limit, double? request, String Function(double?) f) => [
        '$label ${f(used)}',
        if (limit != null && limit > 0) '${formatPercent(used / limit)} of ${f(limit)} limit',
        if (limit == null && request != null && request > 0) '${formatPercent(used / request)} of ${f(request)} request',
        if (limit != null && request != null) '${f(request)} request',
        if (limit == null && request == null) 'no request or limit',
      ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final ns = dig<String>(pod, ['metadata', 'namespace']) ?? '';
    final name = dig<String>(pod, ['metadata', 'name']) ?? '';
    return PodUsageLoader(
      namespace: ns,
      name: name,
      builder: (context, usage, error, loading) {
        final u = usage?.containers[container];
        if (u == null) return const SizedBox.shrink();
        final r = containerResources(spec);
        final cpuBase = r.cpuLim ?? r.cpuReq;
        final memBase = r.memLim ?? r.memReq;
        final tip = [
          usageLine('CPU', u.cpuMillis, r.cpuLim, r.cpuReq, formatCpu),
          usageLine('Memory', u.memoryBytes, r.memLim, r.memReq, formatBytes),
        ].join('\n');
        return Tooltip(
          message: tip,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _MiniBar(cpuBase == null ? null : u.cpuMillis / cpuBase, limited: r.cpuLim != null),
            const SizedBox(height: 3),
            _MiniBar(memBase == null ? null : u.memoryBytes / memBase, limited: r.memLim != null),
          ]),
        );
      },
    );
  }
}

class _MiniBar extends StatelessWidget {
  /// Null: no request or limit to measure against.
  final double? frac;
  final bool limited;
  const _MiniBar(this.frac, {required this.limited});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = frac;
    final color = f == null
        ? Colors.transparent
        : limited && f >= 0.95
            ? severityColor(context, Severity.error)
            : limited && f >= 0.8
                ? severityColor(context, Severity.warn)
                : theme.colorScheme.onSurface.withValues(alpha: 0.45);
    // A sliver for tiny non-zero usage, so the bar never reads as broken.
    final width = f == null ? 0.0 : f.clamp(0.04, 1.0);
    return SizedBox(
      width: 28,
      child: HairlineBar(frac: width, color: color, height: 3, radius: 2, track: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
    );
  }
}

/// The pull policy Kubernetes defaults to for [image]: Always for
/// `:latest` or no tag, IfNotPresent otherwise (a digest counts as pinned).
String defaultPullPolicy(String image) {
  if (image.contains('@')) return 'IfNotPresent';
  final last = image.split('/').last;
  final colon = last.lastIndexOf(':');
  final tag = colon < 0 ? '' : last.substring(colon + 1);
  return tag.isEmpty || tag == 'latest' ? 'Always' : 'IfNotPresent';
}

/// A probe on one line: "HTTPS :8000/startupz · 10s · fails after 360"
/// (the action, its period and failure threshold).
String probeShort(Json p) {
  final String action;
  if (p['httpGet'] is Map) {
    final h = asMap(p['httpGet']);
    action = '${h['scheme'] == 'HTTPS' ? 'HTTPS' : 'HTTP'} ${h['host'] ?? ''}:${h['port'] ?? ''}${h['path'] ?? '/'}';
  } else if (p['tcpSocket'] is Map) {
    final t = asMap(p['tcpSocket']);
    action = 'TCP ${t['host'] ?? ''}:${t['port'] ?? ''}';
  } else if (p['grpc'] is Map) {
    final g = asMap(p['grpc']);
    action = 'gRPC :${g['port'] ?? ''}${g['service'] != null ? ' (${g['service']})' : ''}';
  } else if (p['exec'] is Map) {
    action = 'exec ${shellJoin([for (final c in (dig<List>(p, ['exec', 'command']) ?? const [])) '$c'])}';
  } else {
    action = 'unknown probe';
  }
  return '$action · ${p['periodSeconds'] ?? 10}s · fails after ${p['failureThreshold'] ?? 3}';
}

/// The rest of a probe's timing, for its tooltip.
String probeTiming(Json p) => [
      'every ${p['periodSeconds'] ?? 10}s',
      'timeout ${p['timeoutSeconds'] ?? 1}s',
      'initial delay ${p['initialDelaySeconds'] ?? 0}s',
      'fails after ${p['failureThreshold'] ?? 3} in a row',
      'succeeds after ${p['successThreshold'] ?? 1}',
    ].join(' · ');

/// A container's details, shown when its row is expanded, in small
/// labelled groups (each hidden when empty): runtime (state, image,
/// command), network (ports), health (probes, lifecycle hooks), config
/// (env, mounts, resources). Security is the inspector's Security tab.
/// Usage lives in the row header.
class ContainerDetails extends StatelessWidget {
  final PodContainer c;
  final String? namespace;

  /// The pod's volumes, so a mount can link to what backs it.
  final List<Json> volumes;
  final Widget Function(Json port)? portAction;

  /// A pod template's container: no state, just the spec.
  final bool template;

  /// The pod: env vars from its fields show their values, and mounts of
  /// ephemeral volumes name their claims.
  final Json? pod;

  /// False while the pod's history charts show CPU and memory requests
  /// and limits: then only other resources (storage, GPUs) show here.
  final bool showResources;
  const ContainerDetails(this.c, {super.key, this.namespace, this.volumes = const [], this.portAction, this.template = false, this.pod, this.showResources = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final spec = c.spec;
    final cmd = [for (final x in (spec['command'] as List? ?? const [])) '$x', for (final x in (spec['args'] as List? ?? const [])) '$x'];
    final probes = [
      ('Startup', asMap(spec['startupProbe'])),
      ('Liveness', asMap(spec['livenessProbe'])),
      ('Readiness', asMap(spec['readinessProbe'])),
    ].where((p) => p.$2.isNotEmpty).toList();
    final hooks = asMap(spec['lifecycle']);
    final ports = asMapList(spec['ports']);
    final env = asMapList(spec['env']);
    final envFrom = asMapList(spec['envFrom']);
    final mounts = asMapList(spec['volumeMounts']);
    // Running and ready says it all in the row: just when it started.
    final plainRunning = c.isRunning && c.kind != ContainerKind.init && (c.ready || c.kind == ContainerKind.ephemeral);

    final config = <Widget>[
      if (env.isNotEmpty || envFrom.isNotEmpty)
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (env.isNotEmpty) _envWidget(context, env),
          if (env.isNotEmpty && envFrom.isNotEmpty) const SizedBox(height: 3),
          if (envFrom.isNotEmpty) _envFromWidget(context, envFrom),
        ]),
      if (mounts.isNotEmpty) _mountsWidget(context, mounts),
      if (_resourceKeys.isNotEmpty) _resourcesWidget(context),
    ];

    final groups = <Widget>[
      QuietGroup(key: const ValueKey('container-group-runtime'), 'Runtime', [
        if (!template && plainRunning)
          _Field('Started', AgeText(c.running['startedAt'], suffix: ' ago', style: small))
        else if (!template)
          _Field('State', _stateWidget(context)),
        if (!template && c.lastTerminated.isNotEmpty) _Field('Last state', _lastStateWidget(context)),
        if (c.kind == ContainerKind.ephemeral && spec['targetContainerName'] != null) _Field('Target', Text('${spec['targetContainerName']}', style: small)),
        _Field('Image', _imageWidget(context)),
        if (cmd.isNotEmpty) _Field('Command', _Copyable(shellJoin(cmd))),
        if (spec['workingDir'] != null) _Field('Workdir', _Copyable('${spec['workingDir']}')),
      ]),
      if (ports.isNotEmpty) QuietGroup(key: const ValueKey('container-group-network'), 'Network', [_portsWidget(context, ports)]),
      if (probes.isNotEmpty || hooks.isNotEmpty)
        QuietGroup(key: const ValueKey('container-group-health'), 'Health', [
          for (final (label, p) in probes)
            _Field(
              label,
              Tooltip(
                message: '${probeSentence(p).split(' every ').first}\n${probeTiming(p)}',
                waitDuration: const Duration(milliseconds: 400),
                child: Text(probeShort(p), maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
              ),
            ),
          for (final e in hooks.entries) _Field(e.key, Text(_hookText(asMap(e.value)), style: small)),
        ]),
      if (config.isNotEmpty) QuietGroup(key: const ValueKey('container-group-config'), 'Config', config, gap: 10),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, g) in groups.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 14), child: g),
    ]);
  }

  Widget _stateWidget(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    if (!c.hasStatus) return Text('No status reported yet', style: hint);
    final started = c.status['started'];
    final flags = <String>[
      if (c.kind != ContainerKind.init) c.ready ? 'ready' : 'not ready',
      if (started != null) started == true ? 'started' : 'not started',
    ].join(' · ');
    if (c.isRunning) {
      return InlineWrap([
        Text('Running since', style: small),
        AgeText(c.running['startedAt'], suffix: ' ago', style: small),
        if (flags.isNotEmpty) Text('· $flags', style: hint),
      ]);
    }
    if (c.isWaiting) {
      final msg = c.waiting['message'];
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InlineWrap([
          Text('Waiting: ${c.waiting['reason'] ?? 'unknown'}',
              style: small?.copyWith(color: severityColor(context, c.severity), fontWeight: FontWeight.w600)),
          if (flags.isNotEmpty) Text('· $flags', style: hint),
        ]),
        if (msg != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text('$msg', style: hint)),
      ]);
    }
    return _terminatedWidget(context, c.terminated, current: true);
  }

  Widget _terminatedWidget(BuildContext context, Json t, {required bool current}) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final code = (t['exitCode'] as num?)?.toInt() ?? 0;
    final s = parseTime(t['startedAt']);
    final f = parseTime(t['finishedAt']);
    final hintText = exitCodeHint(code);
    final color = code == 0 ? null : severityColor(context, Severity.error);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InlineWrap([
        Text('${current ? 'Terminated: ' : ''}${t['reason'] ?? (code == 0 ? 'Completed' : 'Error')} · exit $code',
            style: small?.copyWith(color: color, fontWeight: FontWeight.w600)),
        if (f != null) AgeText(t['finishedAt'], suffix: ' ago', style: small),
        if (s != null && f != null) Text('· ran ${formatDuration(f.difference(s))}', style: hint),
      ]),
      if (hintText != null) Text(hintText, style: hint),
      if (t['message'] != null)
        Padding(padding: const EdgeInsets.only(top: 2), child: CodeBlock('${t['message']}'.trim(), maxLines: 8)),
    ]);
  }

  Widget _lastStateWidget(BuildContext context) {
    // The restart pattern's colour (calm for clean exits), as the dot.
    final sev = restartKind(c)?.severity ?? (c.lastTerminated['exitCode'] == 0 ? Severity.info : Severity.error);
    final c2 = sev == Severity.info ? Theme.of(context).hintColor : severityColor(context, sev);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(width: 2, margin: const EdgeInsets.only(right: 8, top: 1, bottom: 1), color: c2),
        Expanded(child: _terminatedWidget(context, c.lastTerminated, current: false)),
      ]),
    );
  }

  /// The image once, in full but with a digest shortened (click to copy
  /// it whole), the pull policy only when it isn't the default for the
  /// tag, the running digest in the tooltip (and a copy-digest action on
  /// hover).
  Widget _imageWidget(BuildContext context) {
    final theme = Theme.of(context);
    final image = '${c.spec['image'] ?? ''}';
    final policy = c.spec['imagePullPolicy'] as String?;
    final id = '${c.status['imageID'] ?? ''}';
    final at = id.indexOf('@');
    final digest = at >= 0 ? id.substring(at + 1) : id;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Hoverable(
        builder: (h) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Flexible(
            child: Tooltip(
              message: [image, if (digest.isNotEmpty && !image.contains(digest)) 'running $digest', 'Click to copy'].join('\n'),
              waitDuration: const Duration(milliseconds: 400),
              child: Hoverable(
                onTap: () => copyToClipboard(context, image),
                builder: (th) => Text(
                  displayImage(image),
                  key: ValueKey('container-image-${c.name}'),
                  style: monoStyle(context, size: 11, color: th ? theme.colorScheme.primary : null),
                ),
              ),
            ),
          ),
          if (h && digest.isNotEmpty) _HoverIcon(icon: Icons.fingerprint, tooltip: 'Copy digest $digest', onTap: () => copyToClipboard(context, id)),
        ]),
      ),
      if (policy != null && policy != defaultPullPolicy(image)) HintText('pull $policy'),
    ]);
  }

  Widget _portsWidget(BuildContext context, List<Json> ports) => Wrap(spacing: 14, runSpacing: 4, children: [
        for (final p in ports) _Port(p, key: ValueKey('container-port-${c.name}-${p['containerPort']}'), action: portAction),
      ]);

  /// The resources to list: all of them, or (while the charts draw CPU and
  /// memory) the rest.
  List<String> get _resourceKeys {
    final r = asMap(c.spec['resources']);
    return {...asMap(r['requests']).keys, ...asMap(r['limits']).keys}.where((k) => showResources || (k != 'cpu' && k != 'memory')).toList()..sort();
  }

  /// One line per resource: "50m request · 200m limit".
  Widget _resourcesWidget(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final r = asMap(c.spec['resources']);
    final req = asMap(r['requests']);
    final lim = asMap(r['limits']);
    final keys = _resourceKeys;
    String label(String k) => switch (k) { 'cpu' => 'CPU', 'memory' => 'Memory', 'ephemeral-storage' => 'Storage', _ => k };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final k in keys)
        _Field(
          label(k),
          Text.rich(
            TextSpan(style: small, children: [
              if (req[k] != null) ...[TextSpan(text: '${req[k]}'), TextSpan(text: ' request', style: hint)],
              if (req[k] != null && lim[k] != null) TextSpan(text: '  ·  ', style: hint),
              if (lim[k] != null) ...[TextSpan(text: '${lim[k]}'), TextSpan(text: ' limit', style: hint)],
              if (lim[k] == null && k == 'memory') TextSpan(text: '  ·  no limit', style: hint),
            ]),
          ),
          tooltip: k,
        ),
    ]);
  }

  static String _hookText(Json h) {
    if (h['exec'] is Map) return 'exec ${shellJoin([for (final x in (dig<List>(h, ['exec', 'command']) ?? const [])) '$x'])}';
    if (h['httpGet'] is Map) return 'HTTP GET :${dig(h, ['httpGet', 'port'])}${dig(h, ['httpGet', 'path']) ?? '/'}';
    if (h['sleep'] is Map) return 'sleep ${dig(h, ['sleep', 'seconds'])}s';
    if (h['tcpSocket'] is Map) return 'TCP :${dig(h, ['tcpSocket', 'port'])}';
    return h.keys.join(', ');
  }

  /// Names in plain text, literal values in mono (copy on hover), and
  /// references as links. Long lists show the first few.
  Widget _envWidget(BuildContext context, List<Json> env) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    Widget value(Json e) {
      if (e.containsKey('value')) return _Copyable('${e['value']}');
      final vf = asMap(e['valueFrom']);
      String optional(Json r) => r['optional'] == true ? ' (optional)' : '';
      if (vf['configMapKeyRef'] is Map || vf['secretKeyRef'] is Map) {
        final isCm = vf['configMapKeyRef'] is Map;
        final r = asMap(vf[isCm ? 'configMapKeyRef' : 'secretKeyRef']);
        return InlineWrap([
          ResourceLink(ObjectRef(kind: isCm ? 'ConfigMap' : 'Secret', name: '${r['name']}', namespace: namespace), label: '${isCm ? 'cm' : 'secret'}/${r['name']}'),
          // The key only when it differs from the variable's name.
          if (r['key'] != e['name'] || r['optional'] == true) Text('${r['key'] != e['name'] ? 'key ${r['key']}' : ''}${optional(r)}'.trim(), style: hint),
        ]);
      }
      // From the pod's fields or resources: the value, its source in grey.
      if (vf['fieldRef'] is Map || vf['resourceFieldRef'] is Map) {
        final r = asMap(vf['resourceFieldRef']);
        final source = vf['fieldRef'] is Map
            ? '${dig(vf, ['fieldRef', 'fieldPath'])}'
            : '${r['resource']}${r['containerName'] != null ? ' of ${r['containerName']}' : ''}${r['divisor'] != null ? ' / ${r['divisor']}' : ''}';
        final resolved = pod == null ? null : resolveEnvSource(pod!, c.spec, vf);
        if (resolved == null) return Text('${vf['fieldRef'] is Map ? 'field' : 'resource'} $source', style: hint);
        return InlineWrap([_Copyable(resolved), Text(source, style: hint)]);
      }
      return Text(vf.keys.join(', '), style: hint);
    }

    return TrimmedList.builder(
      key: ValueKey('container-env-${c.name}'),
      total: env.length,
      builder: (shown) => Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        // Names take what they need up to 40%; values the rest.
        columnWidths: const {0: MinColumnWidth(IntrinsicColumnWidth(), FractionColumnWidth(0.4)), 1: FlexColumnWidth()},
        children: [
          for (final e in env.take(shown))
            TableRow(children: [
              Padding(padding: const EdgeInsets.only(right: 12, bottom: 3), child: Text('${e['name']}', style: small)),
              Padding(padding: const EdgeInsets.only(bottom: 3), child: value(e)),
            ]),
        ],
      ),
    );
  }

  Widget _envFromWidget(BuildContext context, List<Json> envFrom) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final e in envFrom)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: InlineWrap([
            Text('all keys from', style: hint),
            if (e['configMapRef'] is Map)
              ResourceLink(ObjectRef(kind: 'ConfigMap', name: '${dig(e, ['configMapRef', 'name'])}', namespace: namespace),
                  label: 'cm/${dig(e, ['configMapRef', 'name'])}'),
            if (e['secretRef'] is Map)
              ResourceLink(ObjectRef(kind: 'Secret', name: '${dig(e, ['secretRef', 'name'])}', namespace: namespace),
                  label: 'secret/${dig(e, ['secretRef', 'name'])}'),
            if (e['prefix'] != null) Text('prefix ${e['prefix']}', style: hint),
          ]),
        ),
    ]);
  }

  /// "path ← volume": the path in mono, the volume a link to what backs it
  /// (ConfigMap, Secret, PVC) or plain text with its type in a tooltip.
  Widget _mountsWidget(BuildContext context, List<Json> all) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final token = all.where(isDefaultTokenMount).firstOrNull;
    final shown = [for (final m in all) if (m != token) m];
    Widget volume(String name) {
      final v = volumes.where((v) => v['name'] == name).firstOrNull ?? const {};
      final type = v.keys.firstWhere((k) => k != 'name', orElse: () => '');
      final src = asMap(v[type]);
      // A claim by its own name (what env vars and the PVC list say), the
      // volume's name quiet after it.
      final podName = dig<String>(pod, ['metadata', 'name']);
      final claim = switch (type) {
        'persistentVolumeClaim' => '${src['claimName']}',
        'ephemeral' when podName != null => '$podName-$name',
        _ => null,
      };
      if (claim != null) {
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Tooltip(
              message: 'PersistentVolumeClaim $claim${type == 'ephemeral' ? ' (ephemeral, deleted with the pod)' : ''}',
              waitDuration: const Duration(milliseconds: 400),
              child: ResourceLink(ObjectRef(kind: 'PersistentVolumeClaim', name: claim, namespace: namespace), label: claim),
            ),
          ),
          if (claim != name) Text('  vol $name', style: hint),
        ]);
      }
      final ref = switch (type) {
        'configMap' => ObjectRef(kind: 'ConfigMap', name: '${src['name']}', namespace: namespace),
        'secret' => ObjectRef(kind: 'Secret', name: '${src['secretName']}', namespace: namespace),
        _ => null,
      };
      if (ref == null) return Tooltip(message: type.isEmpty ? 'volume $name' : '$type volume', child: Text(name, style: hint));
      return Tooltip(message: '${ref.kind} ${ref.name}', waitDuration: const Duration(milliseconds: 400), child: ResourceLink(ref, label: name));
    }

    Widget mount(Json m) => Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Hoverable(
            builder: (h) => Wrap(spacing: 6, runSpacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${m['mountPath']}', style: monoStyle(context, size: 11)),
              Text('←', style: hint),
              volume('${m['name']}'),
              if (m['subPath'] != null || m['subPathExpr'] != null) Text('subPath ${m['subPath'] ?? m['subPathExpr']}', style: hint),
              if (m['readOnly'] == true) Text('read-only', style: hint),
              if (m['mountPropagation'] != null) Text('${m['mountPropagation']}', style: hint),
              if (h) _HoverIcon(icon: Icons.copy, tooltip: 'Copy path', onTap: () => copyToClipboard(context, '${m['mountPath']}')),
            ]),
          ),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (shown.isNotEmpty)
        TrimmedList.builder(
          key: ValueKey('container-mounts-${c.name}'),
          total: shown.length,
          builder: (n) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final m in shown.take(n)) mount(m)]),
        ),
      // Every pod has it: one quiet line instead of the full path.
      if (token != null)
        Align(
          alignment: Alignment.centerLeft,
          child: Tooltip(
            message: '${token['mountPath']}  ←  ${token['name']}${token['readOnly'] == true ? '  read-only' : ''}',
            child: HintText(shown.isEmpty ? 'service account token' : '+ service account token'),
          ),
        ),
    ]);
  }
}

/// A label in a narrow aligned column beside its value.
class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  final String? tooltip;
  const _Field(this.label, this.child, {this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: theme.hintColor));
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 72, child: Padding(padding: const EdgeInsets.only(right: 8), child: tooltip == null ? text : Tooltip(message: tooltip!, child: text))),
      Expanded(child: DefaultTextStyle.merge(style: small, child: child)),
    ]);
  }
}

/// Mono text with a copy icon after it on hover.
class _Copyable extends StatelessWidget {
  final String text;
  const _Copyable(this.text);

  @override
  Widget build(BuildContext context) => Hoverable(
        builder: (h) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Flexible(child: Text(text, style: monoStyle(context, size: 11))),
          // Trailing, so showing it moves nothing.
          if (h) _HoverIcon(icon: Icons.copy, tooltip: 'Copy', onTap: () => copyToClipboard(context, text)),
        ]),
      );
}

class _HoverIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _HoverIcon({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Hoverable(
        onTap: onTap,
        builder: (h) => Padding(
          padding: const EdgeInsets.fromLTRB(5, 2, 1, 0),
          child: Icon(icon, size: 12, color: h ? theme.colorScheme.onSurface : theme.hintColor),
        ),
      ),
    );
  }
}

/// "postgresql 5432/TCP" in mono; its port-forward icon shows on hover.
/// A live forward (the action draws a wider `localhost:N` link instead
/// of the icon) stays visible.
class _Port extends StatelessWidget {
  final Json p;
  final Widget Function(Json port)? action;
  const _Port(this.p, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    final theme = Theme.of(context);
    final mono = monoStyle(context, size: 11);
    final text = Text.rich(TextSpan(style: mono, children: [
      if (p['name'] != null) TextSpan(text: '${p['name']} ', style: mono.copyWith(color: theme.hintColor)),
      TextSpan(text: '${p['containerPort']}/${p['protocol'] ?? 'TCP'}'),
      if (p['hostPort'] != null) TextSpan(text: ' host ${p['hostIP'] ?? ''}:${p['hostPort']}', style: mono.copyWith(color: theme.hintColor)),
    ]));
    return Hoverable(
      builder: (h) => Row(mainAxisSize: MainAxisSize.min, children: [
        text,
        if (action != null) Padding(padding: const EdgeInsets.only(left: 3), child: RevealOnHover(visible: h, blockWhenHidden: false, child: action(p))),
      ]),
    );
  }
}

