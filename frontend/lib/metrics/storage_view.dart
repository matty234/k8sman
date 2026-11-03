import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../state/poller.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'kubelet_summary.dart' show KubeletSummary;
import 'cache.dart';
import 'quantity.dart';
import 'sortable_table.dart';
import 'volume_usage.dart';

/// One PVC row of the Storage tab.
class StorageRow {
  final String namespace;
  final String name;
  final String phase;
  final PvcUsage? usage;

  /// Kubelet-reported capacity, else the claim's provisioned size.
  final double? capacity;
  const StorageRow({required this.namespace, required this.name, required this.phase, this.usage, this.capacity});

  double? get frac => fraction(usage?.used, usage?.capacity ?? capacity);
}

/// Joins claims with usage keyed `namespace/claim` (pure, for tests).
List<StorageRow> joinStorage(List<Json> pvcs, Map<String, PvcUsage> usage) => [
  for (final p in pvcs)
    () {
      final ns = dig<String>(p, ['metadata', 'namespace']) ?? '';
      final name = dig<String>(p, ['metadata', 'name']) ?? '';
      final u = usage['$ns/$name'];
      return StorageRow(
        namespace: ns,
        name: name,
        phase: dig<String>(p, ['status', 'phase']) ?? 'Unknown',
        usage: u,
        capacity: u?.capacity ?? parseBytes(dig(p, ['status', 'capacity', 'storage'])),
      );
    }(),
];

/// Every PVC in scope with its usage, fullest first.
class StorageView extends StatefulWidget {
  final String? namespace;
  const StorageView({super.key, required this.namespace});

  @override
  State<StorageView> createState() => _StorageViewState();
}

class _StorageViewState extends State<StorageView> with AutomaticKeepAliveClientMixin, PollingState {
  List<StorageRow>? _rows;
  UsageSource? _source;
  String? _unavailable;
  Object? _error;

  ApiClient get _api => context.read<ApiClient>();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    poll(const Duration(seconds: 30), () async {
      await _load();
      return _error == null;
    });
  }

  Future<void> _load() async {
    try {
      final pvcsF = _api.items(const ResourceRef(resource: 'persistentvolumeclaims'), namespace: widget.namespace);
      var usage = await promPvcUsage(_api, namespace: widget.namespace);
      UsageSource? source = usage == null ? null : UsageSource.prometheus;
      String? unavailable;
      if (usage == null) {
        final s = await MetricsCache.of(_api).summary(widget.namespace);
        if (s.available) {
          usage = (await kubeletPvcUsage(_api, namespace: widget.namespace)) ?? const {};
          source = UsageSource.kubelet;
        } else {
          unavailable = _why(s);
        }
      }
      final pvcs = await pvcsF;
      if (!mounted) return;
      setState(() {
        _rows = joinStorage(pvcs, usage ?? const {});
        _source = source;
        _unavailable = unavailable;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static String _why(KubeletSummary s) => s.message ?? 'kubelet stats unavailable';

  void _open(StorageRow r) {
    final app = context.read<AppState>();
    final t = app.typeFor('', 'PersistentVolumeClaim');
    if (t != null) app.openDetail(DetailTarget(type: t, name: r.name, namespace: r.namespace));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final rows = _rows;
    if (rows == null) {
      if (_error != null) return Padding(padding: const EdgeInsets.all(16), child: InlineMessage('$_error', isError: true));
      return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final detail = context.watch<AppState>().detail;
    final mono = monoStyle(context, size: 11.5);
    Widget dim(String s) => Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint);
    final measured = rows.where((r) => r.usage != null).length;
    final sourceText = switch (_source) {
      UsageSource.prometheus => 'usage via Prometheus',
      UsageSource.kubelet => 'usage via kubelet stats',
      null => 'usage unavailable: ${_unavailable ?? 'no source'}',
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Text('Persistent volume claims', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Expanded(child: Text('${rows.length} · $measured measured', maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
            Tooltip(
              message: 'Kubelets only report volumes mounted by a running pod, so idle and unbound claims have no usage.',
              child: Text(sourceText, style: hint),
            ),
          ]),
        ),
        if (rows.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('No persistent volume claims', style: hint))
        else
          SortableTable<StorageRow>(
            rows: rows,
            initialSort: 3,
            initialAscending: false,
            limit: 100,
            onTap: _open,
            selected: (r) => detail?.type.kind == 'PersistentVolumeClaim' && detail?.name == r.name && detail?.namespace == r.namespace,
            columns: [
              MetricColumn(
                label: 'Claim',
                sortKey: (r) => '${r.namespace}/${r.name}',
                cell: (c, r) => Text.rich(
                  TextSpan(children: [
                    if (widget.namespace == null) TextSpan(text: '${r.namespace}/', style: TextStyle(color: theme.hintColor)),
                    TextSpan(text: r.name),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              MetricColumn(
                label: 'Used',
                width: 96,
                numeric: true,
                sortKey: (r) => r.usage?.used,
                cell: (c, r) => r.usage?.used != null
                    ? Text(formatBytes(r.usage!.used!), style: mono)
                    : dim(r.phase == 'Bound' ? 'not mounted' : r.phase.toLowerCase()),
              ),
              MetricColumn(
                label: 'Capacity',
                width: 80,
                numeric: true,
                hideBelow: 380,
                sortKey: (r) => r.capacity,
                cell: (c, r) => r.capacity == null ? dim('—') : Text(formatBytes(r.capacity!), style: mono),
              ),
              MetricColumn(
                label: 'Used %',
                width: 150,
                numeric: true,
                sortKey: (r) => r.frac,
                cell: (c, r) {
                  final f = r.frac;
                  if (f == null) return dim('—');
                  final sev = pvcSeverity(f);
                  return Row(children: [
                    Expanded(child: UsageBar(f, height: 6)),
                    SizedBox(
                      width: 40,
                      child: Text(
                        formatPercent(f),
                        textAlign: TextAlign.right,
                        style: mono.copyWith(color: sev == Severity.neutral ? null : severityColor(context, sev)),
                      ),
                    ),
                  ]);
                },
              ),
              MetricColumn(
                label: 'Inodes',
                width: 64,
                numeric: true,
                hideBelow: 560,
                tooltip: 'inodes used',
                sortKey: (r) => r.usage?.inodeFrac,
                cell: (c, r) {
                  final f = r.usage?.inodeFrac;
                  final sev = pvcSeverity(f);
                  return f == null
                      ? dim('—')
                      : Text(formatPercent(f), style: mono.copyWith(color: sev == Severity.neutral ? null : severityColor(context, sev)));
                },
              ),
            ],
          ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: InlineMessage('Refresh failed: $_error', isError: true)),
      ],
    );
  }
}
