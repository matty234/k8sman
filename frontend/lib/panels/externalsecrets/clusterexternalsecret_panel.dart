import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'es_common.dart';
import '../../ui/widgets/atoms.dart';

/// ClusterExternalSecret: which namespaces it selects and where it was
/// (or failed to be) provisioned.
class ClusterExternalSecretPanel extends ResourcePanel {
  const ClusterExternalSecretPanel();

  @override
  Set<String> get kinds => {'$esGroup/ClusterExternalSecret'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final selectors = [
      if (asMap(spec['namespaceSelector']).isNotEmpty) asMap(spec['namespaceSelector']),
      ...asMapList(spec['namespaceSelectors']),
    ];
    final names = [for (final n in (spec['namespaces'] as List? ?? const [])) '$n'];
    final provisioned = [for (final n in (ctx.status['provisionedNamespaces'] as List? ?? const [])) '$n'];
    final failed = asMapList(ctx.status['failedNamespaces']);
    final inner = asMap(spec['externalSecretSpec']);
    return [
      DetailSection(
        title: 'Cluster external secret',
        icon: Icons.hub_outlined,
        card: true,
        trailing: readyBadge(ctx.status),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ReadyCallout(ctx.status),
          KeyValueTable([
            ('Secret name', spec['externalSecretName'] as String?),
            ('Store', asMap(inner['secretStoreRef']).isEmpty ? null : storeLink(asMap(inner['secretStoreRef']), null)),
            ('Refresh interval', inner['refreshInterval'] == null ? null : '${inner['refreshInterval']}'),
          ], keyWidth: 120),
        ]),
      ),
      DetailSection(
        title: 'Namespace selection',
        icon: Icons.filter_alt_outlined,
        child: selectors.isEmpty && names.isEmpty
            ? const HintText('No namespaceSelector or namespaces set')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final s in selectors) Padding(padding: const EdgeInsets.only(bottom: 4), child: MonoText(selectorSummary(s), size: 11)),
                if (names.isNotEmpty) InlineWrap([for (final n in names) Chipish(text: n)]),
              ]),
      ),
      DetailSection(
        title: 'Provisioned namespaces',
        icon: Icons.check_circle_outline,
        trailing: HintText('${provisioned.length}'),
        child: provisioned.isEmpty ? const HintText('None') : InlineWrap([for (final n in provisioned) Chipish(text: n)]),
      ),
      if (failed.isNotEmpty)
        DetailSection(
          title: 'Failed namespaces',
          icon: Icons.error_outline,
          trailing: HintText('${failed.length}'),
          child: KeyValueTable([for (final f in failed) ('${f['namespace'] ?? ''}', '${f['reason'] ?? ''}')], keyWidth: 150),
        ),
    ];
  }
}

/// A label selector as `k=v, key in (a,b)`.
String selectorSummary(Json s) => [
      for (final e in asMap(s['matchLabels']).entries) '${e.key}=${e.value}',
      for (final e in asMapList(s['matchExpressions'])) '${e['key']} ${e['operator']} (${(e['values'] as List? ?? const []).join(',')})',
    ].join(', ').ifEmpty('(all namespaces)');

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
