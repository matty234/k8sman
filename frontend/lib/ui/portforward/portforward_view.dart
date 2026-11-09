import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/poller.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../inspector/rows.dart' show RowDot, RevealOnHover;
import '../widgets/common.dart';
import '../widgets/context_menu.dart';

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
                    padding: EdgeInsets.all(docked ? 6 : 12),
                    itemCount: fs.length,
                    separatorBuilder: (_, _) => Divider(height: 1, thickness: 0.5, color: AppColors.of(context).separator),
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

  String get _stateLabel => switch (pf.state) {
        'active' => 'Active',
        'starting' => 'Connecting…',
        'reconnecting' => 'Reconnecting…',
        'error' => 'Failed',
        _ => 'Stopped',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final running = pf.state != 'stopped';
    final failed = pf.state == 'error';
    final url = pf.url ?? 'http://localhost:${pf.localPort}';
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final target = '${pf.namespace}/${pf.kind}/${pf.name}:${pf.port}';
    final via = pf.pod == null ? null : 'via ${pf.pod}${pf.remotePort != null ? ':${pf.remotePort}' : ''}';
    final reason = (pf.error ?? '').split('\n').first.trim();
    final Widget status = switch (pf.state) {
      'active' => pf.since == null ? const SizedBox.shrink() : AgeText(pf.since!.toIso8601String(), style: hint),
      'error' => Text(reason.isEmpty ? 'failed' : 'failed: $reason', style: hint, maxLines: 1, overflow: TextOverflow.ellipsis),
      _ => Text(_stateLabel.toLowerCase(), style: hint, maxLines: 1, overflow: TextOverflow.ellipsis),
    };
    final tip = [
      '$_stateLabel: localhost:${pf.localPort} → $target',
      ?via,
      if (pf.connections > 0) '${pf.connections} connections',
      if (pf.reconnects > 0) '${pf.reconnects} reconnects',
      if (otherContext) 'context ${pf.context}',
    ].join('\n');

    Future<void> menu(Offset pos) async {
      final v = await showContextMenuAt<String>(context, pos, [
        if (running) menuItem('open', Icons.open_in_new, 'Open in browser'),
        menuItem('copy', Icons.copy, 'Copy URL'),
        if (!readOnly) running ? menuItem('stop', Icons.stop_circle_outlined, 'Stop') : menuItem('start', Icons.play_circle_outline, 'Start'),
        menuItem('autostart', Icons.bolt, pf.autoStart ? 'Turn off autostart' : 'Start automatically'),
        menuItem('remove', Icons.delete_outline, 'Remove', danger: true),
      ]);
      if (!context.mounted) return;
      switch (v) {
        case 'open':
          openUrl(url);
        case 'copy':
          copyToClipboard(context, url);
        case 'stop':
          onStop();
        case 'start':
          onStart();
        case 'autostart':
          onAutoStart(!pf.autoStart);
        case 'remove':
          onDelete();
      }
    }

    Widget act(String tooltip, IconData icon, VoidCallback? onTap) => IconButton(
          tooltip: tooltip,
          iconSize: 15,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 26, height: 26),
          padding: EdgeInsets.zero,
          icon: Icon(icon),
          onPressed: onTap,
        );

    return Hoverable(
      onSecondaryTapUp: (d) => menu(d.globalPosition),
      cursor: SystemMouseCursors.basic,
      builder: (hovered) => Container(
        decoration: BoxDecoration(color: hovered ? colors.hover : null, borderRadius: BorderRadius.circular(5)),
        padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 34,
            child: Row(children: [
              RowDot(_sev, tooltip: _stateLabel),
              const SizedBox(width: 10),
              InkWell(
                onTap: running ? () => openUrl(url) : null,
                child: Text('localhost:${pf.localPort}',
                    style: monoStyle(context, size: 12.5, color: running ? theme.colorScheme.primary : theme.hintColor).copyWith(fontWeight: FontWeight.w600)),
              ),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('→', style: TextStyle(color: theme.hintColor))),
              Expanded(child: LayoutBuilder(builder: (context, box) => Row(children: [
              ConstrainedBox(
                // Leaves the rest to via/uptime, which ellipsise first.
                constraints: BoxConstraints(maxWidth: box.maxWidth * (MediaQuery.sizeOf(context).width >= 900 ? 0.45 : pf.state == 'active' ? 0.62 : 0.8)),
                child: Tooltip(
                  message: tip,
                  child: InkWell(
                    onTap: onOpenTarget,
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${pf.namespace}/', style: TextStyle(color: theme.hintColor)),
                        TextSpan(text: '${pf.kind}/${pf.name}:${pf.port}'),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(context, size: 12),
                    ),
                  ),
                ),
              ),
              if (MediaQuery.sizeOf(context).width >= 900 && pf.label != null) ...[const SizedBox(width: 8), Chipish(text: pf.label!)],
              if (MediaQuery.sizeOf(context).width >= 900 && pf.ephemeral) ...[const SizedBox(width: 8), const Chipish(text: 'not saved')],
              if (MediaQuery.sizeOf(context).width >= 900 && otherContext) ...[const SizedBox(width: 8), Chipish(text: pf.context)],
              // The via/uptime text takes what's left and ellipsises before
              // the target does.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    if (pf.state == 'active' && via != null) Flexible(child: Text('$via · ', style: hint, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Flexible(child: status),
                  ]),
                ),
              ),
              ]))),
              const SizedBox(width: 6),
              IconButton(
                key: ValueKey('autostart-${pf.id}'),
                tooltip: pf.autoStart ? 'Starts automatically when k8sman opens' : 'Start automatically when k8sman opens',
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                padding: EdgeInsets.zero,
                color: pf.autoStart ? theme.colorScheme.primary : theme.hintColor.withValues(alpha: 0.5),
                icon: const Icon(Icons.bolt),
                onPressed: () => onAutoStart(!pf.autoStart),
              ),
              // Too narrow for hover actions: the right-click menu has them.
              if (MediaQuery.sizeOf(context).width >= 560)
              for (final a in [
                act('Open in browser', Icons.open_in_new, running ? () => openUrl(url) : null),
                act('Copy URL', Icons.copy, () => copyToClipboard(context, url)),
                if (!readOnly) running ? act('Stop', Icons.stop_circle_outlined, onStop) : act('Start', Icons.play_circle_outline, onStart),
                act('Remove', Icons.delete_outline, onDelete),
              ])
                RevealOnHover(visible: hovered || failed, child: a),
            ]),
          ),
          if (failed && pf.error != null && pf.error!.isNotEmpty)
            Padding(padding: const EdgeInsets.fromLTRB(18, 0, 6, 6), child: ErrorNotice(pf.error!, title: 'Forward failed')),
        ]),
      ),
    );
  }
}

