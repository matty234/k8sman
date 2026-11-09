import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../panels/panel.dart';
import '../../state/log_dock.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart' show openUrl;

/// Kinds we can forward to, keyed by `group/Kind` → backend kind.
const portForwardKinds = {
  '/Pod': 'pod',
  '/Service': 'service',
  'apps/Deployment': 'deployment',
  'apps/StatefulSet': 'statefulset',
  'apps/DaemonSet': 'daemonset',
  'apps/ReplicaSet': 'replicaset',
};

/// A port offered in the dialog.
class ForwardablePort {
  /// What the backend expects: service port number, or container port number.
  final String value;
  final int number;
  final String description;
  const ForwardablePort(this.value, this.number, this.description);
}

/// Ports declared on the object (service ports, or container ports of the
/// pod / pod template).
List<ForwardablePort> forwardablePorts(PanelContext ctx) {
  final gk = ctx.type.gk;
  if (gk == '/Service') {
    return [
      for (final p in asMapList(ctx.spec['ports']))
        if ((p['protocol'] ?? 'TCP') == 'TCP')
          ForwardablePort('${p['port']}', (p['port'] as num).toInt(),
              '${p['name'] != null ? '${p['name']} · ' : ''}${p['port']} → ${p['targetPort'] ?? p['port']}'),
    ];
  }
  final podSpec = gk == '/Pod' ? ctx.spec : asMap(dig(ctx.object, ['spec', 'template', 'spec']));
  return [
    for (final c in asMapList(podSpec['containers']))
      for (final p in asMapList(c['ports']))
        if ((p['protocol'] ?? 'TCP') == 'TCP')
          ForwardablePort('${p['containerPort']}', (p['containerPort'] as num).toInt(),
              '${p['name'] != null ? '${p['name']} · ' : ''}${p['containerPort']} (${c['name']})'),
  ];
}

ResourceAction portForwardAction(PanelContext ctx) => ResourceAction(
      id: 'port-forward',
      label: 'Port forward',
      icon: Icons.swap_horiz,
      run: (c) => showPortForwardDialog(c, ctx),
    );

Future<PortForward?> showPortForwardDialog(BuildContext context, PanelContext ctx) async {
  final kind = portForwardKinds[ctx.type.gk];
  if (kind == null) return null;
  final pf = await showDialog<PortForward>(
    context: context,
    builder: (_) => _PortForwardDialog(ctx: ctx, kind: kind),
  );
  if (pf != null && context.mounted) {
    context.read<LogDock?>()?.notifyForwardStarted();
    if (pf.openInBrowser && pf.url != null) openUrl(pf.url!);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text('Forwarding ${pf.url ?? 'localhost:${pf.localPort}'} → ${pf.target}'),
      action: pf.url == null ? null : SnackBarAction(label: 'Open', onPressed: () => openUrl(pf.url!)),
      persist: false,
    ));
  }
  return pf;
}

class _PortForwardDialog extends StatefulWidget {
  final PanelContext ctx;
  final String kind;
  const _PortForwardDialog({required this.ctx, required this.kind});

  @override
  State<_PortForwardDialog> createState() => _PortForwardDialogState();
}

class _PortForwardDialogState extends State<_PortForwardDialog> {
  late final List<ForwardablePort> _ports = forwardablePorts(widget.ctx);
  late final _remote = TextEditingController(text: _ports.isNotEmpty ? _ports.first.value : '');
  late final _local = TextEditingController(text: _suggestLocal(_ports.isNotEmpty ? _ports.first.number : null));
  final _label = TextEditingController();
  bool _autoStart = true;
  bool _openInBrowser = false;
  bool _https = false;

  /// Not saved for restarts.
  bool _ephemeral = false;

  /// The user typed a local port, so suggestions leave it alone.
  bool _localEdited = false;
  bool _busy = false;
  String? _error;

  /// The local port is taken: offer to replace the forward holding it or to
  /// use another port.
  ApiException? _conflict;

  static String _suggestLocal(int? remote) => remote != null && remote >= 1024 ? '$remote' : '';

  @override
  void initState() {
    super.initState();
    if (_ports.isNotEmpty) _prefill(_ports.first.number);
  }

  /// Asks the backend for the local port to default to (the remote port when
  /// free, else the next free one) unless the user has chosen one.
  Future<void> _prefill(int remote) async {
    try {
      final p = await widget.ctx.api.freeForwardPort(remote);
      if (mounted && !_localEdited) setState(() => _local.text = '$p');
    } catch (_) {
      // Keep the local guess; the backend still picks a free port.
    }
  }

