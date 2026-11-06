import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../state/poller.dart';
import '../widgets/common.dart';
import 'overview_api.dart';
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

  Future<void> _refresh() async {
    final seq = ++_seq;
    final ns = _ns;
    setState(() => _loading = true);
    try {
      final data = await source.fetch(scope: ns);
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = data;
        _error = null;
        _updatedAt = DateTime.now();
        _loading = false;
        if (_filter != null && !data.categories.any((c) => c.id == _filter)) _filter = null;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
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
          child: Scrollbar(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                InventoryStrip(data: data),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  InlineMessage('Refresh failed: ${_errorText(_error!)}. Showing the last result.', isError: true),
                ],
                for (final e in data.errors.entries) ...[
                  const SizedBox(height: 8),
                  InlineMessage('Could not list ${e.key}: ${e.value}', icon: Icons.lock_outline),
                ],
                const SizedBox(height: 16),
                SummaryTiles(data: data, namespace: _ns, selected: _filter, onSelect: (id) => setState(() => _filter = _filter == id ? null : id)),
                const SizedBox(height: 16),
                DetailSection(
                  title: 'Issues',
                  icon: Icons.report_gmailerrorred,
                  trailing: _issuesTrailing(context, data, issues.length),
                  child: IssueList(
                    issues: issues,
                    onChanged: _refresh,
                    emptyText: _filter == null ? 'Nothing needs attention.' : 'No issues in this category.',
                  ),
                ),
                if (data.nodes.isNotEmpty)
                  DetailSection(
                    title: 'Nodes',
                    icon: Icons.dns_outlined,
                    trailing: Text(
                      '${data.count('nodes', 'ready')}/${data.count('nodes', 'total')} ready',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                    child: NodesStrip(nodes: data.nodes),
                  ),
                DetailSection(
                  title: 'Top warning events',
                  icon: Icons.notifications_active_outlined,
                  trailing: Text('last hour', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                  child: WarningEventList(reasons: data.topWarnings),
                ),
              ],
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
