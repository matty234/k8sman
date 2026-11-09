import 'package:flutter/material.dart';

import 'pod_logic.dart';

/// Small uppercase tag: INIT / SIDECAR / CONTAINER / EPHEMERAL.
class KindTag extends StatelessWidget {
  final ContainerKind kind;
  const KindTag(this.kind, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = switch (kind) {
      ContainerKind.init => Colors.blueGrey.shade300,
      ContainerKind.sidecar => Colors.teal.shade300,
      ContainerKind.regular => theme.colorScheme.primary,
      ContainerKind.ephemeral => Colors.purple.shade200,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: c.withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(3)),
      child: Text(kind.label.toUpperCase(), style: TextStyle(fontSize: 9.5, letterSpacing: 0.6, fontWeight: FontWeight.w700, color: c)),
    );
  }
}

