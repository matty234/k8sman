import 'package:flutter/material.dart';

import '../../addons/addons.dart';
import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'gw_model.dart';
import 'gw_widgets.dart';
import '../../ui/inspector/inspector.dart' show Callout;
import '../../ui/widgets/atoms.dart';

/// Envoy Gateway's controllerName (see the add-on catalog).
const envoyGatewayController = 'gateway.envoyproxy.io/gatewayclass-controller';

class GatewayClassPanel extends ResourcePanel {
  const GatewayClassPanel();

  @override
  Set<String> get kinds => {'$gwGroup/GatewayClass'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final accepted = condOf(ctx.status['conditions'], 'Accepted');
    final params = asMap(spec['parametersRef']);
    final features = [
      for (final f in (ctx.status['supportedFeatures'] as List? ?? const [])) f is Map ? '${f['name']}' : '$f',
    ]..sort();
    final controller = '${spec['controllerName'] ?? ''}';
    return [
      CoreSection('class', DetailSection(
        title: 'Gateway class',
        icon: Icons.category_outlined,
        trailing: CondBadge(accepted, label: 'Accepted', negative: 'Not accepted'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!condTrue(accepted)) _notAccepted(context, ctx, accepted, controller),
          KeyValueTable([
            ('Controller', MonoText(controller, copy: true)),
            ('Description', spec['description'] as String?),
            (
              'Parameters',
              params.isEmpty
                  ? null
                  : Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      ResourceLink(
                        ObjectRef(group: '${params['group'] ?? ''}', kind: '${params['kind']}', name: '${params['name']}', namespace: params['namespace'] as String?),
                        label: '${params['kind']}/${params['name']}',
                      ),
                      HintText([if (params['group'] != null) '${params['group']}', if (params['namespace'] != null) 'ns ${params['namespace']}'].join(' · ')),
                    ]),
            ),
            ('Status', condTrue(accepted) ? (accepted?['message'] as String?) : null),
          ], keyWidth: 90),
        ]),
      )),
      if (features.isNotEmpty)
        CoreSection('supported-features', DetailSection(
          title: 'Supported features',
          icon: Icons.checklist,
          trailing: Text('${features.length}'),
          child: Wrap(spacing: 4, runSpacing: 4, children: [for (final f in features) Chipish(text: f)]),
        )),
      CoreSection('gateways', _ClassGateways(key: ValueKey('${ctx.uid}/gateways'), ctx: ctx)),
    ];
  }

  Widget _notAccepted(BuildContext context, PanelContext ctx, Json? accepted, String controller) {
    final pending = accepted == null || accepted['status'] == 'Unknown';
    final isEnvoy = controller == envoyGatewayController;
    final detail = pending
        ? 'No running controller claims "$controller", so Gateways of this class are never programmed. '
            '${isEnvoy ? 'Check the envoy-gateway Deployment in envoy-gateway-system.' : 'Install the Gateway API implementation that uses this controller name.'}'
        : '${accepted['message'] ?? accepted['reason'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Callout(
        severity: pending ? Severity.warn : Severity.error,
        title: pending ? 'No controller has accepted this class' : 'Rejected by its controller: ${accepted['reason']}',
        body: detail,
      ),
      if (pending && !ctx.app.readOnly)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
              onPressed: () => requestAddon(context, AddonIds.envoyGateway),
              icon: const Icon(Icons.download_outlined, size: 15),
              label: const Text('Install Envoy Gateway'),
            ),
          ),
        ),
    ]);
  }
}

class _ClassGateways extends StatelessWidget {
  final PanelContext ctx;
  const _ClassGateways({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    return NetFetch<List<Json>>(
      fetchKey: ctx.name,
      load: () => ctx.api.items(const ResourceRef(group: gwGroup, resource: 'gateways')),
      builder: (context, snap, reload) {
        final users = [for (final g in snap.data ?? const <Json>[]) if (dig(g, ['spec', 'gatewayClassName']) == ctx.name) g];
        return DetailSection(
          title: 'Gateways',
          icon: Icons.router_outlined,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (snap.hasData) Text('${users.length}'),
            const SizedBox(width: 4),
            RefreshButton(reload),
          ]),
          child: snap.hasError
              ? InlineMessage('${snap.error}', isError: true)
              : !snap.hasData
                  ? SectionSpinner()
                  : users.isEmpty
                      ? const InlineMessage('No Gateways use this class')
                      : HairlineList(padding: const EdgeInsets.symmetric(vertical: 4), [
                          for (final g in users)
                            () {
                              final programmed = condOf(dig(g, ['status', 'conditions']), 'Programmed');
                              final addr = asMapList(dig(g, ['status', 'addresses'])).map((a) => '${a['value']}').join(', ');
                              return Row(children: [
                                Expanded(
                                  child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                                    gwLink('Gateway', '${dig(g, ['metadata', 'name'])}', namespace: dig(g, ['metadata', 'namespace'])),
                                    if (addr.isNotEmpty) HintText(addr, mono: true),
                                  ]),
                                ),
                                CondBadge(programmed, label: 'Programmed', negative: 'Not programmed'),
                              ]);
                            }(),
                        ]),
        );
      },
    );
  }
}
