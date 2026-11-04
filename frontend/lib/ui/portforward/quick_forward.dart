import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart' show openUrl;

/// Short-lived shared view of the backend's port-forwards, so a panel with
/// many ports makes one request, not one per port.
class _ForwardsCache {
  static Future<List<PortForward>>? _f;
  static DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<List<PortForward>> get(ApiClient api) {
    if (_f == null || DateTime.now().difference(_at) > const Duration(seconds: 3)) {
      _at = DateTime.now();
      _f = api.portForwards().catchError((Object _) => <PortForward>[]);
    }
    return _f!;
  }

  static void invalidate() => _f = null;
}

/// One-click port-forward next to a port in the Pod / Service panels.
/// Click → forwards immediately (same local port when free, else any free
/// port) and shows a snackbar with Open. Once forwarded it becomes a
/// `localhost:N` link. Hidden in read-only mode and for non-TCP ports.
class QuickForwardButton extends StatefulWidget {
  final ApiClient api;
  final AppState app;
  final String namespace;

  /// `pod` or `service` (backend port-forward kinds).
  final String kind;
  final String name;

  /// Remote port: the container port for pods, the service port for services.
  final String port;
  final String? protocol;
  const QuickForwardButton({
    super.key,
    required this.api,
    required this.app,
    required this.namespace,
    required this.kind,
    required this.name,
    required this.port,
    this.protocol,
  });

  @override
  State<QuickForwardButton> createState() => _QuickForwardButtonState();
}

class _QuickForwardButtonState extends State<QuickForwardButton> {
  PortForward? _active;
  bool _busy = false;

  bool _matches(PortForward f) =>
      f.namespace == widget.namespace && f.kind == widget.kind && f.name == widget.name && f.port == widget.port && f.state != 'stopped';

  @override
  void initState() {
    super.initState();
    _ForwardsCache.get(widget.api).then((fs) {
      if (!mounted) return;
      for (final f in fs) {
        if (_matches(f)) {
          setState(() => _active = f);
          break;
        }
      }
    });
  }

  String _url(PortForward f) => f.url ?? 'http://localhost:${f.localPort}';

  Future<void> _forward() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final f = await widget.api.createPortForward(namespace: widget.namespace, kind: widget.kind, name: widget.name, port: widget.port);
      _ForwardsCache.invalidate();
      if (!mounted) return;
      setState(() => _active = f);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Forwarding localhost:${f.localPort} → ${widget.kind}/${widget.name}:${widget.port}'),
          action: SnackBarAction(label: 'Open', onPressed: () => openUrl(_url(f))),
          persist: false,
        ),
      );
    } on ApiException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Port-forward failed: ${e.message}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final proto = (widget.protocol ?? 'TCP').toUpperCase();
    if (widget.app.readOnly || proto != 'TCP') return const SizedBox.shrink();
    final theme = Theme.of(context);
    final f = _active;
    if (f != null) {
      return Tooltip(
        message: 'Forwarded to ${_url(f)}. Click to open; manage it on the Port Forwards page.',
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => openUrl(_url(f)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text('localhost:${f.localPort}', style: monoStyle(context, size: 11, color: theme.colorScheme.primary)),
          ),
        ),
      );
    }
    return Tooltip(
      message: 'Port-forward ${widget.port} to localhost',
      child: InkWell(
        key: ValueKey('quick-forward-${widget.kind}-${widget.port}'),
        borderRadius: BorderRadius.circular(4),
        onTap: _busy ? null : _forward,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: _busy
              ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5))
              : Icon(Icons.swap_horiz, size: 15, color: theme.colorScheme.primary),
        ),
      ),
    );
  }
}
