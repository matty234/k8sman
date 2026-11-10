import 'package:flutter/material.dart';

import '../../ui/widgets/atoms.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';

/// External Secrets Operator's API group.
const _esGroup = 'external-secrets.io';

/// "Managed by ExternalSecret <link>" for the Secret panel. The owner is
/// read from ownerReferences (creationPolicy Owner); a Secret ESO merged
/// into only carries its `reconcile.external-secrets.io/managed` label, so
/// that says no more than "managed". Nothing for other Secrets. Core, not
/// the external-secrets plugin's: it sits at the top of the Secret panel
/// (docs/PLUGINS.md, External Secrets pilot, "Managed by").
class ManagedByExternalSecret extends StatelessWidget {
  final PanelContext ctx;
  const ManagedByExternalSecret({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final owner = ownerRefs(ctx.object).where((o) => o.group == _esGroup && o.kind == 'ExternalSecret').firstOrNull;
    final managed = dig<String>(ctx.metadata, ['labels', 'reconcile.external-secrets.io/managed']) != null;
    if (owner == null && !managed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InlineWrap([
        const Icon(Icons.vpn_key_outlined, size: 14),
        const HintText('Managed by'),
        if (owner != null) ResourceLink(owner, label: 'ExternalSecret/${owner.name}') else const HintText('External Secrets Operator'),
      ]),
    );
  }
}
