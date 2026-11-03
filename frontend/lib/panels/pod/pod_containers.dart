import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import 'pod_logic.dart';
import 'pod_widgets.dart';

/// One card per container (init, sidecar, regular, ephemeral).
class ContainerCard extends StatelessWidget {
  final PodContainer c;
  final String? namespace;
  const ContainerCard(this.c, {super.key, this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sev = c.severity;
    final problem = sev == Severity.error || sev == Severity.warn;
    final accent = problem ? severityColor(context, sev) : (c.restarts > 0 ? severityColor(context, Severity.warn) : null);
    final spec = c.spec;
    final cmd = [for (final x in (spec['command'] as List? ?? const [])) '$x', for (final x in (spec['args'] as List? ?? const [])) '$x'];
    final probes = [
      ('Startup', asMap(spec['startupProbe'])),
      ('Liveness', asMap(spec['livenessProbe'])),
      ('Readiness', asMap(spec['readinessProbe'])),
    ].where((p) => p.$2.isNotEmpty);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: accent != null && sev == Severity.error ? accent.withValues(alpha: 0.05) : theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent?.withValues(alpha: 0.7) ?? theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Row(children: [
            KindTag(c.kind),
            const SizedBox(width: 8),
            Flexible(
              child: SelectableText(c.name, maxLines: 1, style: monoStyle(context, size: 13).copyWith(fontWeight: FontWeight.w700)),
            ),
            const Spacer(),
            if (c.restarts > 0) ...[
              Tooltip(
                message: 'Restart count',
                child: StatusBadge('${c.restarts} restart${c.restarts == 1 ? '' : 's'}', dense: true, severity: c.restarts > 0 ? Severity.warn : Severity.neutral),
              ),
              const SizedBox(width: 6),
            ],
            StatusBadge(c.stateLabel, dense: true, severity: sev),
            if (c.hasStatus && c.kind != ContainerKind.init && c.kind != ContainerKind.ephemeral) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: c.ready ? 'Ready' : 'Not ready',
                child: Icon(c.ready ? Icons.check_circle : Icons.cancel, size: 16, color: severityColor(context, c.ready ? Severity.ok : Severity.error)),
              ),
            ],
          ]),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
          child: KeyValueTable(keyWidth: 84, [
            ('State', _stateWidget(context)),
            if (c.lastTerminated.isNotEmpty) ('Last state', _lastStateWidget(context)),
            if (c.kind == ContainerKind.ephemeral && spec['targetContainerName'] != null) ('Target', MonoValue('${spec['targetContainerName']}')),
            ('Image', _imageWidget(context)),
            if ((c.status['imageID'] ?? '').toString().isNotEmpty) ('Image ID', _imageIdWidget(context, '${c.status['imageID']}')),
            if (cmd.isNotEmpty) ('Command', CodeBlock(shellJoin(cmd))),
            if (spec['workingDir'] != null) ('Working dir', MonoValue('${spec['workingDir']}')),
            if (asMapList(spec['ports']).isNotEmpty) ('Ports', _portsWidget(context)),
            if (_hasResources(spec)) ('Resources', _resourcesWidget(context)),
            for (final (label, p) in probes) (label, Text(probeSentence(p), style: theme.textTheme.bodySmall)),
            if (asMap(spec['lifecycle']).isNotEmpty) ('Lifecycle', _lifecycleWidget(context)),
            if (asMapList(spec['env']).isNotEmpty) ('Env', _envWidget(context)),
            if (asMapList(spec['envFrom']).isNotEmpty) ('Env from', _envFromWidget(context)),
            if (asMapList(spec['volumeMounts']).isNotEmpty) ('Mounts', _mountsWidget(context)),
            if (asMap(spec['securityContext']).isNotEmpty) ('Security', securityChips(context, asMap(spec['securityContext']))),
          ]),
        ),
      ]),
    );
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
        if (msg != null) Padding(padding: const EdgeInsets.only(top: 2), child: SelectableText('$msg', style: hint)),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(color: c2.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(4)),
      child: _terminatedWidget(context, c.lastTerminated, current: false),
    );
  }

  Widget _imageWidget(BuildContext context) {
    final image = '${c.spec['image'] ?? ''}';
    final policy = c.spec['imagePullPolicy'];
    return InlineWrap([
      Chipish(text: image, copyValue: image),
      if (policy != null) Hint('pull $policy'),
    ]);
  }

  Widget _imageIdWidget(BuildContext context, String id) {
    final at = id.indexOf('@');
    final digest = at >= 0 ? id.substring(at + 1) : id;
    final short = digest.length > 19 ? '${digest.substring(0, 19)}…' : digest;
    return Tooltip(
      message: id,
      child: Row(children: [MonoValue(short, size: 11, color: Theme.of(context).hintColor), CopyIcon(id)]),
    );
  }

  Widget _portsWidget(BuildContext context) => InlineWrap([
        for (final p in asMapList(c.spec['ports']))
          Chipish(
            text: [
              if (p['name'] != null) '${p['name']}',
              '${p['containerPort']}/${p['protocol'] ?? 'TCP'}',
              if (p['hostPort'] != null) 'host ${p['hostIP'] ?? ''}:${p['hostPort']}',
            ].join(' '),
            copyValue: '${p['containerPort']}',
          ),
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
                child: SelectableText('${e['name']}', style: monoStyle(context, size: 11, color: theme.colorScheme.primary)),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final m in asMapList(c.spec['volumeMounts']))
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
