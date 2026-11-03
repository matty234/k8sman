import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/backend.dart';
import '../app/kubeconfig_picker.dart';
import '../state/app_state.dart';
import '../state/cluster_error.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/namespace_picker.dart';
import 'widgets/searchable_picker.dart';

/// Explains why the cluster (or backend) couldn't be reached, with what to
/// try and buttons for it. Used for empty tables that failed to load and
/// for the app's startup / context-switch failure screen.
class ClusterErrorView extends StatelessWidget {
  final ClusterError error;

  /// What failed to load, e.g. "pods". Null for app startup.
  final String? resource;

  /// The namespace the list was scoped to (null = all namespaces).
  final String? namespace;

  /// Whether the list was of a namespaced kind (offers the namespace picker
  /// on Forbidden).
  final bool namespaced;
  final VoidCallback onRetry;

  /// Re-run API discovery (offered when a kind is no longer served).
  final Future<void> Function()? onRediscover;
  const ClusterErrorView({
    super.key,
    required this.error,
    required this.onRetry,
    this.resource,
    this.namespace,
    this.namespaced = false,
    this.onRediscover,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final backend = Provider.of<BackendController?>(context, listen: false);
    final e = error;
    final host = e.host ?? 'the configured server';
    final res = resource ?? 'resources';
    final where = namespace == null ? 'any namespace' : 'namespace $namespace';
    final ctx = app.currentContext.isEmpty ? null : app.currentContext;

    final (IconData icon, String title, String body, List<Widget> tips) = switch (e.kind) {
      ClusterErrorKind.unreachable => (
          Icons.cloud_off_outlined,
          "Can't reach the cluster API at $host",
          'The connection to the API server failed${ctx != null ? ' for context $ctx' : ''}.',
          [
            const _Tip('Are you on the VPN or network the cluster needs?'),
            const _Tip('Is the cluster running? Local clusters (kind, minikube, Docker Desktop) stop when Docker does.'),
            const _Tip.code('Check from a terminal:', 'kubectl cluster-info'),
          ],
        ),
      ClusterErrorKind.timeout => (
          Icons.hourglass_empty,
          'The cluster API at $host is not responding',
          'The request timed out. The API server may be overloaded, or the network path to it is slow or blocked.',
          [
            const _Tip('Are you on the VPN or network the cluster needs?'),
            const _Tip.code('Check from a terminal:', 'kubectl cluster-info'),
          ],
        ),
      ClusterErrorKind.unauthorized => (
          Icons.key_off_outlined,
          'Credentials rejected or expired',
          'The cluster did not accept the credentials in your kubeconfig${ctx != null ? ' for context $ctx' : ''}.',
          [
            const _Tip('Clusters that use an exec plugin need a fresh login, then Retry:'),
            const _Tip.code('AWS EKS', 'aws sso login'),
            const _Tip.code('Google GKE', 'gcloud auth login'),
            const _Tip.code('Azure AKS', 'az login'),
            const _Tip('Client certificates and tokens in the kubeconfig may have expired or been removed.'),
          ],
        ),
      ClusterErrorKind.forbidden => (
          Icons.lock_outline,
          "You don't have permission to list $res in $where",
          'Your account is authenticated, but RBAC does not allow this list.',
          [
            if (namespaced)
              _Tip(namespace == null
                  ? 'Pick a namespace you can access: many accounts can only list within their own namespaces.'
                  : 'Pick a namespace you can access.'),
            const _Tip.code('Check your access:', 'kubectl auth can-i --list'),
          ],
        ),
      ClusterErrorKind.notFound => (
          Icons.help_outline,
          'The cluster no longer serves $res',
          'This kind was removed from the API (for example its CustomResourceDefinition was deleted or its API version retired).',
          [const _Tip('Rediscover the API resources to refresh the list of kinds.')],
        ),
      ClusterErrorKind.backendDown => (
          Icons.power_off_outlined,
          "The k8sman backend isn't responding",
          'The local helper process that talks to the cluster could not be reached.',
          [
            if (backend == null || !BackendController.embedded)
              const _Tip('If you started it yourself (make backend), check it is still running.'),
          ],
        ),
      ClusterErrorKind.other => (
          Icons.error_outline,
          resource == null ? 'Cannot connect to the cluster' : "Couldn't load $res",
          'Check the cluster is reachable and your credentials are valid, or choose another kubeconfig.',
          const <Widget>[],
        ),
    };

    final plugin = e.kind == ClusterErrorKind.unauthorized ? e.pluginError : null;
    final canRestartBackend = e.kind == ClusterErrorKind.backendDown && backend != null && BackendController.embedded;
    final clusterSide = e.kind != ClusterErrorKind.backendDown;

    final buttons = <Widget>[
      if (canRestartBackend)
        FilledButton(onPressed: () => backend.retry(), child: const Text('Restart backend'))
      else
        FilledButton(key: const ValueKey('cluster-error-retry'), autofocus: true, onPressed: onRetry, child: const Text('Retry')),
      if (e.kind == ClusterErrorKind.notFound && onRediscover != null)
        OutlinedButton(
          onPressed: () async {
            await onRediscover!();
            onRetry();
          },
          child: const Text('Rediscover API resources'),
        ),
      if (e.kind == ClusterErrorKind.forbidden && namespaced)
        const SizedBox(width: 200, height: 32, child: Center(child: NamespacePicker(height: 30))),
      if (clusterSide && app.contexts.length > 1) const ContextSwitchButton(),
      if (clusterSide) const KubeconfigPicker(compact: false),
    ];

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            key: ValueKey('cluster-error-${e.kind.name}'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 20, color: theme.hintColor)),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              ]),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  if (plugin != null) ...[
                    const SizedBox(height: 8),
                    Text('Credential plugin said:', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                    const SizedBox(height: 2),
                    SelectableText(plugin, style: monoStyle(context, size: 11.5, color: theme.colorScheme.error)),
                  ],
                  if (tips.isNotEmpty) ...[const SizedBox(height: 10), ...tips],
                  const SizedBox(height: 14),
                  Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: buttons),
                  const SizedBox(height: 14),
                  _Details(e.message),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One suggestion line, optionally with a command.
