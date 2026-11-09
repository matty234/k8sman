/// Small widgets and helpers shared by the network panels.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import 'inspector_kit.dart';

/// Runs [load] once (in initState) and re-runs it only when [fetchKey]
/// changes or the user asks for a reload. Build it with a stable key
/// (e.g. `ValueKey('${ctx.uid}/endpoints')`).
class NetFetch<T> extends StatefulWidget {
  final Object fetchKey;
  final Future<T> Function() load;
  final Widget Function(BuildContext context, AsyncSnapshot<T> snap, VoidCallback reload) builder;
  const NetFetch({super.key, required this.fetchKey, required this.load, required this.builder});

  @override
  State<NetFetch<T>> createState() => _NetFetchState<T>();
}

class _NetFetchState<T> extends State<NetFetch<T>> {
  late Future<T> _future = widget.load();

  @override
  void didUpdateWidget(covariant NetFetch<T> old) {
    super.didUpdateWidget(old);
    if (old.fetchKey != widget.fetchKey) _future = widget.load();
  }

  void _reload() => setState(() => _future = widget.load());

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<T>(future: _future, builder: (context, snap) => widget.builder(context, snap, _reload));
}

/// Stable string fingerprint of a JSON value, for [NetFetch.fetchKey].
String fingerprint(Object? v) => jsonEncode(v);

const spinner = Padding(
  padding: EdgeInsets.all(8),
  child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
);

/// Small refresh button for section trailers.
class RefreshButton extends StatelessWidget {
  final VoidCallback onPressed;
  const RefreshButton(this.onPressed, {super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        iconSize: 15,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 26, height: 26),
          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh),
        onPressed: onPressed,
      );
}

/// Monospace text with a trailing copy icon. Selectable.
class CopyText extends StatelessWidget {
  final String text;
  final String? copyValue;
  final Color? color;
  final double size;
  const CopyText(this.text, {super.key, this.copyValue, this.color, this.size = 12});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: Text(text, style: monoStyle(context, size: size, color: color))),
      const SizedBox(width: 2),
      InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => copyToClipboard(context, copyValue ?? text),
        child: Tooltip(
          message: 'Copy',
          child: Padding(padding: const EdgeInsets.all(3), child: Icon(Icons.copy, size: 12, color: theme.hintColor)),
        ),
      ),
    ]);
  }
}

/// A one-line command / name in a tinted box with a copy button.
class CopyLine extends StatelessWidget {
  final String text;
  final String? label;
  const CopyLine(this.text, {super.key, this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 3, 2, 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        if (label != null) ...[
          SizedBox(width: 74, child: Text(label!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
        ],
        Expanded(child: Text(text, style: monoStyle(context, size: 11.5))),
        IconButton(
          iconSize: 13,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          tooltip: 'Copy',
          icon: const Icon(Icons.copy),
          onPressed: () => copyToClipboard(context, text),
        ),
      ]),
    );
  }
}

/// Compact table with a muted header row and hairline separators.
/// [flex] gives a flex factor per column; null means size to content.
class NetTable extends StatelessWidget {
  final List<String> headers;
  final List<List<Widget>> rows;
  final List<double?> flex;
  const NetTable({super.key, required this.headers, required this.rows, required this.flex});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600, letterSpacing: 0.3);
    final line = BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35));
    Widget cell(Widget w) => Padding(padding: const EdgeInsets.fromLTRB(0, 5, 10, 5), child: w);
    return Table(
      columnWidths: {
        for (var i = 0; i < flex.length; i++) i: flex[i] == null ? const IntrinsicColumnWidth() : FlexColumnWidth(flex[i]!),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder(horizontalInside: line),
      children: [
        TableRow(children: [for (final h in headers) cell(Text(h.toUpperCase(), style: head))]),
        for (final r in rows) TableRow(children: [for (final c in r) cell(c)]),
      ],
    );
  }
}

/// Muted small text.
class Muted extends StatelessWidget {
  final String text;
  final bool mono;
  const Muted(this.text, {super.key, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return mono
        ? Text(text, style: monoStyle(context, size: 11.5, color: theme.hintColor))
        : Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
  }
}

/// Mono text for table cells.
class Mono extends StatelessWidget {
  final String text;
  final Color? color;
  const Mono(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) => Text(text, style: monoStyle(context, size: 11.5, color: color));
}

/// A coloured callout box for derived diagnoses.
class Callout extends StatelessWidget {
  final Severity severity;
  final String title;
  final String? detail;
  const Callout({super.key, required this.severity, required this.title, this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = severityColor(context, severity);
    final icon = severityIcon(severity);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: c)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.bodySmall?.copyWith(color: c, fontWeight: FontWeight.w600)),
            if (detail != null && detail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(detail!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.8))),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Ready/total pill for section trailers.
class CountBadge extends StatelessWidget {
  final int ready;
  final int total;
  final String noun;
  const CountBadge({super.key, required this.ready, required this.total, this.noun = 'ready'});

  @override
  Widget build(BuildContext context) => StatusBadge('$ready/$total $noun',
      dense: true,
      severity: total == 0
          ? Severity.error
          : ready == total
              ? Severity.ok
              : ready == 0
                  ? Severity.error
                  : Severity.warn);
}

// ---------------------------------------------------------------------------
// Endpoint rows (shared by Service, EndpointSlice and Endpoints panels)

/// One backend address, normalised from an EndpointSlice endpoint or a
/// legacy Endpoints subset address.
class EndpointAddr {
  final String ip;
  final bool ready;
  final bool? serving;
  final bool terminating;
  final Json? targetRef;
  final String? nodeName;
  final String? zone;
  final String? hostname;
  final List<String> hints;
  const EndpointAddr({
    required this.ip,
    required this.ready,
    this.serving,
    this.terminating = false,
    this.targetRef,
    this.nodeName,
    this.zone,
    this.hostname,
    this.hints = const [],
  });

