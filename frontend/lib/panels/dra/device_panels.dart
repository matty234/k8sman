import 'package:flutter/material.dart';

import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'dra_common.dart';
import '../../ui/widgets/atoms.dart';

/// ResourceClaimTemplate: the claim spec pods get a private copy of.
class ResourceClaimTemplatePanel extends ResourcePanel {
  const ResourceClaimTemplatePanel();

  @override
  Set<String> get kinds => {'$draGroup/ResourceClaimTemplate'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final requests = draRequests(asMap(dig(ctx.spec, ['spec', 'devices'])));
    return [
      DetailSection(
        title: 'Requests',
        icon: Icons.fact_check_outlined,
        trailing: HintText('${requests.length}'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const HintText('Each pod that references this template gets its own claim with these requests.'),
          const SizedBox(height: 6),
          DraRequestList(requests),
        ]),
      ),
    ];
  }
}

/// DeviceClass: which devices a request names, and driver config.
class DeviceClassPanel extends ResourcePanel {
  const DeviceClassPanel();

  @override
  Set<String> get kinds => {'$draGroup/DeviceClass'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final selectors = celSelectors(ctx.spec['selectors']);
    final configs = asMapList(ctx.spec['config']);
    final extended = ctx.spec['extendedResourceName'] as String?;
    return [
      DetailSection(
        title: 'Selectors',
        icon: Icons.filter_alt_outlined,
        trailing: HintText('${selectors.length}'),
        child: selectors.isEmpty
            ? const HintText('No selectors: every device qualifies.')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final s in selectors) Padding(padding: const EdgeInsets.only(bottom: 4), child: CelBlock(s)),
              ]),
      ),
      if (extended != null && extended.isNotEmpty)
        DetailSection(
          title: 'Extended resource',
          icon: Icons.numbers,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MonoText(extended, copy: true),
            const SizedBox(height: 2),
            const HintText('Pods can request these devices as a container resource limit under this name.'),
          ]),
        ),
      if (configs.isNotEmpty)
        DetailSection(
          title: 'Config',
          icon: Icons.tune,
          trailing: HintText('${configs.length}'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final c in configs)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (dig<String>(c, ['opaque', 'driver']) case final d?) MonoText(d, size: 11),
                  JsonTree(dig(c, ['opaque', 'parameters']) ?? c, initiallyExpandedDepth: 0),
                ]),
              ),
          ]),
        ),
    ];
  }
}
