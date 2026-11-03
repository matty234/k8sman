import 'package:flutter/material.dart';

import '../../../actions/actions.dart';
import '../../../api/models.dart';
import '../../../ui/widgets/common.dart';
import '../../../util/k8s.dart';
import '../../panel.dart';
import 'util.dart';

const hpaRef = ResourceRef(group: 'autoscaling', resource: 'horizontalpodautoscalers');

/// The inline − N + scale stepper, or null when the app is read-only.
Widget? scaleControlFor(PanelContext ctx) => ctx.app.readOnly ? null : ScaleControl(ctx);

/// HPAs in [hpas] whose scaleTargetRef points at [obj].
List<Json> hpasTargeting(List<Json> hpas, Json obj) {
  final apiVersion = '${obj['apiVersion'] ?? ''}';
  final group = apiVersion.contains('/') ? apiVersion.split('/').first : '';
  final kind = obj['kind'];
  final name = dig(obj, ['metadata', 'name']);
  return [
    for (final h in hpas)
      if (() {
        final t = asMap(dig(h, ['spec', 'scaleTargetRef']));
        final tv = '${t['apiVersion'] ?? ''}';
        final tg = tv.contains('/') ? tv.split('/').first : '';
        return t['kind'] == kind && t['name'] == name && tg == group;
      }())
        h,
  ];
}

/// Warns that manual scaling will be overridden when an HPA targets this
/// workload. Fetches once per uid (key it by uid). Hidden when read-only.
class HpaOverrideNote extends StatefulWidget {
  final PanelContext ctx;
  const HpaOverrideNote(this.ctx, {super.key});

  @override
  State<HpaOverrideNote> createState() => _HpaOverrideNoteState();
}

class _HpaOverrideNoteState extends State<HpaOverrideNote> {
  late final Future<List<Json>> _future = widget.ctx.api
      .items(hpaRef, namespace: widget.ctx.namespace)
      .then((all) => hpasTargeting(all, widget.ctx.object), onError: (_) => <Json>[]);

  @override
  Widget build(BuildContext context) {
    if (widget.ctx.app.readOnly) return const SizedBox.shrink();
    return FutureBuilder<List<Json>>(
      future: _future,
      builder: (context, snap) {
        final hpas = snap.data ?? const [];
        if (hpas.isEmpty) return const SizedBox.shrink();
        final h = hpas.first;
        final name = '${dig(h, ['metadata', 'name'])}';
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Callout(
            severity: Severity.info,
            icon: Icons.auto_graph,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Managed by HPA '),
                ResourceLink(
                  ObjectRef(group: 'autoscaling', kind: 'HorizontalPodAutoscaler', name: name, namespace: widget.ctx.namespace),
                  label: name,
                ),
                Text(
                  ' (${dig(h, ['spec', 'minReplicas']) ?? 1}–${dig(h, ['spec', 'maxReplicas']) ?? '?'} replicas): '
                  'manual scaling will be overridden.',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
