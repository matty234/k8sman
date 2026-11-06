/// The GPUs page's table: one row per GPU node, with indented sub-rows per
/// device. Same look as the Nodes page (see ui/nodes/nodes_view.dart).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../metrics/quantity.dart';
import '../metrics/widgets.dart';
import '../prometheus/metric_history_chart.dart' show seriesColors;
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
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

/// Placeholder item: the single muted line of a node with no device stats.
class GpuNoStats {
  final GpuNode node;
  const GpuNoStats(this.node);
}

/// Column widths for a given list width (shared by header, node rows and
/// device rows). Columns drop in reverse priority as the width shrinks.
class GpuLayout {
  static const hPad = 16.0;
  static const chevronW = 22.0;
  static const indent = 24.0;
  static const nameMin = 200.0;

  static const allocW = 160.0, utilW = 190.0, statusW = 84.0, podsW = 160.0, modelW = 160.0, memW = 190.0, tempW = 120.0;

  final bool showUtil, showStatus, showPods, showModel, showMem, showTemp;
  const GpuLayout({this.showUtil = false, this.showStatus = false, this.showPods = false, this.showModel = false, this.showMem = false, this.showTemp = false});

  factory GpuLayout.forWidth(double width) {
    var room = width - 2 * hPad - chevronW - nameMin - allocW;
    bool take(double w) {
      if (room < w) return false;
      room -= w;
      return true;
    }

    // Priority: utilisation, status, pods, model, memory, temp / power.
    final util = take(utilW);
    final status = util && take(statusW);
    final pods = status && take(podsW);
    final model = pods && take(modelW);
    final mem = model && take(memW);
    final temp = mem && take(tempW);
    return GpuLayout(showUtil: util, showStatus: status, showPods: pods, showModel: model, showMem: mem, showTemp: temp);
  }
}

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
    Widget cell(String label, GpuSort? s) {
      if (s == null) return Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
      return Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: () => onSort(s),
        builder: (hovered) => Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(
              label,
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
        if (layout.showModel) _col(GpuLayout.modelW, cell('GPU', null)),
        _col(GpuLayout.allocW, cell('Allocated', GpuSort.allocated)),
        if (layout.showUtil) _col(GpuLayout.utilW, cell('Utilisation', GpuSort.util)),
        if (layout.showMem) _col(GpuLayout.memW, cell('Memory', null)),
        if (layout.showTemp) _col(GpuLayout.tempW, cell('Temp · Power', null)),
        if (layout.showPods) _col(GpuLayout.podsW, cell('Pods', null)),
        if (layout.showStatus) _col(GpuLayout.statusW, cell('Status', null)),
      ]),
    );
  }
}

Widget _col(double w, Widget child) => SizedBox(width: w, child: Padding(padding: const EdgeInsets.only(left: 12), child: Align(alignment: Alignment.centerLeft, child: child)));

Widget _dash(BuildContext context) => Text('–', style: TextStyle(color: Theme.of(context).hintColor));