  /// One row per address of an EndpointSlice endpoint.
  static List<EndpointAddr> fromSliceEndpoint(Json e) {
    final cond = asMap(e['conditions']);
    // Per the API: a nil `ready` should be interpreted as true.
    final ready = cond['ready'] != false;
    final hints = [for (final z in asMapList(dig(e, ['hints', 'forZones']))) '${z['name']}'];
    return [
      for (final a in (e['addresses'] as List? ?? const []))
        EndpointAddr(
          ip: '$a',
          ready: ready,
          serving: cond['serving'] is bool ? cond['serving'] as bool : null,
          terminating: cond['terminating'] == true,
          targetRef: e['targetRef'] is Map ? asMap(e['targetRef']) : null,
          nodeName: e['nodeName'] as String?,
          zone: e['zone'] as String?,
          hostname: e['hostname'] as String?,
          hints: hints,
        ),
    ];
  }

  static List<EndpointAddr> fromSlices(List<Json> slices) =>
      [for (final s in slices) for (final e in asMapList(s['endpoints'])) ...fromSliceEndpoint(e)];

  static EndpointAddr fromLegacy(Json a, {required bool ready}) => EndpointAddr(
        ip: '${a['ip'] ?? ''}',
        ready: ready,
        targetRef: a['targetRef'] is Map ? asMap(a['targetRef']) : null,
        nodeName: a['nodeName'] as String?,
        hostname: a['hostname'] as String?,
      );
}

/// Addresses as compact rows, not-ready first: a state dot, the IP, what
/// backs it (pod and node links, zone) and its condition when not plainly
/// ready; copy on hover.
class EndpointList extends StatelessWidget {
  final List<EndpointAddr> addrs;
  final String? namespace;

  /// When set (headless services), show the per-pod DNS name for hostnames.
  final String? headlessDnsSuffix;
  const EndpointList(this.addrs, {super.key, this.namespace, this.headlessDnsSuffix});

  /// Not ready first, then terminating, then by IP.
  static List<EndpointAddr> ordered(List<EndpointAddr> addrs) => [...addrs]..sort((a, b) {
      int rank(EndpointAddr x) => !x.ready ? 0 : (x.terminating ? 1 : 2);
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.ip.compareTo(b.ip);
    });

  @override
  Widget build(BuildContext context) {
    if (addrs.isEmpty) return const Padding(padding: EdgeInsets.only(left: 4), child: Muted('No addresses'));
    return TrimmedRows([for (final a in ordered(addrs)) _row(context, a)], limit: 10);
  }

  Widget _row(BuildContext context, EndpointAddr a) {
    final theme = Theme.of(context);
    final sev = !a.ready ? Severity.error : (a.terminating ? Severity.warn : Severity.ok);
    final tr = a.targetRef;
    final state = [
      if (!a.ready) 'not ready',
      if (a.serving != null && a.serving != a.ready) a.serving! ? 'serving' : 'not serving',
      if (a.terminating) 'terminating',
    ].join(' · ');
    final dns = a.hostname != null && headlessDnsSuffix != null ? '${a.hostname}.$headlessDnsSuffix' : null;
    return CompactRow(
      key: ValueKey('endpoint-${a.ip}'),
      severity: sev,
      dotTooltip: state.isEmpty ? 'ready' : state,
      title: Row(children: [
        Text(a.ip, style: monoStyle(context, size: 12)),
        if (state.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(state, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, sev), fontWeight: FontWeight.w600)),
          ),
        ],
      ]),
      subtitle: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (tr != null)
          ResourceLink(
            ObjectRef.fromOwnerRef({...tr, 'apiVersion': tr['apiVersion'] ?? 'v1'}, namespace: namespace),
            label: tr['kind'] == 'Pod' ? '${tr['name'] ?? ''}' : '${tr['kind'] ?? ''}/${tr['name'] ?? ''}',
          )
        else
          const Text('no targetRef'),
        if (a.nodeName != null) ResourceLink(ObjectRef(kind: 'Node', name: a.nodeName!), label: a.nodeName),
        if (a.zone != null) Text(a.zone!),
        if (a.hints.isNotEmpty) Text('hints: ${a.hints.join(', ')}'),
        if (dns != null) Text(dns, style: monoStyle(context, size: 11, color: theme.hintColor)),
        if (a.hostname != null && dns == null) Text('hostname: ${a.hostname}'),
      ]),
      actions: [copyAction(context, a.ip), if (dns != null) copyAction(context, dns, tooltip: 'Copy $dns')],
    );
  }
}

/// Chips for EndpointSlice / Endpoints ports: `http 8080/TCP`.
class PortChips extends StatelessWidget {
  final List<Json> ports;
  const PortChips(this.ports, {super.key});

  @override
  Widget build(BuildContext context) {
    if (ports.isEmpty) return const Muted('all ports');
    return Wrap(spacing: 4, runSpacing: 4, children: [
      for (final p in ports)
        Chipish(text: [
          if ((p['name'] ?? '').toString().isNotEmpty) '${p['name']}',
          '${p['port'] ?? '*'}/${p['protocol'] ?? 'TCP'}',
          if (p['appProtocol'] != null) '(${p['appProtocol']})',
        ].join(' ')),
    ]);
  }
}

/// Minimal client-side label selector check for `k=v` maps (used for
/// counting / matching, not for querying).
bool labelsMatch(Json? labels, Json selector) {
  final l = labels ?? const {};
  return selector.entries.every((e) => l[e.key]?.toString() == e.value?.toString());
}
