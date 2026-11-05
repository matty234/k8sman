import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/log_dock.dart';
import '../../state/poller.dart';
import '../../state/startup_gate.dart';
import '../../util/k8s.dart';
import '../theme.dart';

/// Running port-forwards for the dock's Forwards tab: a count, amber while
/// any is starting or reconnecting, red if any failed. Nothing when none run.
/// Re-polls right away when [LogDock.forwardsPulse] fires (a forward started).
class ForwardsDockBadge extends StatefulWidget {
  final Duration interval;
  final double leading;
  const ForwardsDockBadge({super.key, this.interval = const Duration(seconds: 3), this.leading = 0});

  @override
  State<ForwardsDockBadge> createState() => _ForwardsDockBadgeState();
}

/// The badge's summary of [forwards]: (running, severity).
(int, Severity) forwardsSummary(List<PortForward> forwards) {
  var running = 0;
  var sev = Severity.ok;
  for (final f in forwards) {
    switch (f.state) {
      case 'error':
        running++;
        sev = Severity.error;
      case 'starting' || 'reconnecting':
        running++;
        if (sev != Severity.error) sev = Severity.warn;
      case 'active':
        running++;
    }
  }
  return (running, sev);
}

class _ForwardsDockBadgeState extends State<ForwardsDockBadge> with PollingState {
  (int, Severity) _summary = (0, Severity.ok);
  bool _busy = false;
  ValueNotifier<int>? _pulse;

  @override
  void initState() {
    super.initState();
    StartupGate.ready.then((_) => _poll());
    poll(widget.interval, _poll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = context.read<LogDock?>()?.forwardsPulse;
    if (p != _pulse) {
      _pulse?.removeListener(_onPulse);
      _pulse = p?..addListener(_onPulse);
    }
  }

  void _onPulse() => scheduleMicrotask(_poll);

  @override
  void dispose() {
    _pulse?.removeListener(_onPulse);
    super.dispose();
  }

  Future<bool> _poll() async {
    if (!mounted || _busy) return true;
    final ApiClient api;
    try {
      api = context.read<ApiClient>();
    } catch (_) {
      return true; // no backend in this tree (tests)
    }
    _busy = true;
    var ok = true;
    (int, Severity)? s;
    try {
      s = forwardsSummary(await api.portForwards());
    } catch (_) {
      ok = false;
    } finally {
      _busy = false;
    }
    if (mounted && s != null && s != _summary) setState(() => _summary = s!);
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final (n, sev) = _summary;
    if (n == 0) return const SizedBox.shrink();
    final c = sev == Severity.ok ? Theme.of(context).hintColor : severityColor(context, sev);
    return Padding(
      padding: EdgeInsets.only(left: widget.leading),
      child: Tooltip(
        message: '$n port-forward${n == 1 ? '' : 's'} running${sev == Severity.error ? ', some failing' : sev == Severity.warn ? ', some reconnecting' : ''}',
        child: Container(
          key: const ValueKey('forwards-badge'),
          constraints: const BoxConstraints(minWidth: 16),
          height: 16,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)),
          child: Text('$n', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c)),
        ),
      ),
    );
  }
}
