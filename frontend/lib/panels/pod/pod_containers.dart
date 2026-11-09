import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../metrics/pod_usage.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import 'pod_logic.dart';
import 'pod_section.dart';
import 'pod_widgets.dart';
import '../../util/text.dart';

/// The token volume Kubernetes adds to every pod (`kube-api-access-*`).
bool isDefaultTokenMount(Json m) => '${m['name']}'.startsWith('kube-api-access-') && '${m['mountPath']}' == '/var/run/secrets/kubernetes.io/serviceaccount';

/// "registry.example.com/team/app:1.2" → "app:1.2"; digests shortened.
String shortImage(String image) {
  var s = image.split('/').last;
  final at = s.indexOf('@');
  if (at >= 0 && s.length > at + 20) s = '${s.substring(0, at + 20)}…';
  return s;
}

/// One container as a compact row: state dot, name, short image and state,
/// restarts, usage mini-bars and its actions (logs, previous logs,
/// terminal; on hover, or always while it has a problem). Click to expand
/// the details. Containers with problems start expanded.
class ContainerRow extends StatefulWidget {
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

  /// Live CPU/memory usage meters for the details, or null to hide them.
  final Widget? usage;

  /// Optional per-port trailing action (e.g. one-click port-forward).
  final Widget Function(Json port)? portAction;
  const ContainerRow(
    this.c, {
    super.key,
    required this.podUid,
    this.namespace,
    this.quiet = false,
    this.onViewLogs,
    this.onOpenTerminal,
    this.miniUsage,
    this.usage,
    this.portAction,
  });

  @override
  State<ContainerRow> createState() => _ContainerRowState();
}

class _ContainerRowState extends State<ContainerRow> {
  String get _memoryId => 'container:${widget.podUid}/${widget.c.name}';
  late bool _open = PodSectionMemory.isOpen(_memoryId, fallback: widget.c.hasProblem);

  PodContainer get c => widget.c;
  bool get _canTerminal => widget.onOpenTerminal != null && c.isRunning && c.kind != ContainerKind.init;

  void _toggle() {
    setState(() => _open = !_open);
    PodSectionMemory.set(_memoryId, _open);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return Hoverable(
      key: ValueKey('container-row-${c.name}'),
      onTap: _toggle,
      builder: (hovered) => Container(
        decoration: BoxDecoration(
          color: hovered && !_open ? colors.hover : null,
          borderRadius: BorderRadius.circular(5),
        ),
        padding: const EdgeInsets.fromLTRB(4, 7, 2, 7),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(context, theme, hovered),
          if (_open)
            // Taps inside the details (links, copy, selection) must not
            // collapse the row.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: MouseRegion(
                cursor: SystemMouseCursors.basic,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(15, 10, 6, 4),
                  child: ContainerDetails(c, namespace: widget.namespace, usage: widget.usage, portAction: widget.portAction),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _header(BuildContext context, ThemeData theme, bool hovered) {
    final sev = c.severity;
    final problem = c.hasProblem;
    final onSurface = theme.colorScheme.onSurface;
    final name = Text(
      c.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: monoStyle(context, size: 12.5, color: widget.quiet ? onSurface.withValues(alpha: 0.7) : onSurface).copyWith(fontWeight: FontWeight.w600),
    );
    final image = '${c.spec['image'] ?? ''}';
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final stateColor = sev == Severity.error || sev == Severity.warn ? severityColor(context, sev) : theme.hintColor;
    final state = c.isRunning && c.kind != ContainerKind.init
        ? null
        : Text(c.stateLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: stateColor, fontWeight: problem ? FontWeight.w600 : null));
    final showActions = hovered || problem || _open;
    final actions = <Widget>[
      if (widget.onViewLogs != null)
        _IconAction(key: ValueKey('view-logs-${c.name}'), icon: Icons.notes, tooltip: 'View logs', onTap: () => widget.onViewLogs!(context, false)),
      if (widget.onViewLogs != null && (c.restarts > 0 || c.lastTerminated.isNotEmpty))
        _IconAction(
          key: ValueKey('view-previous-logs-${c.name}'),
          icon: Icons.history,
          tooltip: 'Logs of the previous (terminated) instance',
          onTap: () => widget.onViewLogs!(context, true),
        ),
      if (_canTerminal)
        _IconAction(key: ValueKey('open-terminal-${c.name}'), icon: Icons.terminal, tooltip: 'Open a shell in ${c.name} (bottom panel)', onTap: () => widget.onOpenTerminal!(context)),
    ];

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 5), child: _StateDot(c)),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Tooltip(message: c.name, waitDuration: const Duration(milliseconds: 600), child: name)),
            if (c.kind == ContainerKind.sidecar || (problem && c.kind != ContainerKind.regular)) ...[
              const SizedBox(width: 6),
              Text(c.kind.label.toLowerCase(), style: hint?.copyWith(fontSize: 11)),
            ],
          ]),
          const SizedBox(height: 2),
          // The state (when not plainly running) leads, so a narrow row
          // shortens the image rather than the reason.
          LayoutBuilder(
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
        ]),
      ),
      if (c.restarts > 0) ...[
        const SizedBox(width: 8),
        Tooltip(
          message: plural(c.restarts, 'restart'),
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.replay, size: 12, color: severityColor(context, Severity.warn)),
              const SizedBox(width: 2),
              Text('${c.restarts}', style: small?.copyWith(color: severityColor(context, Severity.warn), fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ],
      if (widget.miniUsage != null) ...[const SizedBox(width: 10), Padding(padding: const EdgeInsets.only(top: 4), child: widget.miniUsage!)],
      if (actions.isNotEmpty) ...[
        const SizedBox(width: 6),
        IgnorePointer(
          ignoring: !showActions,
          child: AnimatedOpacity(
            opacity: showActions ? 1 : 0,
            duration: const Duration(milliseconds: 100),
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
        ),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 1, left: 2),
        child: AnimatedRotation(
          turns: _open ? 0.25 : 0,
          duration: const Duration(milliseconds: 120),
          child: Icon(Icons.chevron_right, size: 16, color: hovered || _open ? theme.hintColor : theme.hintColor.withValues(alpha: 0.5)),
        ),
      ),
    ]);
  }
}

