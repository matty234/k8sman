import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../state/startup_gate.dart';
import '../../prometheus/prom_api.dart';
import '../../state/app_state.dart';
import '../../state/poller.dart';
import '../../util/k8s.dart';
import '../theme.dart';

/// Count of firing critical alerts for the nav's Alerts item. Polls every
/// [interval] while an Alertmanager exists; shows nothing otherwise.
class AlertsNavBadge extends StatefulWidget {
  final Duration interval;
  const AlertsNavBadge({super.key, this.interval = const Duration(seconds: 30)});

  @override
  State<AlertsNavBadge> createState() => _AlertsNavBadgeState();
}

class _AlertsNavBadgeState extends State<AlertsNavBadge> with PollingState {
  int _critical = 0;
  String? _context;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // First fetch once the first table has painted (see StartupGate).
    StartupGate.ready.then((_) => _poll());
    poll(widget.interval, _poll);
  }

  /// False when the fetch failed (the poll then backs off).
  Future<bool> _poll() async {
    if (!mounted || _busy) return true;
    final ApiClient api;
    try {
      api = context.read<ApiClient>();
    } catch (_) {
      return true; // no backend in this tree (tests)
    }
    _busy = true;
    var n = 0;
    var ok = true;
    try {
      final prom = PromApi.of(api);
      final status = await prom.cachedStatus();
      if (status?.defaultAlertmanager != null) n = (await prom.alerts()).summary.critical;
    } catch (_) {
      n = 0;
      ok = false;
    } finally {
      _busy = false;
    }
    if (mounted && n != _critical) setState(() => _critical = n);
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    // Re-poll right away after a context switch.
    final ctx = context.select<AppState, String>((a) => a.currentContext);
    if (_context != null && ctx != _context) scheduleMicrotask(_poll);
    _context = ctx;
    if (_critical == 0) return const SizedBox.shrink();
    final c = severityColor(context, Severity.error);
    return Tooltip(
      message: '$_critical critical alert${_critical == 1 ? '' : 's'} firing',
      child: Container(
        constraints: const BoxConstraints(minWidth: 16),
        height: 16,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: c.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)),
        child: Text('$_critical', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c)),
      ),
    );
  }
}
