import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/poller.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Manage persistent port-forwards: live state, open/copy URL, autostart,
/// start/stop/remove. Polls the backend every 1.5s while visible. Lives in
/// the bottom dock's Forwards pane ([docked]).
class PortForwardView extends StatefulWidget {
  /// In the bottom dock: a one-line toolbar instead of the page header, and
  /// tighter spacing.
  final bool docked;
  const PortForwardView({super.key, this.docked = false});

  @override
  State<PortForwardView> createState() => _PortForwardViewState();
}

class _PortForwardViewState extends State<PortForwardView> with PollingState {
  List<PortForward>? _forwards;
  Object? _error;

  /// Forwards the user started that open the browser once they are active.
  final _openWhenActive = <String>{};
  bool _goneDismissed = false;

  ApiClient get _api => context.read<ApiClient>();

  @override
  void initState() {
    super.initState();
    _refresh();
    poll(const Duration(milliseconds: 1500), () async {
      await _refresh();
      return _error == null;
    });
  }

  Future<void> _refresh() async {
    try {
      final f = await _api.portForwards();
      for (final pf in f) {
        if (pf.state == 'active' && _openWhenActive.remove(pf.id)) openUrl(pf.url ?? 'http://localhost:${pf.localPort}');
      }
      if (mounted) setState(() => (_forwards = f, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _do(Future<void> Function() op) async {
    try {
      await op();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.message)));
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final fs = _forwards;
    final active = fs?.where((f) => f.state == 'active').length ?? 0;
    final help = Tooltip(
      message: 'Start a forward from a Pod, Service or workload: its inspector, or right-click its row',
      child: Icon(Icons.help_outline, size: 16, color: theme.hintColor),
    );
    final docked = widget.docked;
    final stopAll = !(fs?.any((f) => f.state != 'stopped') ?? false)
        ? const SizedBox.shrink()
        : TextButton.icon(
            key: const ValueKey('stop-all-forwards'),
            onPressed: () async {
              if (await stopAllForwards(context, forwards: fs)) await _refresh();
            },
            icon: const Icon(Icons.stop_circle_outlined, size: 16),
            label: const Text('Stop all'),
          );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (docked)
        SizedBox(
          height: 34,
          child: Row(children: [
            const SizedBox(width: 12),
            // Expanded, not Flexible + Spacer (they'd split the width and
            // centre the help icon).
            Expanded(child: fs == null ? const SizedBox() : Text('$active active · ${fs.length} saved', style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
            stopAll,
            help,
            const SizedBox(width: 12),
          ]),
        )
      else
        PageHeader(
          title: 'Port Forwards',
          subtitle: fs == null ? null : Text('$active active · ${fs.length} saved'),
          actions: [stopAll, help],
        ),
      if (_api.removedForwards > 0 && !_goneDismissed)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(children: [
            Expanded(
              child: Text(
                _api.removedForwards == 1
                    ? '1 saved forward was removed (its target is gone)'
                    : '${_api.removedForwards} saved forwards were removed (their targets are gone)',
                key: const ValueKey('forwards-removed-gone'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _goneDismissed = true),
            ),
          ]),
        ),
      docked ? Divider(height: 1, color: AppColors.of(context).separator) : const Divider(),
      if (_error != null && fs != null)
        Padding(padding: EdgeInsets.fromLTRB(docked ? 12 : 16, 10, docked ? 12 : 16, 2), child: ErrorNotice(_error!, title: 'Refresh failed', note: 'Showing the last result.', onRetry: _refresh)),
      Expanded(
        child: fs == null
            ? (_error != null ? LoadFailure(_error!, onRetry: _refresh) : const Center(child: CircularProgressIndicator()))
            : fs.isEmpty
                ? Center(
                    child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (!docked) ...[Icon(Icons.swap_horiz, size: 40, color: theme.hintColor), const SizedBox(height: 8)],
                      Text('No port-forwards yet', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text('Open a Pod, Service or Deployment and choose "Port forward".', style: TextStyle(color: theme.hintColor)),
                    ])),
                  )
                : ListView.separated(
                    padding: EdgeInsets.all(docked ? 8 : 12),
                    itemCount: fs.length,
                    separatorBuilder: (_, _) => SizedBox(height: docked ? 6 : 8),
                    itemBuilder: (context, i) => _ForwardCard(
                      pf: fs[i],
                      readOnly: app.readOnly,
                      otherContext: fs[i].context != app.currentContext,
                      onStart: () => _do(() async {
                        if (fs[i].openInBrowser) _openWhenActive.add(fs[i].id);
                        await _api.startPortForward(fs[i].id);
                      }),
                      onStop: () => _do(() => _api.stopPortForward(fs[i].id)),
                      onDelete: () => _do(() => _api.deletePortForward(fs[i].id)),
                      onAutoStart: (v) => _do(() => _api.updatePortForward(fs[i].id, autoStart: v)),
                      onOpenTarget: () {
                        final kinds = {'pod': ('', 'Pod'), 'service': ('', 'Service'), 'deployment': ('apps', 'Deployment'), 'statefulset': ('apps', 'StatefulSet'), 'daemonset': ('apps', 'DaemonSet'), 'replicaset': ('apps', 'ReplicaSet')};
                        final k = kinds[fs[i].kind];
                        final t = k == null ? null : app.typeFor(k.$1, k.$2);
                        if (t != null) app.openDetail(DetailTarget(type: t, name: fs[i].name, namespace: fs[i].namespace));
                      },
                    ),
                  ),
      ),
    ]);
  }
}

