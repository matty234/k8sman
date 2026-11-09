import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'es_common.dart';
import '../../ui/widgets/atoms.dart';

/// SecretStore and ClusterSecretStore: the provider and its settings,
/// conditions and the ExternalSecrets that use the store.
class SecretStorePanel extends ResourcePanel {
  const SecretStorePanel();

  @override
  Set<String> get kinds => {'$esGroup/SecretStore', '$esGroup/ClusterSecretStore'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final provider = asMap(ctx.spec['provider']);
    final kind = provider.keys.firstOrNull;
    final cluster = ctx.type.kind == 'ClusterSecretStore';
    final rows = kind == null ? const <(String, Object?)>[] : providerRows(asMap(provider[kind]), ctx.namespace);
    final caps = ctx.status['capabilities'] as String?;
    return [
      DetailSection(
        title: 'Provider',
        icon: Icons.vpn_key_outlined,
        card: true,
        trailing: readyBadge(ctx.status),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ReadyCallout(ctx.status),
          KeyValueTable([
            ('Provider', kind == null ? null : Chipish(text: kind)),
            ('Capabilities', caps),
            ('Refresh interval', ctx.spec['refreshInterval'] == null ? null : '${ctx.spec['refreshInterval']}'),
            ('Controller', ctx.spec['controller'] as String?),
            ...rows,
          ], keyWidth: 150),
        ]),
      ),
      if (asMapList(ctx.status['conditions']).isNotEmpty)
        DetailSection(title: 'Conditions', icon: Icons.fact_check_outlined, child: ConditionsTable(asMapList(ctx.status['conditions']))),
      _UsedBy(key: ValueKey('${ctx.uid}/usedby'), ctx: ctx, cluster: cluster),
    ];
  }
}

/// ExternalSecrets that reference this store, from one list.
class _UsedBy extends StatelessWidget {
  final PanelContext ctx;
  final bool cluster;
  const _UsedBy({super.key, required this.ctx, required this.cluster});

  static const _cap = 50;

  @override
  Widget build(BuildContext context) => NetFetch<List<Json>>(
        fetchKey: ctx.uid,
        load: () async => [
          for (final es in await ctx.api.items(externalSecretsRef))
            if (_uses(es)) es,
        ],
        builder: (context, snap, reload) {
          final list = snap.data ?? const <Json>[];
          if (snap.hasError) return const SizedBox.shrink();
          return DetailSection(
            title: 'ExternalSecrets using this store',
            icon: Icons.link,
            trailing: snap.hasData ? HintText('${list.length}') : SectionSpinner(),
            child: list.isEmpty
                ? const HintText('None')
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final es in list.take(_cap))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          Expanded(
                            child: ResourceLink(
                              externalSecretRef(dig<String>(es, ['metadata', 'name']) ?? '', dig<String>(es, ['metadata', 'namespace'])),
                              label: '${dig<String>(es, ['metadata', 'namespace'])}/${dig<String>(es, ['metadata', 'name'])}',
                              singleLine: true,
                            ),
                          ),
                          StatusBadge(readyReason(asMap(es['status'])), dense: true),
                        ]),
                      ),
                    if (list.length > _cap) HintText('and ${list.length - _cap} more'),
                  ]),
          );
        },
      );

  bool _uses(Json es) {
    final ref = asMap(dig(es, ['spec', 'secretStoreRef']));
    final kind = ref['kind'] ?? 'SecretStore';
    if (ref['name'] != ctx.name || kind != ctx.type.kind) return false;
    return cluster || dig<String>(es, ['metadata', 'namespace']) == ctx.namespace;
  }
}
