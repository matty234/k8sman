import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../util/k8s.dart';
import '../theme.dart';

/// Drains [node] like `kubectl drain --ignore-daemonsets`: shows the plan
/// (pods to evict, what's skipped, what blocks it) for the chosen options,
/// then cordons the node and evicts. Returns the result, or null if
/// cancelled.
Future<DrainResult?> showDrainDialog(BuildContext context, String node) async {
  final result = await showDialog<DrainResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Provider<ApiClient>.value(value: context.read<ApiClient>(), child: _DrainDialog(node: node)),
  );
  if (result != null && result.error == null && context.mounted) {
    final n = result.evicted.length;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Drained ${result.node}: evicted $n pod${n == 1 ? '' : 's'}')));
  }
  return result;
}

class _DrainDialog extends StatefulWidget {
  final String node;
  const _DrainDialog({required this.node});

  @override
  State<_DrainDialog> createState() => _DrainDialogState();
}

class _DrainDialogState extends State<_DrainDialog> {
  bool _emptyDir = false;
  bool _force = false;
  DrainPlan? _plan;
  String? _planError;
  int _seq = 0;
  bool _running = false;
  DrainResult? _result;
  String? _runError;

  ApiClient get _api => context.read<ApiClient>();

  @override
  void initState() {
    super.initState();
    _loadPlan();
  }

  Future<void> _loadPlan() async {
    final seq = ++_seq;
    setState(() => _planError = null);
    try {
      final p = await _api.drainPlan(widget.node, deleteEmptyDirData: _emptyDir, force: _force);
      if (mounted && seq == _seq) setState(() => _plan = p);
    } on ApiException catch (e) {
      if (mounted && seq == _seq) setState(() => _planError = e.message);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _planError = '$e');
    }
  }

  void _setOption(VoidCallback change) {
    setState(change);
    _loadPlan();
  }

  Future<void> _drain() async {
    setState(() => (_running = true, _runError = null));
    try {
      final r = await _api.drainNode(widget.node, deleteEmptyDirData: _emptyDir, force: _force);
      if (!mounted) return;
      if (r.error == null) return Navigator.pop(context, r);
      setState(() => (_running = false, _result = r));
    } on ApiException catch (e) {
      if (mounted) setState(() => (_running = false, _runError = e.message));
    } catch (e) {
      if (mounted) setState(() => (_running = false, _runError = '$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = _plan;
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final result = _result;

    Widget bullet(String text, Severity sev) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(sev == Severity.error ? Icons.block : Icons.info_outline, size: 14, color: severityColor(context, sev))),
            const SizedBox(width: 6),
            Expanded(child: Text(text, style: small)),
          ]),
        );

    final List<Widget> body;
    if (result != null) {
      final n = result.evicted.length;
      body = [
        Text('Evicted $n pod${n == 1 ? '' : 's'} before stopping. ${widget.node} stays cordoned.', style: theme.textTheme.bodyMedium),
        bullet(result.error!, Severity.error),
        const SizedBox(height: 8),
        Text('PodDisruptionBudgets can block evictions until other replicas are ready. Try again, or check the budgets in the blocked pods\' namespaces.', style: hint),
      ];
    } else {
      body = [
        Text('Cordons the node, then evicts its pods so their controllers recreate them elsewhere. DaemonSet pods stay. '
            'PodDisruptionBudgets are respected: blocked evictions are retried for up to 5 minutes.',
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 10),
        CheckboxListTile(
          key: const ValueKey('drain-emptydir'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _emptyDir,
          onChanged: _running ? null : (v) => _setOption(() => _emptyDir = v ?? false),
          title: const Text('Evict pods with emptyDir volumes'),
          subtitle: Text('Their emptyDir data is lost (kubectl --delete-emptydir-data)', style: hint),
        ),
        CheckboxListTile(
          key: const ValueKey('drain-force'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _force,
          onChanged: _running ? null : (v) => _setOption(() => _force = v ?? false),
          title: const Text('Delete pods without a controller'),
          subtitle: Text("They won't be recreated (kubectl --force)", style: hint),
        ),
        const Divider(height: 16),
        if (_planError != null)
          bullet('Could not work out the plan: $_planError', Severity.error)
        else if (plan == null)
          const Padding(padding: EdgeInsets.all(12), child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))))
        else ...[
          Text(plan.evict.isEmpty ? 'No pods to evict.' : 'Will evict ${plan.evict.length} pod${plan.evict.length == 1 ? '' : 's'}:',
              key: const ValueKey('drain-summary'), style: theme.textTheme.labelLarge),
          if (plan.evict.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(top: 4),
                children: [for (final p in plan.evict) Text(p, style: monoStyle(context, size: 11.5))],
              ),
            ),
          for (final b in plan.blockers) bullet(b, Severity.error),
          for (final w in plan.warnings) bullet(w, Severity.warn),
        ],
        if (_runError != null) bullet(_runError!, Severity.error),
      ];
    }

    final blocked = plan == null || plan.blockers.isNotEmpty || _planError != null;
    return AlertDialog(
      title: Text(result != null ? 'Drain of ${widget.node} stopped' : 'Drain node ${widget.node}?'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: body)),
      ),
      actions: result != null
          ? [FilledButton(onPressed: () => Navigator.pop(context, result), child: const Text('Close'))]
          : [
              TextButton(onPressed: _running ? null : () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                key: const ValueKey('drain-confirm'),
                style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error, foregroundColor: theme.colorScheme.onError),
                onPressed: _running || blocked ? null : _drain,
                child: _running
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.onError)),
                        const SizedBox(width: 8),
                        const Text('Draining…'),
                      ])
                    : const Text('Drain'),
              ),
            ],
    );
  }
}
