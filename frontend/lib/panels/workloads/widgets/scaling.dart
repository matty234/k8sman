import 'package:flutter/material.dart';

import '../../../actions/actions.dart';
import '../../../api/models.dart';
import '../../../ui/widgets/common.dart';
import '../../../util/k8s.dart';
import '../../panel.dart';
import 'status_header.dart';
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

/// The status header's "Replicas" fact: the scale stepper, or (read-only)
/// the desired count.
(String, Object?) replicasFact(PanelContext ctx) {
  final control = scaleControlFor(ctx);
  final desired = asInt(ctx.spec['replicas']) ?? 1;
  return ('Replicas', control == null ? '$desired desired' : scaleFact(control));
}

/// Says the workload is scaled by an HPA (and, unless read-only, that
/// manual scaling will be overridden), as an insight line for the status
/// header. Fetches once per uid (key it by uid); nothing without an HPA.
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
    return FutureBuilder<List<Json>>(
      future: _future,
      builder: (context, snap) {
        final hpas = snap.data ?? const [];
        if (hpas.isEmpty) return const SizedBox.shrink();
        final h = hpas.first;
        final name = '${dig(h, ['metadata', 'name'])}';
        final range = '${dig(h, ['spec', 'minReplicas']) ?? 1}–${dig(h, ['spec', 'maxReplicas']) ?? '?'} replicas';
        return Padding(
          key: const ValueKey('hpa-note'),
          padding: const EdgeInsets.only(top: 10),
          child: InsightRow(
            WorkloadInsight(
              Severity.info,
              'Scaled by HPA $name',
              title: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                const Text('Scaled by HPA '),
                ResourceLink(ObjectRef(group: 'autoscaling', kind: 'HorizontalPodAutoscaler', name: name, namespace: widget.ctx.namespace), label: name),
              ]),
              detail: widget.ctx.app.readOnly ? range : '$range: manual scaling will be overridden.',
            ),
          ),
        );
      },
    );
  }
}
