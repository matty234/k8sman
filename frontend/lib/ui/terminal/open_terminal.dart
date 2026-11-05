import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../panels/panel.dart';
import '../../panels/pod/pod_logic.dart';
import '../../state/app_state.dart';
import '../../state/log_dock.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import 'exec_protocol.dart';
import 'terminal_tab.dart';

/// Action id for "Terminal". The inspector shows it beside "Logs" and hides
/// it in read-only mode (exec is refused there).
const String kTerminalActionId = 'terminal';

/// Opens a terminal session as a new tab in the bottom dock. [container]
/// null = the pod's default container; [command] null = auto shell.
/// Returns null (with a message) in read-only mode.
TerminalTab? openTerminal(BuildContext context, {required String namespace, required String pod, String? container, List<String>? command}) {
  final app = context.read<AppState>();
  if (app.readOnly) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Terminals are disabled in read-only mode')));
    return null;
  }
  final tab = TerminalTab(
    transport: execTransportFor(context.read<ApiClient>()),
    request: ExecRequest(namespace: namespace, pod: pod, container: container, command: command),
  );
  context.read<LogDock>().add(tab);
  return tab;
}

/// Local shells need a pseudo-terminal implementation; Windows (ConPTY)
/// doesn't have one yet.
bool get localShellSupported => !Platform.isWindows;

/// Opens a login shell on this machine as a new dock tab. The backend points
/// its KUBECONFIG at the app's current context. Allowed in read-only mode:
/// the shell prints a notice that read-only can't apply to it.
TerminalTab? openLocalShell(BuildContext context) {
  if (!localShellSupported) return null;
  final tab = TerminalTab(transport: execTransportFor(context.read<ApiClient>()), request: const ExecRequest.localShell());
  context.read<LogDock>().add(tab);
  return tab;
}

/// Containers a terminal can attach to: running regular, sidecar and
/// ephemeral containers, regular ones first.
List<PodContainer> terminalContainers(Json pod) {
  int rank(PodContainer c) => switch (c.kind) {
        ContainerKind.regular => 0,
        ContainerKind.sidecar => 1,
        ContainerKind.ephemeral => 2,
        ContainerKind.init => 3,
      };
  final cs = podContainers(pod).where((c) => c.isRunning && c.kind != ContainerKind.init).toList();
  // Stable sort by kind, keeping spec order within a kind.
  return [for (var r = 0; r < 3; r++) ...cs.where((c) => rank(c) == r)];
}

/// The container a pod's "Terminal" action defaults to: the
/// `kubectl.kubernetes.io/default-container` annotation if running, else the
/// first running non-sidecar.
String? defaultTerminalContainer(Json pod) {
  final cs = terminalContainers(pod);
  final annotated = dig<String>(pod, ['metadata', 'annotations', 'kubectl.kubernetes.io/default-container']);
  for (final c in cs) {
    if (c.name == annotated) return c.name;
  }
  return cs.isEmpty ? null : cs.first.name;
}

/// Opens a terminal in [pod], asking which container when several run.
Future<void> openPodTerminal(BuildContext context, Json pod, {String? container}) async {
  final ns = dig<String>(pod, ['metadata', 'namespace']) ?? '';
  final name = dig<String>(pod, ['metadata', 'name']) ?? '';
  if (container == null) {
    final cs = terminalContainers(pod);
    if (cs.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Pod $name has no running containers')));
      return;
    }
    container = cs.length == 1 ? cs.single.name : await pickContainer(context, pod, cs);
    if (container == null || !context.mounted) return;
  }
  openTerminal(context, namespace: ns, pod: name, container: container);
}

/// A small chooser; the default container is listed first and focused, so
/// Return accepts it.
Future<String?> pickContainer(BuildContext context, Json pod, List<PodContainer> cs) {
  final def = defaultTerminalContainer(pod);
  final ordered = [...cs.where((c) => c.name == def), ...cs.where((c) => c.name != def)];
  return showDialog<String>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return SimpleDialog(
        title: Text('Terminal in ${dig(pod, ['metadata', 'name'])}'),
        children: [
          for (final (i, c) in ordered.indexed)
            SimpleDialogOption(
              key: ValueKey('pick-container-${c.name}'),
              onPressed: () => Navigator.pop(context, c.name),
              child: Focus(
                autofocus: i == 0,
                child: Row(children: [
                  Icon(Icons.terminal, size: 16, color: theme.hintColor),
                  const SizedBox(width: 10),
                  Text(c.name, style: monoStyle(context, size: 13)),
                  const SizedBox(width: 8),
                  Text(c.kind.label.toLowerCase(), style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                  if (i == 0) ...[const Spacer(), Text('default', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))],
                ]),
              ),
            ),
        ],
      );
    },
  );
}

/// "Terminal" header action for a Pod.
ResourceAction podTerminalAction(PanelContext ctx) => ResourceAction(
      id: kTerminalActionId,
      label: 'Terminal',
      icon: Icons.terminal,
      tooltip: 'Open a shell in a container (bottom panel)',
      run: (context) => openPodTerminal(context, ctx.object),
    );

/// "Terminal" header action for Deployments / StatefulSets / DaemonSets:
/// picks a ready pod (owned by the object when possible).
ResourceAction workloadTerminalAction(PanelContext ctx) => ResourceAction(
      id: kTerminalActionId,
      label: 'Terminal',
      icon: Icons.terminal,
      tooltip: 'Open a shell in a ready pod (bottom panel)',
      run: (context) => openWorkloadTerminal(context, ctx),
    );

Future<void> openWorkloadTerminal(BuildContext context, PanelContext ctx) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final sel = selectorToString(ctx.spec['selector']);
  if (sel.isEmpty) {
    messenger?.showSnackBar(const SnackBar(content: Text('No pod selector')));
    return;
  }
  List<Json> pods;
  try {
    pods = await ctx.api.items(const ResourceRef(resource: 'pods'), namespace: ctx.namespace, labelSelector: sel);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Could not list pods: $e')));
    return;
  }
  final pod = pickReadyPod(pods, ownerUid: ctx.uid, preferOwned: ctx.type.kind != 'Deployment');
  if (pod == null) {
    messenger?.showSnackBar(SnackBar(content: Text('${ctx.type.kind} ${ctx.name} has no running pods')));
    return;
  }
  if (!context.mounted) return;
  final ns = dig<String>(pod, ['metadata', 'namespace']) ?? ctx.namespace ?? '';
  openTerminal(context, namespace: ns, pod: '${dig(pod, ['metadata', 'name'])}', container: defaultTerminalContainer(pod));
}

/// A ready, running, non-terminating pod (else any running one), by name.
Json? pickReadyPod(List<Json> pods, {String? ownerUid, bool preferOwned = true}) {
  var candidates = pods;
  if (preferOwned && ownerUid != null) {
    final owned = pods.where((p) => asMapList(dig(p, ['metadata', 'ownerReferences'])).any((r) => r['uid'] == ownerUid)).toList();
    if (owned.isNotEmpty) candidates = owned;
  }
  bool running(Json p) => dig(p, ['status', 'phase']) == 'Running' && dig(p, ['metadata', 'deletionTimestamp']) == null;
  bool ready(Json p) => asMapList(dig(p, ['status', 'conditions'])).any((c) => c['type'] == 'Ready' && c['status'] == 'True');
  final sorted = [...candidates]..sort((a, b) => '${dig(a, ['metadata', 'name'])}'.compareTo('${dig(b, ['metadata', 'name'])}'));
  return sorted.where((p) => running(p) && ready(p)).firstOrNull ?? sorted.where(running).firstOrNull;
}
