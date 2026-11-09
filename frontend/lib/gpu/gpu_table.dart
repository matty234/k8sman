/// The GPUs page's table: one row per GPU node, with indented sub-rows per
/// device. Same look as the Nodes page (see ui/nodes/nodes_view.dart): a
/// status dot and the name over a meta line, usage cells in the
/// UsageCell idiom (value, thin bar, percentage), "—" for no value.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../metrics/quantity.dart';
import '../metrics/quantity_cell.dart';
import '../prometheus/metric_history_chart.dart' show seriesColors;
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../ui/widgets/editorial.dart';
import '../util/k8s.dart';
import 'gpu_api.dart';
import 'gpu_widgets.dart';

enum GpuSort { name, allocated, util }

/// Mean utilisation (0..1) over the devices that report it.
double? nodeAvgUtil(GpuNode n) {
  final v = [for (final d in n.devices) if (d.util != null) d.util!];
  return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
}

/// (used, total) framebuffer bytes summed over the devices that report it.
(double, double)? nodeMemory(GpuNode n) {
  var used = 0.0, total = 0.0;
  var any = false;
  for (final d in n.devices) {
    if (d.memUsed == null || d.memTotal == null) continue;
    any = true;
    used += d.memUsed!;
    total += d.memTotal!;
  }
  return any ? (used, total) : null;
}

double _allocFrac(GpuNode n) => n.allocatable > 0 ? n.allocated / n.allocatable : 0;

List<GpuNode> sortGpuNodes(List<GpuNode> nodes, GpuSort by, bool ascending) {
  int key(GpuNode a, GpuNode b) => switch (by) {
        GpuSort.name => a.name.compareTo(b.name),
        GpuSort.allocated => _allocFrac(a).compareTo(_allocFrac(b)),
        GpuSort.util => (nodeAvgUtil(a) ?? -1).compareTo(nodeAvgUtil(b) ?? -1),
      };
  final dir = ascending ? 1 : -1;
  return [...nodes]..sort((a, b) {
      final k = key(a, b);
      return k != 0 ? k * dir : a.name.compareTo(b.name);
    });
}

/// Column widths for a given list width (shared by header, node rows and
/// device rows). Allocated always shows; the rest drop in reverse priority
/// as the width shrinks: utilisation, pods, driver, memory, temperature.
class GpuLayout {
  static const hPad = 16.0;
  static const chevronW = 22.0;
  static const indent = 24.0;
  static const gap = 12.0;

  /// Room the name keeps for its meta line (GPU model and memory) before
  /// columns are added.
  static const nameMin = 300.0;

  static const driverW = 92.0, usageW = 156.0, tempW = 104.0, podsW = 150.0;

  final bool showUtil, showPods, showDriver, showMem, showTemp;
  const GpuLayout({this.showUtil = false, this.showPods = false, this.showDriver = false, this.showMem = false, this.showTemp = false});

  factory GpuLayout.forWidth(double width) {
    var room = width - 2 * hPad - chevronW - nameMin - (usageW + gap);
    bool take(double w) {
      if (room < w + gap) return false;
      room -= w + gap;
      return true;
    }

    final util = take(usageW);
    final pods = util && take(podsW);
    final driver = pods && take(driverW);
    final mem = driver && take(usageW);
    final temp = mem && take(tempW);
    return GpuLayout(showUtil: util, showPods: pods, showDriver: driver, showMem: mem, showTemp: temp);
  }
}

/// A fixed-width column with the gap before it.
Widget _col(double w, Widget? child) =>
    SizedBox(width: w + GpuLayout.gap, child: Padding(padding: const EdgeInsets.only(left: GpuLayout.gap), child: Align(alignment: Alignment.centerLeft, child: child)));

TextStyle? _cellStyle(BuildContext context) => Theme.of(context).textTheme.bodySmall?.copyWith(fontFeatures: tabularFigures);

/// The one empty state of a cell: a faint dash.
Widget _none(BuildContext context) => Text('—', style: _cellStyle(context)?.copyWith(color: AppColors.of(context).faint));