  @override
  void dispose() {
    _remote.dispose();
    _local.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _create({bool replace = false}) async {
    setState(() => (_busy = true, _error = null, _conflict = null));
    try {
      final pf = await widget.ctx.api.createPortForward(
        namespace: widget.ctx.namespace ?? '',
        kind: widget.kind,
        name: widget.ctx.name,
        port: _remote.text.trim(),
        localPort: int.tryParse(_local.text.trim()) ?? 0,
        autoStart: _autoStart && !_ephemeral,
        label: _label.text.trim().isEmpty ? null : _label.text.trim(),
        replace: replace,
        openInBrowser: _openInBrowser,
        https: _https,
        ephemeral: _ephemeral,
      );
      if (mounted) Navigator.pop(context, pf);
    } on ApiException catch (e) {
      setState(() => (_busy = false, e.isPortInUse ? _conflict = e : _error = e.message));
    } catch (e) {
      setState(() => (_busy = false, _error = '$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Port forward ${widget.ctx.type.kind.toLowerCase()}/${widget.ctx.name}'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_ports.isNotEmpty) ...[
            Text('Port', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in _ports)
                ChoiceChip(
                  label: Text(p.description),
                  selected: _remote.text == p.value,
                  onSelected: (_) {
                    setState(() {
                      _remote.text = p.value;
                      if (!_localEdited) _local.text = _suggestLocal(p.number);
                    });
                    _prefill(p.number);
                  },
                ),
            ]),
            const SizedBox(height: 12),
          ],
          Row(children: [
            Expanded(
              child: TextField(
                controller: _remote,
                decoration: InputDecoration(labelText: widget.kind == 'service' ? 'Service port' : 'Remote port (number or name)'),
                style: monoStyle(context),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Icon(Icons.arrow_back, size: 16)),
            Expanded(
              child: TextField(
                controller: _local,
                decoration: const InputDecoration(labelText: 'Local port', hintText: 'auto'),
                style: monoStyle(context),
                keyboardType: TextInputType.number,
                onChanged: (_) => _localEdited = true,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _label, decoration: const InputDecoration(labelText: 'Label (optional)', hintText: 'e.g. web UI')),
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _autoStart && !_ephemeral,
            onChanged: _ephemeral ? null : (v) => setState(() => _autoStart = v ?? false),
            title: const Text('Start automatically with k8sman'),
            subtitle: Text(
                widget.kind == 'pod'
                    ? 'Reconnects if the connection drops.'
                    : 'Follows a ready pod: reconnects to a new one if the pod is replaced.',
                style: theme.textTheme.bodySmall),
          ),
          CheckboxListTile(
            key: const ValueKey('pf-open-browser'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _openInBrowser,
            onChanged: (v) => setState(() => _openInBrowser = v ?? false),
            title: const Text('Open in browser when it starts'),
            subtitle: Text('Remembered for this forward.', style: theme.textTheme.bodySmall),
          ),
          CheckboxListTile(
            key: const ValueKey('pf-https'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _https,
            onChanged: (v) => setState(() => _https = v ?? false),
            title: const Text('Use https'),
          ),
          CheckboxListTile(
            key: const ValueKey('pf-ephemeral'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _ephemeral,
            onChanged: (v) => setState(() => _ephemeral = v ?? false),
            title: const Text("Don't remember this forward"),
            subtitle: Text('It is gone after k8sman restarts.', style: theme.textTheme.bodySmall),
          ),
          if (_conflict case final c?) _PortConflict(
            port: _local.text.trim(),
            conflict: c,
            onReplace: () => _create(replace: true),
            onUseOther: () {
              _local.text = '${c.suggestedPort}';
              _create();
            },
          ),
          if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy || _remote.text.trim().isEmpty ? null : _create, child: Text(_busy ? 'Starting…' : 'Start forwarding')),
      ],
    );
  }
}

/// "Port 8080 is used by X": replace it, or use the next free port.
class _PortConflict extends StatelessWidget {
  final String port;
  final ApiException conflict;
  final VoidCallback onReplace, onUseOther;
  const _PortConflict({required this.port, required this.conflict, required this.onReplace, required this.onUseOther});

  @override
  Widget build(BuildContext context) {
    final ours = (conflict.usedBy ?? '').isNotEmpty;
    final other = conflict.suggestedPort;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ours ? 'Port $port is used by ${conflict.usedBy}.' : 'Port $port is in use by another process.'),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          if (ours) OutlinedButton(onPressed: onReplace, child: const Text('Replace it')),
          if (other != null) OutlinedButton(onPressed: onUseOther, child: Text('Use $other instead')),
        ]),
      ]),
    );
  }
}