class _Tip extends StatelessWidget {
  final String text;
  final String? code;
  const _Tip(this.text) : code = null;
  const _Tip.code(this.text, String this.code);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('•  ', style: style),
        Expanded(
          child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(text, style: style),
            if (code != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(4)),
                child: SelectableText(code!, style: monoStyle(context, size: 11.5)),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// The raw error, collapsed by default.
class _Details extends StatefulWidget {
  final String message;
  const _Details(this.message);

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Hoverable(
        key: const ValueKey('cluster-error-details'),
        cursor: SystemMouseCursors.basic,
        onTap: () => setState(() => _open = !_open),
        builder: (h) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16, color: theme.hintColor),
          Text('Error details', style: theme.textTheme.bodySmall?.copyWith(color: h ? theme.colorScheme.onSurface : theme.hintColor)),
        ]),
      ),
      if (_open)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(6)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: SelectableText(widget.message, style: monoStyle(context, size: 11.5))),
            IconButton(
              tooltip: 'Copy',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.content_copy),
              onPressed: () => copyToClipboard(context, widget.message, label: 'error'),
            ),
          ]),
        ),
    ]);
  }
}

/// "Switch context…": a searchable list of the kubeconfig's contexts.
class ContextSwitchButton extends StatelessWidget {
  const ContextSwitchButton({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    return SearchablePicker<String>(
      key: const ValueKey('switch-context'),
      hint: 'Search contexts',
      selected: app.currentContext,
      items: () => [for (final c in app.contexts) PickerOption(c.name, c.name)],
      onSelected: (v) => v != app.currentContext ? app.switchContext(v) : null,
      width: 300,
      builder: (h) => Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: h ? theme.colorScheme.onSurface.withValues(alpha: 0.04) : null,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.hub_outlined, size: 15, color: theme.colorScheme.onSurface),
          const SizedBox(width: 6),
          Text('Switch context…', style: theme.textTheme.labelLarge),
        ]),
      ),
    );
  }
}