class GpuHeaderRow extends StatelessWidget {
  final GpuLayout layout;
  final GpuSort sort;
  final bool ascending;
  final ValueChanged<GpuSort> onSort;
  const GpuHeaderRow({super.key, required this.layout, required this.sort, required this.ascending, required this.onSort});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(color: theme.hintColor);
    Widget cell(String label, [GpuSort? s]) {
      if (s == null) return Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
      return Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: () => onSort(s),
        builder: (hovered) => Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(color: hovered || sort == s ? theme.colorScheme.onSurface : null, fontWeight: sort == s ? FontWeight.w600 : null),
            ),
          ),
          if (sort == s) ...[
            const SizedBox(width: 2),
            Icon(ascending ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 14, color: theme.hintColor),
          ],
        ]),
      );
    }

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: GpuLayout.hPad),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.of(context).separator))),
      child: Row(children: [
        const SizedBox(width: GpuLayout.chevronW),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: cell('Node', GpuSort.name))),
        if (layout.showDriver) _col(GpuLayout.driverW, cell('Driver')),
        _col(GpuLayout.usageW, cell('Allocated', GpuSort.allocated)),
        if (layout.showUtil) _col(GpuLayout.usageW, cell('Utilisation', GpuSort.util)),
        if (layout.showMem) _col(GpuLayout.usageW, cell('Memory')),
        if (layout.showTemp) _col(GpuLayout.tempW, cell('Temp · Power')),
        if (layout.showPods) _col(GpuLayout.podsW, cell('Pods')),
      ]),
    );
  }
}

/// A usage cell like [UsageCell]: [lead] (the value) in a right-aligned
/// slot [leadW] wide on every row of the column, a thin bar for [frac] (or
/// [chart], a sparkline, in the bar's place) and the percentage. Narrower
/// than [usageBarMinWidth] it keeps only the lead, else the percentage.
class _Meter extends StatelessWidget {
  final Widget? lead;
  final double leadW;
  final double? frac;
  final Widget? chart;
  final String? tooltip;
  const _Meter({this.lead, required this.leadW, required this.frac, this.chart, this.tooltip});

  static const _pctW = 38.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = _cellStyle(context);
    final f = frac;
    final pct = f == null ? null : Text(formatPercent(f), textAlign: TextAlign.right, maxLines: 1, style: style?.copyWith(color: theme.hintColor));
    final cell = LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < usageBarMinWidth) return Align(alignment: Alignment.centerLeft, child: lead ?? pct);
      return Row(children: [
        SizedBox(width: leadW, child: Align(alignment: Alignment.centerRight, child: lead)),
        const SizedBox(width: 6),
        Expanded(child: chart ?? (f == null ? const SizedBox.shrink() : UsageBar(frac: f, color: theme.colorScheme.onSurface.withValues(alpha: 0.42)))),
        const SizedBox(width: 6),
        SizedBox(width: _pctW, child: pct),
      ]);
    });
    return tooltip == null ? cell : Tooltip(message: tooltip, waitDuration: const Duration(milliseconds: 500), child: cell);
  }
}

/// Lead widths, per column, so bars line up down it.
const _allocLeadW = 40.0, _utilLeadW = 40.0, _memLeadW = 56.0;

/// The first pod as a link, "+N" for the rest (all of them in a tooltip).
Widget _podsCell(BuildContext context, List<GpuPodRef> pods, {bool counts = false}) {
  if (pods.isEmpty) return _none(context);
  final theme = Theme.of(context);
  final all = pods.map((p) => '${p.namespace}/${p.name}${counts ? ' (${p.gpus} GPU${p.gpus == 1 ? '' : 's'})' : ''}').join('\n');
  return Row(children: [
    Flexible(child: GpuPodLink(namespace: pods.first.namespace, name: pods.first.name, compact: true)),
    if (pods.length > 1)
      Tooltip(
        message: all,
        child: Text('  +${pods.length - 1}', style: _cellStyle(context)?.copyWith(color: theme.hintColor)),
      ),
  ]);
}

