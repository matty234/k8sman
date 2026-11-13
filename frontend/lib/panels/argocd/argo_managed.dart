/// Warns, in an edit's review dialog, that the object is deployed by an
/// Argo CD Application, which will put it back the way git has it.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../util/k8s.dart';
import 'argo_common.dart';

const _trackingAnnotation = 'argocd.argoproj.io/tracking-id';

/// The managing Application from an object's tracking annotation
/// (`<app>:<group>/<Kind>:<namespace>/<name>`; `<app>` is `<ns>_<name>`
/// for apps outside Argo's own namespace). Null when the object isn't
/// tracked, or the annotation was copied from another object.
({String? namespace, String name})? argoTrackingApp(Json obj, {required String name}) {
  final id = dig<String>(obj, ['metadata', 'annotations', _trackingAnnotation]);
  if (id == null) return null;
  final parts = id.split(':');
  if (parts.length != 3 || parts[0].isEmpty || parts[2].split('/').last != name) return null;
  final app = parts[0];
  final i = app.indexOf('_');
  return i > 0 ? (namespace: app.substring(0, i), name: app.substring(i + 1)) : (namespace: null, name: app);
}

/// Shown above the diff when the object belongs to an Argo CD app; nothing
/// otherwise. With self-heal on, Argo reverts the change within seconds.
class ArgoManagedNotice extends StatefulWidget {
  final DetailTarget target;
  const ArgoManagedNotice({super.key, required this.target});

  @override
  State<ArgoManagedNotice> createState() => _ArgoManagedNoticeState();
}

class _ArgoManagedNoticeState extends State<ArgoManagedNotice> {
  ({String? namespace, String name})? _app;
  Json? _spec;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<ApiClient>();
    final t = widget.target;
    try {
      final obj = await api.object(t.type.ref, namespace: t.namespace, name: t.name);
      final app = argoTrackingApp(obj, name: t.name);
      if (app == null || !mounted) return;
      setState(() => _app = app);
      // Argo's namespace isn't known up front: look the app up by name.
      final apps = await api.items(applicationsRef, namespace: app.namespace, fieldSelector: 'metadata.name=${app.name}');
      if (apps.isNotEmpty && mounted) setState(() => _spec = asMap(apps.first['spec']));
    } catch (_) {
      // Best effort: no notice (or the generic one) if we can't tell.
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    if (app == null) return const SizedBox.shrink();
    final spec = _spec;
    final auto = spec != null && autoSyncEnabled(spec);
    final selfHeal = auto && dig<bool>(spec, ['syncPolicy', 'automated', 'selfHeal']) == true;
    final label = app.namespace == null ? app.name : '${app.namespace}/${app.name}';
    final text = selfHeal
        ? 'Managed by Argo CD app $label with self-heal on: Argo will revert this change within seconds. Change it in git instead, or turn off self-heal first.'
        : auto
            ? 'Managed by Argo CD app $label with auto-sync: the app will show OutOfSync and the next sync from git will revert this change.'
            : 'Managed by Argo CD app $label: the next sync from git will revert this change.';
    final theme = Theme.of(context);
    final c = severityColor(context, selfHeal ? Severity.error : Severity.warn);
    return Container(
      key: const ValueKey('argo-managed-notice'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withValues(alpha: 0.4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.sync_problem, size: 18, color: c),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ]),
    );
  }
}
