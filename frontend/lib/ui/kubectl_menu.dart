import 'package:flutter/material.dart';

import '../api/models.dart';
import '../panels/pod/pod_logic.dart';
import '../state/app_state.dart';
import '../state/log_dock.dart' show defaultLogContainer;
import '../util/k8s.dart';
import '../util/kubectl.dart';
import 'widgets/common.dart' show copyToClipboard;

/// The context and kubeconfig the app is on (the active kubeconfig, or none
/// for the default loading rules).
KubectlEnv kubectlEnvOf(AppState app) => KubectlEnv(context: app.currentContext, kubeconfig: app.kubeconfigs.current);

/// The container `kubectl logs` / `exec` should name for [pod]: the
/// `kubectl.kubernetes.io/default-container` annotation if it names a
/// container, else the one the app's Logs action opens. Null for a
/// single-container pod, where `-c` is noise.
String? kubectlPodContainer(Json pod) {
  final names = [for (final c in podContainers(pod)) c.name];
  if (names.length < 2) return null;
  final annotated = dig<String>(pod, ['metadata', 'annotations', 'kubectl.kubernetes.io/default-container']);
  return names.contains(annotated) ? annotated : defaultLogContainer(pod);
}

/// A small menu at [globalPosition] offering the kubectl equivalents for
/// [refs] (all of [type]); picking one copies it. Pod logs / exec are only
/// offered for a single pod ([pod] is its live object; [container] overrides
/// the default); rollout for Deployments, StatefulSets and DaemonSets.
Future<void> showKubectlMenu(
  BuildContext context,
  Offset globalPosition, {
  required AppState app,
  required ResourceType type,
  required List<KubectlRef> refs,
  Json? pod,
  String? container,
}) async {
  final env = kubectlEnvOf(app);
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(globalPosition);
  final theme = Theme.of(context);
  final single = refs.length == 1;
  final c = container ?? (pod == null ? null : kubectlPodContainer(pod));

  PopupMenuItem<String> item(String label, String command) => PopupMenuItem<String>(
        value: command,
        height: 30,
        child: Text(label, style: theme.textTheme.bodyMedium),
      );

  final chosen = await showMenu<String>(
    context: context,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    position: RelativeRect.fromRect(Rect.fromPoints(local, local), Offset.zero & overlay.size),
    constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
    items: [
      item('kubectl get -o yaml', env.get(type, refs)),
      item('kubectl describe', env.describe(type, refs)),
      if (single && type.gk == '/Pod') ...[
        item('kubectl logs -f', env.logs(refs.single, container: c)),
        item('kubectl exec -it', env.exec(refs.single, container: c)),
      ],
      if (kubectlRolloutKinds.contains(type.gk)) ...[
        item('kubectl rollout restart', env.rolloutRestart(type, refs)),
        item('kubectl rollout status', env.rolloutStatus(type, refs)),
      ],
    ],
  );
  if (chosen != null && context.mounted) copyToClipboard(context, chosen, label: 'kubectl command');
}