/// A small dot in the container's state colour: green running and ready,
/// amber/red for problems, hollow grey for completed or no status.
class _StateDot extends StatelessWidget {
  final PodContainer c;
  const _StateDot(this.c);

  @override
  Widget build(BuildContext context) {
    final sev = c.severity;
    final done = sev == Severity.ok && c.isTerminated;
    final hollow = sev == Severity.neutral || done;
    final color = severityColor(context, done ? Severity.neutral : sev);
    final tip = [c.stateLabel, if (c.hasStatus && c.kind != ContainerKind.init && c.kind != ContainerKind.ephemeral) c.ready ? 'ready' : 'not ready'].join(' · ');
    return Tooltip(
      message: tip,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(shape: BoxShape.circle, color: hollow ? null : color, border: hollow ? Border.all(color: color, width: 1.2) : null),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconAction({super.key, required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: Hoverable(
        onTap: onTap,
        builder: (h) => Container(
          width: 22,
          height: 20,
          decoration: BoxDecoration(color: h ? accent.withValues(alpha: 0.12) : null, borderRadius: BorderRadius.circular(4)),
          child: Icon(icon, size: 14, color: h ? accent : theme.hintColor),
        ),
      ),
    );
  }
}

/// CPU and memory as two short stacked bars against the container's limit
/// (else its request); grey unless close to the limit.
class ContainerMiniUsage extends StatelessWidget {
  final Json pod;
  final String container;
  final Json spec;
  const ContainerMiniUsage({super.key, required this.pod, required this.container, required this.spec});

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
        String line(String label, String used, double? lim, double? req, String Function(double?) f) =>
            '$label ${usageAgainst(used, limit: lim == null ? null : f(lim), request: req == null ? null : f(req))}';
        final tip = [
          line('CPU', formatCpu(u.cpuMillis), r.cpuLim, r.cpuReq, formatCpu),
          line('Memory', formatBytes(u.memoryBytes), r.memLim, r.memReq, formatBytes),
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
    return Container(
      width: 28,
      height: 3,
      decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(2)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: width,
        child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
      ),
    );
  }
}

/// A container's details, shown when its row is expanded: state, last
/// state, image, command, ports, resources and usage, probes, lifecycle,
/// env, mounts and security context.
class ContainerDetails extends StatelessWidget {
  final PodContainer c;
  final String? namespace;
  final Widget? usage;
  final Widget Function(Json port)? portAction;
  const ContainerDetails(this.c, {super.key, this.namespace, this.usage, this.portAction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = c.spec;
    final cmd = [for (final x in (spec['command'] as List? ?? const [])) '$x', for (final x in (spec['args'] as List? ?? const [])) '$x'];
    final probes = [
      ('startup', asMap(spec['startupProbe'])),
      ('liveness', asMap(spec['livenessProbe'])),
      ('readiness', asMap(spec['readinessProbe'])),
    ].where((p) => p.$2.isNotEmpty).toList();
    // Running and ready says it all in the row: just when it started.
    final plainRunning = c.isRunning && c.kind != ContainerKind.init && (c.ready || c.kind == ContainerKind.ephemeral);

    return KeyValueTable(keyWidth: 78, [
      if (plainRunning)
        ('Started', AgeText(c.running['startedAt'], suffix: ' ago', style: theme.textTheme.bodySmall))
      else
        ('State', _stateWidget(context)),
      if (c.lastTerminated.isNotEmpty) ('Last state', _lastStateWidget(context)),
      if (c.kind == ContainerKind.ephemeral && spec['targetContainerName'] != null) ('Target', MonoValue('${spec['targetContainerName']}')),
      ('Image', _imageWidget(context)),
      if (cmd.isNotEmpty) ('Command', CodeBlock(shellJoin(cmd))),
      if (spec['workingDir'] != null) ('Working dir', MonoValue('${spec['workingDir']}')),
      if (asMapList(spec['ports']).isNotEmpty) ('Ports', _portsWidget(context)),
      if (_hasResources(spec)) ('Resources', _resourcesWidget(context)),
      if (usage != null) ('Usage', usage!),
      if (probes.isNotEmpty)
        (
          'Probes',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (label, p) in probes)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 62, child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
                  Expanded(child: Text(probeSentence(p), style: theme.textTheme.bodySmall)),
                ]),
              ),
          ]),
        ),
      if (asMap(spec['lifecycle']).isNotEmpty) ('Lifecycle', _lifecycleWidget(context)),
      if (asMapList(spec['env']).isNotEmpty) ('Env', _envWidget(context)),
      if (asMapList(spec['envFrom']).isNotEmpty) ('Env from', _envFromWidget(context)),
      if (asMapList(spec['volumeMounts']).isNotEmpty) ('Mounts', _mountsWidget(context)),
      if (asMap(spec['securityContext']).isNotEmpty) ('Security', securityChips(context, asMap(spec['securityContext']))),
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
    final c2 = severityColor(context, c.lastTerminated['exitCode'] == 0 ? Severity.warn : Severity.error);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(width: 2, margin: const EdgeInsets.only(right: 8, top: 1, bottom: 1), color: c2),
        Expanded(child: _terminatedWidget(context, c.lastTerminated, current: false)),
      ]),
    );
  }

  Widget _imageWidget(BuildContext context) {
    final image = '${c.spec['image'] ?? ''}';
    final policy = c.spec['imagePullPolicy'];
    final id = '${c.status['imageID'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InlineWrap([
        Chipish(text: image, copyValue: image),
        if (policy != null) Hint('pull $policy'),
      ]),
      if (id.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: _imageIdWidget(context, id)),
    ]);
  }

  Widget _imageIdWidget(BuildContext context, String id) {
    final at = id.indexOf('@');
    final digest = at >= 0 ? id.substring(at + 1) : id;
    final short = digest.length > 19 ? '${digest.substring(0, 19)}…' : digest;
    return Tooltip(
      message: id,
      child: Row(children: [Flexible(child: Text(short, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: Theme.of(context).hintColor))), CopyIcon(id)]),
    );
  }

  Widget _portsWidget(BuildContext context) => InlineWrap([
        for (final p in asMapList(c.spec['ports']))
          Row(mainAxisSize: MainAxisSize.min, children: [
            Chipish(
              text: [
                if (p['name'] != null) '${p['name']}',
                '${p['containerPort']}/${p['protocol'] ?? 'TCP'}',
                if (p['hostPort'] != null) 'host ${p['hostIP'] ?? ''}:${p['hostPort']}',
              ].join(' '),
              copyValue: '${p['containerPort']}',
            ),
            if (portAction != null) ...[const SizedBox(width: 2), portAction!(p)],
          ]),
      ]);

  static bool _hasResources(Json spec) {
    final r = asMap(spec['resources']);
    return asMap(r['requests']).isNotEmpty || asMap(r['limits']).isNotEmpty;
  }

  Widget _resourcesWidget(BuildContext context) {
    final theme = Theme.of(context);
    final r = asMap(c.spec['resources']);
    final req = asMap(r['requests']);
    final lim = asMap(r['limits']);
    final keys = {...req.keys, ...lim.keys}.toList()..sort();
    final head = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11);
    TableRow row(List<Widget> cells) => TableRow(children: [for (final w in cells) Padding(padding: const EdgeInsets.only(bottom: 2), child: w)]);
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      columnWidths: const {3: FlexColumnWidth()},
      children: [
        row([const SizedBox(), Padding(padding: const EdgeInsets.only(left: 16), child: Text('request', style: head)), Padding(padding: const EdgeInsets.only(left: 16), child: Text('limit', style: head)), const SizedBox()]),
        for (final k in keys)
          row([
            Text(k, style: monoStyle(context, size: 11, color: theme.hintColor)),
            Padding(padding: const EdgeInsets.only(left: 16), child: Text('${req[k] ?? '—'}', style: monoStyle(context, size: 11))),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text('${lim[k] ?? '—'}', style: monoStyle(context, size: 11, color: lim[k] == null && k == 'memory' ? theme.hintColor : null)),
            ),
            const SizedBox(),
          ]),
      ],
    );
  }

  Widget _lifecycleWidget(BuildContext context) {
    final lc = asMap(c.spec['lifecycle']);
    String handler(Json h) {
      if (h['exec'] is Map) return 'exec ${shellJoin([for (final x in (dig<List>(h, ['exec', 'command']) ?? const [])) '$x'])}';
      if (h['httpGet'] is Map) return 'HTTP GET :${dig(h, ['httpGet', 'port'])}${dig(h, ['httpGet', 'path']) ?? '/'}';
      if (h['sleep'] is Map) return 'sleep ${dig(h, ['sleep', 'seconds'])}s';
      if (h['tcpSocket'] is Map) return 'TCP :${dig(h, ['tcpSocket', 'port'])}';
      return h.keys.join(', ');
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final e in lc.entries) Text('${e.key}: ${handler(asMap(e.value))}', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  Widget _envWidget(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    Widget value(Json e) {
      if (e.containsKey('value')) return MonoValue('${e['value']}', size: 11);
      final vf = asMap(e['valueFrom']);
      String optional(Json r) => r['optional'] == true ? ' (optional)' : '';
      if (vf['configMapKeyRef'] is Map || vf['secretKeyRef'] is Map) {
        final isCm = vf['configMapKeyRef'] is Map;
        final r = asMap(vf[isCm ? 'configMapKeyRef' : 'secretKeyRef']);
        return InlineWrap([
          ResourceLink(ObjectRef(kind: isCm ? 'ConfigMap' : 'Secret', name: '${r['name']}', namespace: namespace), label: '${isCm ? 'cm' : 'secret'}/${r['name']}'),
          Text('key ${r['key']}${optional(r)}', style: monoStyle(context, size: 11, color: theme.hintColor)),
        ]);
      }
      if (vf['fieldRef'] is Map) return Text('field ${dig(vf, ['fieldRef', 'fieldPath'])}', style: hint);
      if (vf['resourceFieldRef'] is Map) {
        final r = asMap(vf['resourceFieldRef']);
        return Text('resource ${r['resource']}${r['containerName'] != null ? ' of ${r['containerName']}' : ''}${r['divisor'] != null ? ' / ${r['divisor']}' : ''}', style: hint);
      }
      return Text(vf.keys.join(', '), style: hint);
    }

    final env = asMapList(c.spec['env']);
    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      children: [
        for (final e in env)
          TableRow(children: [
            Padding(
              padding: const EdgeInsets.only(right: 10, bottom: 3),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text('${e['name']}', style: monoStyle(context, size: 11, color: theme.colorScheme.primary)),
              ),
            ),
            Padding(padding: const EdgeInsets.only(bottom: 3), child: value(e)),
          ]),
      ],
    );
  }

  Widget _envFromWidget(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final e in asMapList(c.spec['envFrom']))
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: InlineWrap([
            Hint('all keys from'),
            if (e['configMapRef'] is Map)
              ResourceLink(ObjectRef(kind: 'ConfigMap', name: '${dig(e, ['configMapRef', 'name'])}', namespace: namespace),
                  label: 'cm/${dig(e, ['configMapRef', 'name'])}'),
            if (e['secretRef'] is Map)
              ResourceLink(ObjectRef(kind: 'Secret', name: '${dig(e, ['secretRef', 'name'])}', namespace: namespace),
                  label: 'secret/${dig(e, ['secretRef', 'name'])}'),
            if (e['prefix'] != null) Text('prefix ${e['prefix']}', style: monoStyle(context, size: 11, color: theme.hintColor)),
          ]),
        ),
    ]);
  }

  Widget _mountsWidget(BuildContext context) {
    final theme = Theme.of(context);
    final all = asMapList(c.spec['volumeMounts']);
    final token = all.where(isDefaultTokenMount).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final m in all)
        if (m != token)
          Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '${m['mountPath']}', style: monoStyle(context, size: 11)),
              TextSpan(text: '  ←  ', style: monoStyle(context, size: 11, color: theme.hintColor)),
              TextSpan(text: '${m['name']}', style: monoStyle(context, size: 11, color: theme.colorScheme.primary)),
              if (m['subPath'] != null || m['subPathExpr'] != null)
                TextSpan(text: '  subPath ${m['subPath'] ?? m['subPathExpr']}', style: monoStyle(context, size: 11, color: theme.hintColor)),
              if (m['readOnly'] == true) TextSpan(text: '  ro', style: TextStyle(fontSize: 11, color: theme.hintColor, fontWeight: FontWeight.w600)),
              if (m['mountPropagation'] != null) TextSpan(text: '  ${m['mountPropagation']}', style: TextStyle(fontSize: 11, color: theme.hintColor)),
            ]),
          ),
        ),
      // Every pod has it: one quiet line instead of the full path.
      if (token != null)
        Tooltip(
          message: '${token['mountPath']}  ←  ${token['name']}${token['readOnly'] == true ? '  ro' : ''}',
          child: const Hint('+ service account token'),
        ),
    ]);
  }
}

