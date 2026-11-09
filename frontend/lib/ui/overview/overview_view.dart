import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../metrics/cache.dart';
import '../../metrics/metrics_api.dart';
import '../../state/poller.dart';
import '../widgets/common.dart';
import 'overview_api.dart';
import 'overview_cards.dart';
import 'overview_summary.dart';
import 'overview_widgets.dart';
import '../widgets/namespace_picker.dart';
import '../widgets/partial_banner.dart';
import '../../state/namespace_scope.dart';

/// Cluster health overview: what is crashlooping, stuck, failing or
/// unhealthy, grouped by owning workload, with quick fixes.
class OverviewView extends StatefulWidget {
  /// Override the data source (tests). Defaults to `OverviewApi(ApiClient)`.
  final OverviewApi? source;

  /// Auto-refresh period.
  final Duration interval;
  const OverviewView({super.key, this.source, this.interval = const Duration(seconds: 10)});

  @override
  State<OverviewView> createState() => _OverviewViewState();
}

class _OverviewViewState extends State<OverviewView> with PollingState {
  OverviewApi? _source;
  OverviewData? _data;
  Object? _error;
  bool _loading = false;
  bool _paused = false;
  DateTime? _updatedAt;
  String? _filter;
  late final Poll _poll;
  int _seq = 0;

  /// Namespace the current data (or in-flight request) is for.
  NamespaceScope _ns = NamespaceScope.all;

  bool _started = false;

  OverviewApi get source => _source ??= widget.source ?? OverviewApi(context.read<ApiClient>());

  @override
  void initState() {
    super.initState();
    _poll = poll(widget.interval, () async {
      if (!_paused && !_loading && mounted) await _refresh();
      return _error == null;
    });
  }

  /// The backend answers early with what it has and lists the rest in
  /// `pending`; while something is pending, fetch again after these delays
  /// (the last repeats) instead of waiting for the normal interval.
  static const _quickDelays = [Duration(milliseconds: 700), Duration(milliseconds: 1500), Duration(seconds: 3)];
  Timer? _quick;
  final _scroll = ScrollController();
  int _quickStep = 0;

  void _scheduleQuick(OverviewData data) {
    _quick?.cancel();
    _quick = null;
    if (data.pending.isEmpty) {
      _quickStep = 0;
      return;
    }
    final delay = _quickDelays[_quickStep.clamp(0, _quickDelays.length - 1)];
    _quickStep++;
    _quick = Timer(delay, () {
      if (mounted && !_paused && !_loading) _refresh();
    });
  }

