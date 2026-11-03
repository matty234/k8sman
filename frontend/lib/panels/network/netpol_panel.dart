import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'netpol_explain.dart';
import 'widgets.dart';
import '../../util/pod.dart';

class NetworkPolicyPanel extends ResourcePanel {
  const NetworkPolicyPanel();

  @override
  Set<String> get kinds => {'networking.k8s.io/NetworkPolicy'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) =>
      [_NetpolView(key: ValueKey('${ctx.uid}/netpol'), ctx: ctx)];
}

class _NetpolView extends StatelessWidget {
  final PanelContext ctx;
  const _NetpolView({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final sel = selectorToString(ctx.spec['podSelector']);
    return NetFetch<List<Json>>(
      fetchKey: sel,
      load: () => ctx.api.items(const ResourceRef(resource: 'pods'), namespace: ctx.namespace, labelSelector: sel.isEmpty ? null : sel),
      builder: (context, snap, reload) {
        final pods = snap.data;
        final ex = explainNetworkPolicy(ctx.object, matchedPods: pods?.length);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DetailSection(
            title: 'What this policy does',
            icon: Icons.shield_outlined,
            child: _explanation(context, ex),
          ),
          DetailSection(
            title: 'Selected pods',
            icon: Icons.widgets_outlined,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (pods != null) StatusBadge('${pods.length}', dense: true, severity: pods.isEmpty ? Severity.warn : Severity.info),
              RefreshButton(reload),
            ]),
            child: snap.hasError
                ? InlineMessage('${snap.error}', isError: true)
                : pods == null
                    ? spinner
                    : _pods(context, pods, sel),
          ),
        ]);
      },
    );
  }

  Widget _explanation(BuildContext context, NetpolExplanation ex) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SelectableText(ex.appliesTo, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      _direction(context, ex.ingress),
      const SizedBox(height: 8),
      _direction(context, ex.egress),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: Muted('policyTypes: ${ex.policyTypes.join(', ')}${ex.policyTypesDefaulted ? ' (defaulted)' : ''}  ·  '
              'policies are additive: traffic is allowed if any policy selecting the pod allows it'),
        ),
        IconButton(
          iconSize: 13,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          tooltip: 'Copy explanation',
          icon: const Icon(Icons.copy),
          onPressed: () => copyToClipboard(context, ex.text),
        ),
      ]),
    ]);
  }

  Widget _direction(BuildContext context, DirectionExplanation d) {
    final theme = Theme.of(context);
    final (label, sev) = switch (d.mode) {
      PolicyMode.unrestricted => ('Not restricted', Severity.neutral),
      PolicyMode.denyAll => ('Deny all', Severity.error),
      PolicyMode.allowAll => ('Allow all', Severity.ok),
      PolicyMode.restricted => ('Restricted', Severity.warn),
    };
    final c = severityColor(context, sev);
    final body = d.text.substring(d.direction.length + 2);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c, width: 3)),
        color: c.withValues(alpha: 0.06),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(d.direction == 'Ingress' ? Icons.call_received : Icons.call_made, size: 14, color: c),
          const SizedBox(width: 6),
          Text(d.direction, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          StatusBadge(label, dense: true, severity: sev),
        ]),
        const SizedBox(height: 4),
        if (d.mode != PolicyMode.restricted)
          SelectableText(body, style: theme.textTheme.bodySmall)
        else ...[
          SelectableText(body, style: theme.textTheme.bodySmall),
          if (d.rules.length > 1 || d.rules.any((r) => r.peers.length > 1)) ...[
            const SizedBox(height: 4),
            for (var i = 0; i < d.rules.length; i++) _rule(context, d, i),
          ],
        ],
      ]),
    );
  }

  /// Structured view of one rule: peers as bullets plus port chips.
  Widget _rule(BuildContext context, DirectionExplanation d, int i) {
    final theme = Theme.of(context);
    final r = d.rules[i];
    final small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('Rule ${i + 1}', style: small?.copyWith(fontWeight: FontWeight.w600, color: theme.hintColor)),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(spacing: 4, runSpacing: 2, children: [
              if (r.ports.isEmpty) const Chipish(text: 'any port') else for (final p in r.ports) Chipish(text: p),
            ]),
          ),
        ]),
        if (r.peers.isEmpty)
          Padding(padding: const EdgeInsets.only(left: 12, top: 2), child: Text('• ${d.preposition} anywhere', style: small))
        else
          for (final p in r.peers) Padding(padding: const EdgeInsets.only(left: 12, top: 2), child: Text('• $p', style: small)),
      ]),
    );
  }

  Widget _pods(BuildContext context, List<Json> pods, String sel) {
    if (pods.isEmpty) {
      return InlineMessage(sel.isEmpty
          ? 'No pods in ${ctx.namespace} yet; the policy will apply to every pod created here.'
          : 'No pods match $sel; the policy currently has no effect.');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final p in pods.take(50))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            StatusBadge(podReady(p) ? 'Ready' : dig(p, ['status', 'phase']) == 'Succeeded' ? 'Completed' : 'NotReady · ${dig(p, ['status', 'phase']) ?? 'Unknown'}',
                dense: true, severity: podReady(p) ? Severity.ok : (dig(p, ['status', 'phase']) == 'Succeeded' ? Severity.neutral : Severity.error)),
            const SizedBox(width: 8),
            Flexible(child: ResourceLink(ObjectRef(kind: 'Pod', name: '${dig(p, ['metadata', 'name'])}', namespace: ctx.namespace), label: '${dig(p, ['metadata', 'name'])}')),
            const SizedBox(width: 8),
            if (dig(p, ['status', 'podIP']) != null) Muted('${dig(p, ['status', 'podIP'])}', mono: true),
          ]),
        ),
      if (pods.length > 50) Muted('… and ${pods.length - 50} more'),
    ]);
  }
}