/// Compact chip summary of a (pod or container) securityContext.
Widget securityChips(BuildContext context, Json sc) {
  final err = severityColor(context, Severity.error);
  final ok = severityColor(context, Severity.ok);
  final chips = <Widget>[];
  void add(String t, [Color? c]) => chips.add(Chipish(text: t, color: c));
  if (sc['privileged'] == true) add('privileged', err);
  if (sc['runAsUser'] != null) add('uid ${sc['runAsUser']}', sc['runAsUser'] == 0 ? err : null);
  if (sc['runAsGroup'] != null) add('gid ${sc['runAsGroup']}');
  if (sc['fsGroup'] != null) add('fsGroup ${sc['fsGroup']}');
  if (sc['runAsNonRoot'] == true) add('runAsNonRoot', ok);
  if (sc['readOnlyRootFilesystem'] == true) add('read-only rootfs', ok);
  if (sc['allowPrivilegeEscalation'] == false) add('no privilege escalation', ok);
  if (sc['allowPrivilegeEscalation'] == true) add('privilege escalation allowed', err);
  final caps = asMap(sc['capabilities']);
  for (final a in (caps['add'] as List? ?? const [])) {
    add('+$a', err);
  }
  for (final d in (caps['drop'] as List? ?? const [])) {
    add('-$d');
  }
  final seccomp = dig(sc, ['seccompProfile', 'type']);
  if (seccomp != null) add('seccomp $seccomp');
  if (sc['supplementalGroups'] is List) add('groups ${(sc['supplementalGroups'] as List).join(',')}');
  if (sc['procMount'] != null) add('procMount ${sc['procMount']}');
  if (sc['sysctls'] is List) {
    for (final s in asMapList(sc['sysctls'])) {
      add('${s['name']}=${s['value']}');
    }
  }
  if (chips.isEmpty) return Hint(sc.keys.join(', '));
  return InlineWrap(chips);
}
