import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'inspector_kit.dart';
import 'netpol_explain.dart';
import 'widgets.dart';

class NetworkPolicyPanel extends ResourcePanel {
  const NetworkPolicyPanel();

  @override
  Set<String> get kinds => {'networking.k8s.io/NetworkPolicy'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) =>
      [_NetpolView(key: ValueKey('${ctx.uid}/netpol'), ctx: ctx)];
}

/// The headline for a policy: what it does to the directions it governs.
String netpolHeadline(NetpolExplanation ex) {
  final governed = [for (final d in [ex.ingress, ex.egress]) if (d.mode != PolicyMode.unrestricted) d];
  if (governed.isEmpty) return 'No effect';
  String dirs(Iterable<DirectionExplanation> ds) => ds.map((d) => d.direction.toLowerCase()).join(' and ');
  if (governed.every((d) => d.mode == PolicyMode.denyAll)) return governed.length == 2 ? 'Default deny' : 'Default deny ${dirs(governed)}';
  if (governed.every((d) => d.mode == PolicyMode.allowAll)) return 'Allows all ${dirs(governed)}';
  return 'Restricts ${dirs(governed)}';
}

/// One plain-language line per allowed source/destination of a rule:
/// "from pods with tier=frontend in this namespace on TCP 8080".
List<String> ruleLines(DirectionExplanation d, RuleExplanation r) {
  final where = r.ports.isEmpty ? 'on any port' : 'on ${r.ports.join(', ')}';
  return [for (final p in r.peers.isEmpty ? const ['anywhere'] : r.peers) '${d.preposition} $p $where'];
}

String _modeLabel(PolicyMode m) => switch (m) {
      PolicyMode.unrestricted => 'Not restricted',
      PolicyMode.denyAll => 'Deny all',
      PolicyMode.allowAll => 'Allow all',
      PolicyMode.restricted => 'Restricted',
    };

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
          _header(context, ex, pods, sel, snap.error),
          _direction(context, ex.ingress),
          _direction(context, ex.egress),
          PodSection(
            id: 'netpol-pods',
            title: 'Selected pods',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (pods != null) Flexible(child: SectionSummary('${pods.length}')),
              const SizedBox(width: 4),
              SizedBox(height: 20, child: RefreshButton(reload)),
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

  Widget _header(BuildContext context, NetpolExplanation ex, List<Json>? pods, String sel, Object? error) {
    String figure(DirectionExplanation d) => switch (d.mode) {
          PolicyMode.unrestricted => '–',
          PolicyMode.denyAll => 'deny',
          PolicyMode.allowAll => 'all',
          PolicyMode.restricted => '${[for (final r in d.rules) ...ruleLines(d, r)].length}',
        };
    final insights = <PodInsight>[
      if (pods != null && pods.isEmpty)
        PodInsight(
          Severity.warn,
          'Selects no pods',
          sel.isEmpty ? 'No pods in ${ctx.namespace} yet; the policy will apply to every pod created here.' : 'No pods match $sel; the policy currently has no effect.',
        ),
      if (error != null) PodInsight(Severity.warn, 'Could not list pods', '$error'),
    ];
    return InspectorHeader(
      mark: worstOf(insights) ?? (pods == null ? Severity.neutral : Severity.ok),
      headline: netpolHeadline(ex),
      detail: ex.appliesTo,
      figures: [
        HeaderFigure(pods == null ? '–' : '${pods.length}', pods?.length == 1 ? 'pod' : 'pods', severity: pods != null && pods.isEmpty ? Severity.warn : Severity.neutral),
        HeaderFigure(figure(ex.ingress), 'ingress', tooltip: ex.ingress.text),
        HeaderFigure(figure(ex.egress), 'egress', tooltip: ex.egress.text),
      ],
      insights: insights,
      facts: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Muted('policyTypes: ${ex.policyTypes.join(', ')}${ex.policyTypesDefaulted ? ' (defaulted)' : ''}  ·  '
              'policies are additive: traffic is allowed if any policy selecting the pod allows it'),
        ),
        RowAction(icon: Icons.copy, tooltip: 'Copy explanation', onTap: () => copyToClipboard(context, ex.text)),
      ]),
    );
  }

  /// A direction's section: its mode in the header, then one row per
  /// allowed peer in plain language.
  Widget _direction(BuildContext context, DirectionExplanation d) {
    final lines = [
      for (final (i, r) in d.rules.indexed)
        for (final l in ruleLines(d, r)) (i, l),
    ];
    final multiRule = d.rules.length > 1;
    final Widget body = switch (d.mode) {
      PolicyMode.unrestricted => Padding(padding: const EdgeInsets.only(left: 4), child: Muted('This policy does not restrict ${d.direction.toLowerCase()} traffic.')),
      PolicyMode.denyAll => CompactRow(
          severity: Severity.neutral,
          title: Text('All ${d.direction.toLowerCase()} traffic denied', maxLines: 2),
          subtitle: const Text('No rule allows anything, so only other policies can open it.'),
        ),
      PolicyMode.allowAll => CompactRow(
          severity: Severity.ok,
          title: Text('All ${d.direction.toLowerCase()} traffic allowed', maxLines: 2),
          subtitle: const Text('A rule with no peers and no ports allows everything.'),
        ),
      PolicyMode.restricted => TrimmedRows([
          for (final (i, l) in lines)
            CompactRow(
              key: ValueKey('netpol-${d.direction}-$l'),
              severity: Severity.ok,
              title: Text(l, maxLines: 3),
              subtitle: multiRule ? Text('rule ${i + 1}') : null,
            ),
        ], limit: 8),
    };
    return PodSection(
      id: 'netpol-${d.direction.toLowerCase()}',
      title: d.direction,
      initiallyExpanded: d.mode != PolicyMode.unrestricted,
      trailing: SectionSummary(d.mode == PolicyMode.restricted ? '${_modeLabel(d.mode)} · ${lines.length} allowed' : _modeLabel(d.mode)),
      child: body,
    );
  }

  Widget _pods(BuildContext context, List<Json> pods, String sel) {
    if (pods.isEmpty) {
      return InlineMessage(sel.isEmpty
          ? 'No pods in ${ctx.namespace} yet; the policy will apply to every pod created here.'
          : 'No pods match $sel; the policy currently has no effect.');
    }
    return PodRows(pods, trailing: (p) => [if (dig(p, ['status', 'podIP']) != null) Muted('${dig(p, ['status', 'podIP'])}', mono: true)]);
  }
}