  @override
  void dispose() {
    _quick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final seq = ++_seq;
    final ns = _ns;
    _quick?.cancel();
    setState(() => _loading = true);
    try {
      final data = await source.fetch(scope: ns);
      if (!mounted || seq != _seq) return;
      // The sidebar's problem badges count all namespaces.
      if (ns.isAll) OverviewSummary.of(source.api).feed(data, source.api.context);
      _scheduleQuick(data);
      setState(() {
        _data = data;
        _error = null;
        _updatedAt = DateTime.now();
        _loading = false;
        if (_filter != null && !data.categories.any((c) => c.id == _filter)) _filter = null;
      });
      if (ns.isAll && (data.capacity?.known ?? false)) _loadUsage(seq);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Live usage summed over nodes, from metrics-server (one request shared
  /// through [MetricsCache]); stays null when metrics aren't available.
  Usage? _usage;

  Future<void> _loadUsage(int seq) async {
    Usage? sum;
    try {
      final nodes = await MetricsCache.of(context.read<ApiClient>()).nodes();
      if (nodes.isNotEmpty) sum = nodes.map((n) => n.usage).reduce((a, b) => a + b);
    } catch (_) {
      // No metrics-server (or no access): requests alone are shown.
    }
    if (mounted && seq == _seq && (sum?.cpuMillis != _usage?.cpuMillis || sum?.memoryBytes != _usage?.memoryBytes)) {
      setState(() => _usage = sum);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      _started = true;
      // Overview has its own scope (independent of the table's namespace),
      // defaulting to all namespaces and remembered for the session.
      _ns = PageScope.of('overview');
      scheduleMicrotask(() {
        if (mounted) _refresh();
      });
    }
    final data = _data;
    final theme = Theme.of(context);

    final header = OverviewHeader(
      namespace: _ns,
      onNamespaceChanged: (ns) {
        if (ns == _ns) return;
        PageScope.set('overview', ns);
        setState(() {
          _ns = ns;
          _data = null; // don't show another scope's numbers
          _usage = null;
          _quickStep = 0;
        });
        _refresh();
      },
      updatedAt: _updatedAt,
      loading: _loading,
      paused: _paused,
      interval: widget.interval,
      onTogglePause: () => setState(() => _poll.paused = _paused = !_paused),
      onRefresh: _loading ? null : _refresh,
    );

    if (data == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const Divider(),
          Expanded(
            child: Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : SizedBox(
                      width: 460,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InlineMessage('Could not load the overview: ${_errorText(_error!)}', isError: true),
                          const SizedBox(height: 12),
                          FilledButton.tonal(onPressed: _refresh, child: const Text('Retry')),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      );
    }

    final issues = _filter == null ? data.issues : data.issues.where((i) => i.category == _filter).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const Divider(),
        if (data.partialErrors.isNotEmpty) PartialBanner(errors: data.partialErrors),
        Expanded(
          // Laid out in full (not a lazy ListView), so the scrollbar keeps
          // one size instead of re-estimating as sections scroll in.
          child: Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                StatBlocks(data: data, scope: _ns),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  InlineMessage('Refresh failed: ${_errorText(_error!)}. Showing the last result.', isError: true),
                ],
                for (final e in data.errors.entries) ...[
                  const SizedBox(height: 8),
                  InlineMessage('Could not list ${e.key}: ${e.value}', icon: Icons.lock_outline),
                ],
                // Requests only cover the pods in scope, so cluster capacity
                // is shown for all namespaces only.
                if (_ns.isAll && (data.isPending('nodes') || (data.capacity?.known ?? false))) ...[
                  const SizedBox(height: 10),
                  CapacityStrip(capacity: data.isPending('nodes') ? null : data.capacity, usage: _usage, nodes: data.nodes.length),
                ],
                const SizedBox(height: 16),
                AreaCards(data: data, scope: _ns, selected: _filter, checkedAt: _updatedAt, onSelect: (id) => setState(() => _filter = _filter == id ? null : id)),
                const SizedBox(height: 16),
                if (issues.isNotEmpty || _filter != null || data.loadingSections.isNotEmpty)
                  DetailSection(
                    title: 'Issues',
                    icon: Icons.report_gmailerrorred,
                    trailing: _issuesTrailing(context, data, issues.length),
                    child: IssueList(
                      issues: issues,
                      onChanged: _refresh,
                      emptyText: _filter == null ? 'Nothing needs attention.' : 'No issues in this category.',
                      loading: data.loadingSections.isNotEmpty,
                    ),
                  ),
                if (data.isPending('nodes'))
                  const DetailSection(title: 'Nodes', icon: Icons.dns_outlined, child: PendingRows())
                else if (data.nodes.isNotEmpty)
                  DetailSection(
                    title: 'Nodes',
                    icon: Icons.dns_outlined,
                    trailing: Text(
                      '${data.count('nodes', 'ready')}/${data.count('nodes', 'total')} ready',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                    child: NodeCards(nodes: data.nodes, showRequests: _ns.isAll),
                  ),
                DetailSection(
                  title: 'Top warning events',
                  icon: Icons.notifications_active_outlined,
                  trailing: Text('last hour', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                  child: data.isPending('events') ? const PendingRows(rows: 2) : WarningEventList(reasons: data.topWarnings),
                ),
              ]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _issuesTrailing(BuildContext context, OverviewData data, int shown) {
    final theme = Theme.of(context);
    final filter = _filter;
    if (filter == null) {
      return Text('${data.issues.length}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    }
    final label = data.categories.where((c) => c.id == filter).map((c) => c.label).firstOrNull ?? filter;
    return InputChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      label: Text('$label · $shown', style: theme.textTheme.labelSmall),
      onDeleted: () => setState(() => _filter = null),
      deleteButtonTooltipMessage: 'Show all issues',
      onPressed: () => setState(() => _filter = null),
    );
  }

  static String _errorText(Object e) => e is ApiException ? e.message : '$e';
}
