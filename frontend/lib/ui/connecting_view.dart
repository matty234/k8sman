import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/kubeconfig_picker.dart';
import '../state/app_state.dart';
import '../util/k8s.dart';
import 'cluster_error_view.dart';
import 'theme.dart';

/// Shown while connecting to a context (startup, context or kubeconfig
/// switch): which cluster, which step, how long, and after a few seconds
/// what is probably going on. Cancel abandons the connect and returns to the
/// previous context (or, with none, to the context/kubeconfig pickers).
class ConnectingView extends StatefulWidget {
  const ConnectingView({super.key});

  /// How long before the screen explains what may be slow.
  static const explainAfter = Duration(seconds: 4);

  @override
  State<ConnectingView> createState() => _ConnectingViewState();
}

class _ConnectingViewState extends State<ConnectingView> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = app.connecting;
    if (c == null) {
      // Before the backend has said which context it is on (a local call).
      return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final elapsed = clock.now().difference(c.started);
    final prev = app.previousContext;
    final steps = [
      (ConnectStep.reaching, 'Reaching the API server'),
      (ConnectStep.signingIn, c.auth != null ? 'Signing in via ${c.auth}' : 'Checking credentials'),
      (ConnectStep.discovering, 'Discovering resource kinds'),
      (ConnectStep.namespaces, 'Loading namespaces'),
    ];

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): app.cancelConnect},
      child: Focus(
        autofocus: true,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                key: const ValueKey('connecting-view'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: 'Connecting to '),
                          TextSpan(text: c.context, style: const TextStyle(fontWeight: FontWeight.w600)),
                        ]),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ]),
                  Padding(
                    padding: const EdgeInsets.only(left: 30, top: 4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (c.server != null || c.auth != null)
                        Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          if (c.server != null) SelectableText(c.server!, style: monoStyle(context, size: 11.5, color: muted)),
                          if (c.auth != null) Text('· via ${c.auth}', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                        ]),
                      const SizedBox(height: 14),
                      for (final (step, label) in steps) _StepRow(label: label, state: _stateOf(step, c.step), elapsed: step == c.step ? elapsed : null),
                      if (elapsed >= ConnectingView.explainAfter) ...[
                        const SizedBox(height: 12),
                        _Explanation(progress: c),
                      ],
                      const SizedBox(height: 16),
                      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        OutlinedButton(
                          key: const ValueKey('connecting-cancel'),
                          onPressed: app.cancelConnect,
                          child: const Text('Cancel'),
                        ),
                        if (app.contexts.length > 1) const ContextSwitchButton(),
                        const KubeconfigPicker(compact: false),
                      ]),
                      if (prev != null) ...[
                        const SizedBox(height: 6),
                        Text('Cancel goes back to $prev.', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                      ],
                    ]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static _StepState _stateOf(ConnectStep step, ConnectStep current) => step.index < current.index
      ? _StepState.done
      : step == current
          ? _StepState.active
          : _StepState.pending;
}

enum _StepState { done, active, pending }

class _StepRow extends StatelessWidget {
  final String label;
  final _StepState state;
  final Duration? elapsed;
  const _StepRow({required this.label, required this.state, this.elapsed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (state) {
      _StepState.done => theme.colorScheme.onSurfaceVariant,
      _StepState.active => theme.colorScheme.onSurface,
      _StepState.pending => theme.hintColor,
    };
    final icon = switch (state) {
      _StepState.done => Icon(Icons.check, size: 14, color: severityColor(context, Severity.ok)),
      _StepState.active => Icon(Icons.arrow_right, size: 16, color: theme.colorScheme.primary),
      _StepState.pending => Icon(Icons.circle_outlined, size: 8, color: theme.hintColor),
    };
    final secs = elapsed?.inSeconds ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        SizedBox(width: 18, child: Center(child: icon)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label,
              style: theme.textTheme.bodyMedium?.copyWith(color: color, fontWeight: state == _StepState.active ? FontWeight.w500 : null)),
        ),
        if (elapsed != null && secs >= 1) ...[
          const SizedBox(width: 8),
          Text('${secs}s', key: const ValueKey('connecting-elapsed'), style: monoStyle(context, size: 11.5, color: theme.hintColor)),
        ],
      ]),
    );
  }
}

/// What is probably slow, for the current step.
class _Explanation extends StatelessWidget {
  final ConnectProgress progress;
  const _Explanation({required this.progress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = progress;
    final server = c.server ?? 'the API server';
    final (String title, List<String> tips) = switch (c.step) {
      ConnectStep.reaching => (
          'No answer from $server yet',
          [
            'If the cluster is on a private network, check your VPN is connected.',
            'Local clusters (kind, minikube, Docker Desktop) stop when Docker does.',
            'If nothing answers within 10 seconds, k8sman stops and shows what failed.',
          ],
        ),
      ConnectStep.signingIn when c.auth != null => (
          '${c.auth} may be waiting for you to sign in',
          [
            'Check your browser for a login page; it may have opened behind this window.',
            'Finish signing in and k8sman continues on its own. It waits up to 5 minutes.',
            'If no login page appeared, sign in from a terminal (for example kubectl get ns --context ${c.context}), then Cancel and connect again.',
          ],
        ),
      ConnectStep.signingIn => (
          'The API server is slow to accept your credentials',
          ['The server is answering, but authenticated requests are slow. It may be overloaded.'],
        ),
      ConnectStep.discovering => (
          'The API server is answering slowly',
          [
            'Discovering which kinds the cluster serves can take a while on large or busy clusters. Later starts use a cache.',
            'Requests may be crossing a slow VPN or proxy.',
          ],
        ),
      ConnectStep.namespaces => (
          'Listing namespaces is taking a while',
          ['The API server may be overloaded. k8sman gives up after 30 seconds.'],
        ),
    };
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Container(
      key: ValueKey('connecting-explanation-${c.step.name}'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(c.step == ConnectStep.signingIn && c.auth != null ? Icons.open_in_browser : Icons.info_outline, size: 15, color: theme.hintColor),
          const SizedBox(width: 6),
          Expanded(child: Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500))),
        ]),
        const SizedBox(height: 4),
        for (final t in tips)
          Padding(
            padding: const EdgeInsets.only(bottom: 2, left: 21),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('•  ', style: style),
              Expanded(child: Text(t, style: style)),
            ]),
          ),
      ]),
    );
  }
}
