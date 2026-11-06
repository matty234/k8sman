import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'cache.dart';
import 'custom_view.dart';
import 'external_view.dart';
import 'metrics_api.dart';
import 'network_view.dart';
import 'storage_view.dart';
import 'top_view.dart';
import 'widgets.dart';
import '../ui/widgets/namespace_picker.dart';
import '../state/poller.dart';

/// The Metrics page (MetricsModule, lib/modules): which metrics APIs are served, top
/// nodes/pods by usage, PVC storage usage, network throughput, and browsers
/// for custom and external metrics.
class MetricsPage extends StatefulWidget {
  const MetricsPage({super.key});

  @override
  State<MetricsPage> createState() => _MetricsPageState();
}

class _MetricsPageState extends State<MetricsPage> with PollingState {
  MetricsStatus? _status;
  Object? _statusError;

  /// Bumped by the refresh button; tabs reload when it changes.
  int _reload = 0;

  /// The page's own scope (independent of the table's namespace), defaulting
  /// to all namespaces and remembered for the session.
  String? _ns = PageScope.of('metrics');

  ApiClient get _api => context.read<ApiClient>();

  @override
  void initState() {
    super.initState();
    _loadStatus();
    poll(const Duration(seconds: 30), () async {
      await _loadStatus();
      return _statusError == null;
    });
  }

  Future<void> _loadStatus({bool force = false}) async {
    try {
      final s = await MetricsCache.of(_api).status(force: force);
      if (mounted) {
        setState(() {
          _status = s;
          _statusError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _statusError = e);
    }
  }

  void _refresh() {
    MetricsCache.of(_api).clear();
    _loadStatus(force: true);
    setState(() => _reload++);
  }

  void _setScope(String? ns) {
    if (ns == _ns) return;
    PageScope.set('metrics', ns);
    // The tabs are keyed by scope, so they drop the old data and refetch.
    setState(() => _ns = ns);
  }

  @override
  Widget build(BuildContext context) {
    final ns = _ns;
    return DefaultTabController(
      length: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Metrics',
            subtitle: PageScopePicker(value: ns, onChanged: _setScope),
            actions: [IconButton(tooltip: 'Refresh', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: _refresh)],
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 2),
            child: _statusError != null ? InlineMessage('$_statusError', isError: true) : MetricsStatusStrip(_status),
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Top', height: 34),
                Tab(text: 'Storage', height: 34),
                Tab(text: 'Network', height: 34),
                Tab(text: 'Custom metrics', height: 34),
                Tab(text: 'External metrics', height: 34),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                TopView(key: ValueKey('top-$ns-$_reload'), namespace: ns, status: _status?.resource),
                StorageView(key: ValueKey('storage-$ns-$_reload'), namespace: ns),
                NetworkView(key: ValueKey('network-$ns-$_reload'), namespace: ns),
                CustomMetricsView(key: ValueKey('custom-$ns-$_reload'), namespace: ns, status: _status?.custom),
                ExternalMetricsView(key: ValueKey('external-$ns-$_reload'), namespace: ns, status: _status?.external),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One chip per metrics API: available / not ready / not installed.
class MetricsStatusStrip extends StatelessWidget {
  final MetricsStatus? status;
  const MetricsStatusStrip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) return const SizedBox(height: 22);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _ApiChip(s.resource, label: 'Resource', missingHint: const InstallMetricsServerLink()),
        _ApiChip(s.custom, label: 'Custom'),
        _ApiChip(s.external, label: 'External'),
      ],
    );
  }
}

class _ApiChip extends StatelessWidget {
  final MetricsApiStatus s;
  final String label;
  final Widget? missingHint;
  const _ApiChip(this.s, {required this.label, this.missingHint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final (IconData icon, Color color, String state) = switch (s.state) {
      MetricsState.available => (Icons.check_circle_outline, theme.colorScheme.onSurface.withValues(alpha: 0.7), 'available'),
      MetricsState.notReady => (Icons.hourglass_bottom, severityColor(context, Severity.warn), 'not ready'),
      MetricsState.notInstalled => (Icons.remove_circle_outline, theme.hintColor, 'not installed'),
      MetricsState.unknown => (Icons.help_outline, theme.hintColor, 'unknown'),
    };
    final tip = [
      '${s.group}${s.version != null ? '/${s.version}' : ''}',
      if (s.service != null) 'served by ${s.service}',
      if (s.reason != null && s.reason != 'Passed') s.reason!,
      if (s.message != null && s.message != 'all checks passed') s.message!,
    ].join('\n');
    return Tooltip(
      message: tip,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Text(label, style: small?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 5),
            Text(s.group, style: monoStyle(context, size: 10.5, color: theme.hintColor)),
            const SizedBox(width: 6),
            Text(state, style: hint?.copyWith(color: s.state == MetricsState.notReady ? color : null)),
            if (s.state == MetricsState.notInstalled && missingHint != null) ...[Text(' · ', style: hint), missingHint!],
          ],
        ),
      ),
    );
  }
}

/// Shown in a tab whose API isn't served.
class ApiMissing extends StatelessWidget {
  final MetricsApiStatus? status;
  final String what;
  final String howTo;
  const ApiMissing({super.key, required this.status, required this.what, required this.howTo});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final notReady = s?.state == MetricsState.notReady;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(notReady ? '${s!.group} is installed but not ready yet' : '$what is not available', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            notReady ? [if (s!.service != null) 'Backed by ${s.service}.', s.reason, s.message].whereType<String>().join(' ') : howTo,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}