/// Asks "Stop N port forwards?" and stops them in one request. When running
/// forwards span several contexts it also offers all of them, not just the
/// current context's. Returns whether anything was stopped.
Future<bool> stopAllForwards(BuildContext context, {List<PortForward>? forwards}) async {
  final api = context.read<ApiClient>();
  final current = context.read<AppState>().currentContext;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final running = (forwards ?? await api.portForwards()).where((f) => f.state != 'stopped').toList();
    final here = running.where((f) => f.context == current).length;
    if (running.isEmpty) {
      messenger?.showSnackBar(const SnackBar(content: Text('No port forwards are running')));
      return false;
    }
    if (!context.mounted) return false;
    // null = cancelled, '' = every context.
    final scope = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String forwardsLabel(int n) => '$n port forward${n == 1 ? '' : 's'}';
        final several = running.length > here && here > 0;
        return AlertDialog(
          title: Text('Stop ${forwardsLabel(here > 0 ? here : running.length)}?'),
          content: Text(several
              ? 'This cluster has ${forwardsLabel(here)} running; ${forwardsLabel(running.length)} across all clusters. They stay saved and can be started again.'
              : 'They stay saved and can be started again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            if (several) TextButton(onPressed: () => Navigator.pop(ctx, ''), child: Text('All ${running.length}')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, here > 0 ? current : ''),
              child: Text(several ? 'This cluster ($here)' : 'Stop'),
            ),
          ],
        );
      },
    );
    if (scope == null) return false;
    final n = await api.stopAllPortForwards(context: scope.isEmpty ? null : scope);
    messenger?.showSnackBar(SnackBar(content: Text('Stopped $n port forward${n == 1 ? '' : 's'}')));
    return true;
  } on ApiException catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
}

class _ForwardCard extends StatelessWidget {
  final PortForward pf;
  final bool readOnly;
  final bool otherContext;
  final VoidCallback onStart, onStop, onDelete, onOpenTarget;
  final ValueChanged<bool> onAutoStart;
  const _ForwardCard({
    required this.pf,
    required this.readOnly,
    required this.otherContext,
    required this.onStart,
    required this.onStop,
    required this.onDelete,
    required this.onAutoStart,
    required this.onOpenTarget,
  });

  Severity get _sev => switch (pf.state) {
        'active' => Severity.ok,
        'starting' || 'reconnecting' => Severity.warn,
        'error' => Severity.error,
        _ => Severity.neutral,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = severityColor(context, _sev);
    final running = pf.state != 'stopped';
    final url = pf.url ?? 'http://localhost:${pf.localPort}';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 2, children: [
              InkWell(
                onTap: running ? () => openUrl(url) : null,
                child: Text('localhost:${pf.localPort}',
                    style: monoStyle(context, size: 13, color: running ? theme.colorScheme.primary : theme.hintColor).copyWith(fontWeight: FontWeight.w600)),
              ),
              Text('  →  ', style: TextStyle(color: theme.hintColor)),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: InkWell(
                  onTap: onOpenTarget,
                  child: Text('${pf.namespace}/${pf.kind}/${pf.name}:${pf.port}', overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12)),
                ),
              ),
              if (pf.label != null) ...[const SizedBox(width: 8), Chipish(text: pf.label!)],
              if (pf.ephemeral) ...[const SizedBox(width: 8), const Chipish(text: 'not saved')],
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 12, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              StatusBadge(pf.state, severity: _sev, dense: true),
              if (pf.pod != null) Text('via ${pf.pod}${pf.remotePort != null ? ':${pf.remotePort}' : ''}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              if (pf.since != null && pf.state == 'active') AgeText(pf.since!.toIso8601String(), suffix: ' up'),
              if (pf.connections > 0) Text('${pf.connections} conn', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              if (pf.reconnects > 0) Text('${pf.reconnects} reconnects', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              if (otherContext) Chipish(text: pf.context),
            ]),
            if (pf.error != null && pf.error!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                // Colour on the icon only: the text stays readable.
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1, right: 5),
                    child: Icon(severityIcon(pf.state == 'active' ? Severity.warn : Severity.error), size: 13, color: severityColor(context, pf.state == 'active' ? Severity.warn : Severity.error)),
                  ),
                  Expanded(child: Text(pf.error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                ]),
              ),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(tooltip: 'Open in browser', iconSize: 16, icon: const Icon(Icons.open_in_new), onPressed: running ? () => openUrl(url) : null),
            IconButton(tooltip: 'Copy URL', iconSize: 16, icon: const Icon(Icons.copy), onPressed: () => copyToClipboard(context, url)),
            if (!readOnly)
              running
                  ? IconButton(tooltip: 'Stop', iconSize: 18, icon: const Icon(Icons.stop_circle_outlined), onPressed: onStop)
                  : IconButton(tooltip: 'Start', iconSize: 18, icon: const Icon(Icons.play_circle_outline), onPressed: onStart),
            IconButton(tooltip: 'Remove', iconSize: 16, icon: const Icon(Icons.delete_outline), onPressed: onDelete),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Autostart', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            Transform.scale(scale: 0.75, child: Switch(value: pf.autoStart, onChanged: onAutoStart)),
          ]),
        ]),
      ]),
    );
  }
}