class GpuNodeRow extends StatelessWidget {
  final GpuNode n;
  final GpuInventory inv;
  final GpuLayout layout;
  final bool expanded;
  final VoidCallback onToggle;
  const GpuNodeRow(this.n, {super.key, required this.inv, required this.layout, required this.expanded, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final app = context.read<AppState>();
    final type = context.select<AppState, ResourceType?>((a) => a.typeFor('', 'Node'));
    final selected = context.select<AppState, bool>((a) => a.detail?.type == type && a.detail?.name == n.name);
    final info = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final style = _cellStyle(context);
    final problem = !n.ready || n.devices.any((d) => d.health.isNotEmpty);
    final err = severityColor(context, Severity.error);
    final warn = severityColor(context, Severity.warn);
    final noExporter = !n.monitored && inv.monitoring == GpuMonitoring.dcgm;
    final sev = problem ? Severity.error : (n.unschedulable || noExporter || n.idleAllocated > 0 ? Severity.warn : Severity.ok);
    final avg = nodeAvgUtil(n);
    final mem = nodeMemory(n);
    final temps = [for (final d in n.devices) if (d.tempC != null) d.tempC!];
    final maxTemp = temps.isEmpty ? null : temps.reduce((a, b) => a > b ? a : b);
    final powers = [for (final d in n.devices) if (d.powerW != null) d.powerW!];
    final power = powers.isEmpty ? null : powers.reduce((a, b) => a + b);

    // The meta lines: what the GPUs are, then (without a Driver column) the
    // driver on a line of its own, so neither cuts the other off. Every
    // fact is also in the tooltip, one per line.
    final memory = n.memoryMiB > 0 ? formatBytes(n.memoryMiB * 1024 * 1024) : null;
    final extra = [
      for (final r in n.resources)
        if (r.name != 'nvidia.com/gpu' && r.capacity > 0) '${r.name.replaceFirst('nvidia.com/', '')} ${r.allocated}/${r.allocatable}',
    ];
    final modelLine = ['${n.count} × ${n.productName}', ?memory, ...gpuSharing(n), ...extra].join(' · ');
    final driverLine = gpuDriverLine(n);
    final metaLines = [modelLine, if (!layout.showDriver && driverLine.isNotEmpty) driverLine];
    final facts = [
      '${n.count} × ${n.productName}${memory == null ? '' : ', $memory each'}',
      if (driverLine.isNotEmpty) driverLine.replaceFirst('driver', 'Driver'),
      ...gpuSharing(n),
      for (final e in extra) '$e allocated',
    ].join('\n');
    final lineHeight = (TextPainter(text: TextSpan(text: 'x', style: info), textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))..layout()).height;

    Widget chip(String text, Severity severity, {String? tooltip}) {
      final c = StatusBadge(text, severity: severity, dense: true);
      return Padding(padding: const EdgeInsets.only(left: 8), child: tooltip == null ? c : Tooltip(message: tooltip, child: c));
    }

    const noExporterTip = 'No DCGM exporter metrics map to this node, so there are no live GPU stats';
    final expandable = n.devices.isNotEmpty;

    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: type == null ? null : () => app.openDetail(DetailTarget(type: type, name: n.name)),
      builder: (hovered) => Container(
        height: 44 + (metaLines.length - 1) * lineHeight,
        margin: const EdgeInsets.fromLTRB(6, 2, 6, 0),
        padding: const EdgeInsets.only(left: GpuLayout.hPad - 6, right: GpuLayout.hPad - 6),
        decoration: BoxDecoration(
          color: selected
              ? colors.selection
              : hovered
                  ? colors.hover
                  : (problem ? err.withValues(alpha: 0.06) : null),
          border: problem ? Border(left: BorderSide(color: err, width: 3)) : null,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(children: [
          SizedBox(
            width: GpuLayout.chevronW,
            child: !expandable
                ? null
                : Padding(
                    // Line up with the name, not the middle of the lines.
                    padding: EdgeInsets.only(bottom: metaLines.length * lineHeight),
                    child: InkResponse(
                      onTap: onToggle,
                      radius: 12,
                      child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 18, color: theme.hintColor),
                    ),
                  ),
          ),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: severityColor(context, sev), shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Flexible(
                  flex: 3,
                  child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ),
                Flexible(
                  flex: 2,
                  child: ClipRect(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: Row(children: [
                        if (!n.ready) chip('NotReady', Severity.error),
                        if (n.unschedulable) chip('Cordoned', Severity.warn),
                        // With a Utilisation column the cell says so instead.
                        if (noExporter && !layout.showUtil) chip('No exporter', Severity.warn, tooltip: noExporterTip),
                        if (n.idleAllocated > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Tooltip(
                              message: '${n.idleAllocated} allocated GPU${n.idleAllocated == 1 ? '' : 's'} idle for the last hour',
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.hourglass_empty, size: 12, color: warn),
                                const SizedBox(width: 2),
                                Text('${n.idleAllocated} idle', style: style?.copyWith(color: warn)),
                              ]),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
              ]),
              Tooltip(
                message: facts,
                waitDuration: const Duration(milliseconds: 500),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final line in metaLines)
                    Padding(
                      padding: const EdgeInsets.only(left: 15),
                      child: Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: info),
                    ),
                ]),
              ),
            ]),
          ),
          if (layout.showDriver)
            _col(
              GpuLayout.driverW,
              n.driverVersion == null && n.cudaVersion == null
                  ? _none(context)
                  : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(n.driverVersion ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                      if (n.cudaVersion != null) Text('CUDA ${n.cudaVersion}', maxLines: 1, overflow: TextOverflow.ellipsis, style: info),
                    ]),
            ),
          _col(
            GpuLayout.usageW,
            _Meter(
              leadW: _allocLeadW,
              lead: Text('${n.allocated} / ${n.allocatable}', maxLines: 1, style: style),
              frac: n.allocatable > 0 ? n.allocated / n.allocatable : null,
              tooltip: '${n.allocated} of ${n.allocatable} allocatable GPU${n.allocatable == 1 ? '' : 's'} requested by pods'
                  '${n.capacity > n.allocatable ? ' (capacity ${n.capacity})' : ''}',
            ),
          ),
          if (layout.showUtil)
            _col(
              GpuLayout.usageW,
              avg != null
                  ? _Meter(leadW: _utilLeadW, frac: avg, tooltip: 'Average across ${n.devices.where((d) => d.util != null).length} GPUs')
                  : noExporter
                      ? Tooltip(message: noExporterTip, child: Text('No exporter', maxLines: 1, overflow: TextOverflow.ellipsis, style: style?.copyWith(color: warn)))
                      : _none(context),
            ),
          if (layout.showMem)
            _col(
              GpuLayout.usageW,
              mem == null
                  ? _none(context)
                  : _Meter(
                      leadW: _memLeadW,
                      lead: Text(formatBytes(mem.$1), maxLines: 1, style: style),
                      frac: mem.$2 > 0 ? mem.$1 / mem.$2 : null,
                      tooltip: '${formatBytes(mem.$1)} of ${formatBytes(mem.$2)} framebuffer',
                    ),
            ),
          if (layout.showTemp)
            _col(GpuLayout.tempW, maxTemp == null ? _none(context) : Text('${formatTemp(maxTemp)} · ${formatWatts(power)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
          if (layout.showPods) _col(GpuLayout.podsW, _podsCell(context, n.pods, counts: true)),
        ]),
      ),
    );
  }
}

