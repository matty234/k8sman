import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';

Future<void> openUrl(String url) => launchUrl(Uri.parse(url));

/// Manage persistent port-forwards: live state, open/copy URL, autostart,
/// start/stop/remove. Polls the backend every 1.5s while visible.
class PortForwardView extends StatefulWidget {
  const PortForwardView({super.key});

  @override
  State<PortForwardView> createState() => _PortForwardViewState();
}

class _PortForwardViewState extends State<PortForwardView> {
  List<PortForward>? _forwards;
  String? _error;
  Timer? _poll;

  ApiClient get _api => context.read<ApiClient>();

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final f = await _api.portForwards();
      if (mounted) setState(() => (_forwards = f, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: 'Port Forwards',
        subtitle: fs == null ? null : Text('$active active · ${fs.length} saved'),
        actions: [
          Tooltip(
            message: 'Start a forward from a Pod, Service or workload in the sidebar',
            child: Icon(Icons.help_outline, size: 16, color: theme.hintColor),
          ),
        ],
      ),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: InlineMessage(_error!, isError: true)),
      const Divider(),
      Expanded(
        child: fs == null
            ? const Center(child: CircularProgressIndicator())
            : fs.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.swap_horiz, size: 40, color: theme.hintColor),
                      const SizedBox(height: 8),
                      Text('No port-forwards yet', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text('Open a Pod, Service or Deployment and choose "Port forward".', style: TextStyle(color: theme.hintColor)),
                    ]),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: fs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _ForwardCard(
                      pf: fs[i],
                      readOnly: app.readOnly,
                      otherContext: fs[i].context != app.currentContext,
                      onStart: () => _do(() => _api.startPortForward(fs[i].id)),
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
                child: Text(pf.error!, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, pf.state == 'active' ? Severity.warn : Severity.error))),
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
