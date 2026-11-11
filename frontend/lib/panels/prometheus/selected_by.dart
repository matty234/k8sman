import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../prometheus/prom_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/atoms.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'common.dart';

ObjectRef amcfgRef(SourceRef s) => ObjectRef(group: 'monitoring.coreos.com', kind: 'AlertmanagerConfig', namespace: s.namespace, name: s.name);

/// Which Prometheus (or, for an AlertmanagerConfig, Alertmanager) custom
/// resources pick this object up, and the selector that stops the others.
class SelectedByView extends StatefulWidget {
  final PanelContext ctx;
  const SelectedByView({super.key, required this.ctx});

  @override
  State<SelectedByView> createState() => _SelectedByViewState();
}

class _SelectedByViewState extends State<SelectedByView> {
  late final Future<List<SelectedBy>> _f =
      PromApi.of(widget.ctx.api).selectedBy(kind: widget.ctx.type.kind, namespace: widget.ctx.namespace ?? '', name: widget.ctx.name);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAMConfig = widget.ctx.type.kind == 'AlertmanagerConfig';
    return FutureBuilder<List<SelectedBy>>(
      future: _f,
      builder: (context, snap) {
        if (snap.hasError) return LiveStateMessage(snap.error!);
        final l = snap.data;
        if (l == null) return const HintText('Checking…');
        if (l.isEmpty) return HintText('No ${isAMConfig ? 'Alertmanager' : 'Prometheus'} custom resource in the cluster.');
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!l.any((s) => s.selected))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('Nothing picks this ${widget.ctx.type.kind} up, so it has no effect.',
                  style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn))),
            ),
          for (final s in l)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Icon(s.selected ? Icons.check : Icons.close, size: 13, color: severityColor(context, s.selected ? Severity.ok : Severity.neutral)),
                ResourceLink(s.ref, label: '${s.kind} ${s.namespace}/${s.name}'),
                if (!s.selected) HintText(s.detail),
                if (s.selected && s.matcherStrategy != null) HintText(matcherStrategyText(s.matcherStrategy!, widget.ctx.namespace ?? '', s.namespace)),
              ]),
            ),
        ]);
      },
    );
  }
}

/// What an AlertmanagerConfig in [ns] applies to under the Alertmanager's
/// alertmanagerConfigMatcherStrategy.
String matcherStrategyText(String strategy, String ns, String amNamespace) => switch (strategy) {
      'None' => 'applies to every alert (matcher strategy None)',
      'OnNamespaceExceptForAlertmanagerNamespace' when ns == amNamespace => 'applies to every alert (it lives in the Alertmanager\'s namespace)',
      _ => 'applies only to alerts with namespace="$ns"',
    };