class GpuDeviceRow extends StatelessWidget {
  final GpuDevice d;
  final GpuLayout layout;
  final List<double>? history;
  const GpuDeviceRow(this.d, {super.key, required this.layout, this.history});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final style = _cellStyle(context);
    final tempSev = tempSeverity(d.tempC);
    final hasSpark = history != null && history!.length > 1;
    final sev = d.health.isNotEmpty ? Severity.error : (d.idle ? Severity.warn : Severity.ok);
    // What is wrong, as quiet coloured text (the dot carries the severity).
    final notes = [
      if (d.idle) ('Idle', 'Allocated, but averaged under 1% utilisation over the last hour', Severity.warn),
      for (final h in d.health) (GpuDeviceTile.shortHealth(h), h, Severity.error),
    ];
    return Container(
      height: 30,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      padding: const EdgeInsets.only(left: GpuLayout.hPad - 6, right: GpuLayout.hPad - 6),
      child: Row(children: [
        const SizedBox(width: GpuLayout.chevronW),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: GpuLayout.indent),
            child: Row(children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: severityColor(context, sev), shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(d.label, maxLines: 1, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.85))),
              // Without a Pods column, the pod rides along the name.
              if (!layout.showPods && d.pods.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(child: Text(d.pods.map((p) => p.name).join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint))),
              ],
              for (final (i, (text, tip, s)) in notes.indexed) ...[
                if (i == 0) const SizedBox(width: 8) else Text(' · ', style: theme.textTheme.bodySmall?.copyWith(color: colors.faint)),
                Flexible(
                  child: Tooltip(
                    message: tip,
                    child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, s))),
                  ),
                ),
              ],
            ]),
          ),
        ),
        if (layout.showDriver) _col(GpuLayout.driverW, null),
        _col(GpuLayout.usageW, null),
        if (layout.showUtil)
          _col(
            GpuLayout.usageW,
            d.util == null
                ? _none(context)
                : _Meter(
                    leadW: _utilLeadW,
                    // The last hour's sparkline in place of the bar, not beside it.
                    chart: hasSpark ? Tooltip(message: 'Utilisation, last hour', child: SizedBox(height: 14, child: Sparkline(history!, color: seriesColors(context).first))) : null,
                    frac: d.util,
                  ),
          ),
        if (layout.showMem)
          _col(
            GpuLayout.usageW,
            d.memUsed == null
                ? _none(context)
                : _Meter(
                    leadW: _memLeadW,
                    lead: Text(formatBytes(d.memUsed), maxLines: 1, style: style),
                    frac: d.memTotal == null || d.memTotal! <= 0 ? null : d.memUsed! / d.memTotal!,
                    tooltip: '${formatBytes(d.memUsed)} of ${formatBytes(d.memTotal)} framebuffer',
                  ),
          ),
        if (layout.showTemp)
          _col(
            GpuLayout.tempW,
            d.tempC == null && d.powerW == null
                ? _none(context)
                : Text.rich(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    TextSpan(children: [
                      TextSpan(text: formatTemp(d.tempC), style: tempSev == Severity.neutral ? null : TextStyle(color: severityColor(context, tempSev))),
                      TextSpan(text: ' · ${formatWatts(d.powerW)}'),
                    ]),
                    style: style,
                  ),
          ),
        if (layout.showPods) _col(GpuLayout.podsW, _podsCell(context, d.pods)),
      ]),
    );
  }
}