Widget _meter({
  required double? used,
  required double? scale,
  required String valueText,
  required String Function(double) format,
  required String percentOf,
  double valueWidth = 0,
}) =>
    ResourceMeter(
      label: '',
      labelWidth: 0,
      valueWidth: valueWidth,
      compact: true,
      used: used,
      scale: scale,
      percentBase: scale,
      percentOf: percentOf,
      valueText: valueText,
      format: format,
    );

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
    final problem = !n.ready || n.devices.any((d) => d.health.isNotEmpty);
    final err = severityColor(context, Severity.error);
    final warn = severityColor(context, Severity.warn);
    final expandable = n.devices.isNotEmpty || n.count > 0;
    final avg = nodeAvgUtil(n);
    final mem = nodeMemory(n);
    final temps = [for (final d in n.devices) if (d.tempC != null) d.tempC!];
    final maxTemp = temps.isEmpty ? null : temps.reduce((a, b) => a > b ? a : b);
    final powers = [for (final d in n.devices) if (d.powerW != null) d.powerW!];
    final power = powers.isEmpty ? null : powers.reduce((a, b) => a + b);
    final extra = [
      for (final r in n.resources)
        if (r.name != 'nvidia.com/gpu' && r.capacity > 0) '${r.name.replaceFirst('nvidia.com/', '')} ${r.allocated}/${r.allocatable}',
    ];
    final statusBadge = !n.ready
        ? const StatusBadge('NotReady', severity: Severity.error, dense: true)
        : n.unschedulable
            ? const StatusBadge('Cordoned', severity: Severity.warn, dense: true)
            : const StatusBadge('Ready', dense: true);
    final secondLine = [
      if (!layout.showModel) gpuNodeLine(n),
      if (extra.isNotEmpty) extra.join(' · '),
    ].join(' · ');
    final podsText = n.pods.isEmpty ? null : n.pods.map((p) => '${p.namespace}/${p.name} (${p.gpus} GPU${p.gpus == 1 ? '' : 's'})').join('\n');

    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: type == null ? null : () => app.openDetail(DetailTarget(type: type, name: n.name)),
      builder: (hovered) => Container(
        height: 44,
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
            child: expandable
                ? InkResponse(
                    onTap: onToggle,
                    radius: 12,
                    child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 18, color: theme.hintColor),
                  )
                : null,
          ),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.memory, size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ),
                if (!layout.showStatus && (!n.ready || n.unschedulable)) ...[const SizedBox(width: 8), Flexible(child: statusBadge)],
                if (!n.monitored && inv.monitoring == GpuMonitoring.dcgm) ...[
                  const SizedBox(width: 8),
                  const Flexible(
                    child: Tooltip(
                      message: 'No DCGM exporter metrics map to this node, so there are no live GPU stats',
                      child: StatusBadge('No exporter', severity: Severity.warn, dense: true),
                    ),
                  ),
                ],
                if (n.idleAllocated > 0) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '${n.idleAllocated} allocated GPU${n.idleAllocated == 1 ? '' : 's'} idle for the last hour',
                    child: Icon(Icons.hourglass_empty, size: 14, color: warn),
                  ),
                ],
              ]),
              if (secondLine.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 20), child: Text(secondLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: info)),
            ]),
          ),
          if (layout.showModel)
            _col(
              GpuLayout.modelW,
              Tooltip(
                message: gpuNodeLine(n),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(n.productName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  Text('${n.count} × ${n.memoryMiB > 0 ? formatBytes(n.memoryMiB * 1024 * 1024) : 'GPU'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: info),
                ]),
              ),
            ),
          _col(
            GpuLayout.allocW,
            _meter(
              used: n.allocated.toDouble(),
              scale: n.allocatable > 0 ? n.allocatable.toDouble() : null,
              valueText: '${n.allocated} / ${n.allocatable}',
              format: (v) => v.toStringAsFixed(0),
              percentOf: 'allocatable${n.capacity > n.allocatable ? ' (of ${n.capacity})' : ''}',
              valueWidth: 44,
            ),
          ),
          if (layout.showUtil)
            _col(
              GpuLayout.utilW,
              avg == null
                  ? _dash(context)
                  : Padding(padding: const EdgeInsets.only(left: 50), child: _meter(used: avg, scale: 1, valueText: '', format: formatPercent, percentOf: 'the GPUs (average)')),
            ),
          if (layout.showMem)
            _col(
              GpuLayout.memW,
              mem == null
                  ? _dash(context)
                  : _meter(used: mem.$1, scale: mem.$2, valueText: formatBytes(mem.$1), format: (v) => formatBytes(v), percentOf: 'framebuffer', valueWidth: 70),
            ),
          if (layout.showTemp)
            _col(GpuLayout.tempW, maxTemp == null ? _dash(context) : Text('${formatTemp(maxTemp)}${power == null ? '' : ' · ${formatWatts(power)}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: info)),
          if (layout.showPods)
            _col(
              GpuLayout.podsW,
              podsText == null
                  ? Text('–', style: info)
                  : Tooltip(
                      message: podsText,
                      child: Row(children: [
                        Flexible(child: GpuPodLink(namespace: n.pods.first.namespace, name: n.pods.first.name)),
                        if (n.pods.length > 1) Text(' +${n.pods.length - 1}', style: info),
                      ]),
                    ),
            ),
          if (layout.showStatus) _col(GpuLayout.statusW, statusBadge),
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
    final info = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final tempSev = tempSeverity(d.tempC);
    final hasSpark = history != null && history!.length > 1;
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
              Flexible(child: Text(d.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.8)))),
              if (d.idle) ...[
                const SizedBox(width: 8),
                const Tooltip(message: 'Allocated, but averaged under 1% utilisation over the last hour', child: StatusBadge('Idle', severity: Severity.warn, dense: true)),
              ],
              for (final h in d.health) ...[
                const SizedBox(width: 6),
                Flexible(child: Tooltip(message: h, child: StatusBadge(GpuDeviceTile.shortHealth(h), severity: Severity.error, dense: true))),
              ],
            ]),
          ),
        ),
        if (layout.showModel) const SizedBox(width: GpuLayout.modelW),
        _col(GpuLayout.allocW, Text(d.pods.isEmpty ? '' : 'in use', style: info)),
        if (layout.showUtil)
          _col(
            GpuLayout.utilW,
            Row(children: [
              SizedBox(
                width: 44,
                height: 14,
                child: hasSpark ? Tooltip(message: 'Utilisation, last hour', child: Sparkline(history!, color: seriesColors(context).first)) : null,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: d.util == null ? _dash(context) : _meter(used: d.util, scale: 1, valueText: '', format: formatPercent, percentOf: 'the GPU'),
              ),
            ]),
          ),
        if (layout.showMem)
          _col(
            GpuLayout.memW,
            d.memUsed == null
                ? _dash(context)
                : _meter(used: d.memUsed, scale: d.memTotal, valueText: formatBytes(d.memUsed), format: (v) => formatBytes(v), percentOf: 'framebuffer', valueWidth: 70),
          ),
        if (layout.showTemp)
          _col(
            GpuLayout.tempW,
            Text.rich(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              TextSpan(children: [
                TextSpan(text: formatTemp(d.tempC), style: tempSev == Severity.neutral ? null : TextStyle(color: severityColor(context, tempSev))),
                TextSpan(text: ' · ${formatWatts(d.powerW)}'),
              ]),
              style: info,
            ),
          ),
        if (layout.showPods)
          _col(
            GpuLayout.podsW,
            d.pods.isEmpty
                ? Text('–', style: info)
                : Row(children: [
                    Flexible(child: GpuPodLink(namespace: d.pods.first.namespace, name: d.pods.first.name)),
                    if (d.pods.length > 1) Text(' +${d.pods.length - 1}', style: info),
                  ]),
          ),
        if (layout.showStatus) const SizedBox(width: GpuLayout.statusW),
      ]),
    );
  }
}

class GpuNoStatsRow extends StatelessWidget {
  final GpuNode n;
  const GpuNoStatsRow(this.n, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.only(left: GpuLayout.hPad + GpuLayout.chevronW + GpuLayout.indent, right: GpuLayout.hPad),
      alignment: Alignment.centerLeft,
      child: Text(
        '${n.count} × ${n.productName} · no live stats',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
    );
  }
}
