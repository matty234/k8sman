import 'package:flutter/material.dart';

import '../../state/cluster_error.dart';
import '../../util/k8s.dart' show Severity;
import '../theme.dart';

/// `partialErrors` of a response (tables, Overview, Security, …): namespaces
/// of a namespace set that could not be read, by namespace.
Map<String, ClusterError> parsePartialErrors(Object? json) => {
      if (json is List)
        for (final e in json)
          if (e is Map && '${e['namespace'] ?? ''}'.isNotEmpty)
            '${e['namespace']}': ClusterError.classify(
              reason: e['reason'] as String?,
              code: (e['code'] as num?)?.toInt(),
              message: '${e['error'] ?? 'Unknown error'}',
            ),
    };

/// Shown over what was read when some namespaces of a set can't be (RBAC,
/// deleted): "No access to team-5 (forbidden). Showing the other
/// namespaces." Tables and pages share it.
class PartialBanner extends StatelessWidget {
  final Map<String, ClusterError> errors;
  const PartialBanner({super.key, required this.errors});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byWhy = <String, List<String>>{};
    for (final e in errors.entries) {
      final why = switch (e.value.kind) {
        ClusterErrorKind.forbidden => 'forbidden',
        ClusterErrorKind.notFound => 'not found',
        _ => 'unavailable',
      };
      (byWhy[why] ??= []).add(e.key);
    }
    final text = [for (final e in byWhy.entries) '${(e.value..sort()).join(', ')} (${e.key})'].join('; ');
    return Container(
      key: const ValueKey('partial-banner'),
      color: severityColor(context, Severity.warn).withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(14, 5, 8, 5),
      child: Row(children: [
        Icon(Icons.lock_outline, size: 14, color: severityColor(context, Severity.warn)),
        const SizedBox(width: 8),
        Expanded(
          child: Tooltip(
            message: [for (final e in errors.entries) '${e.key}: ${e.value.message}'].join('\n'),
            child: Text('No access to $text. Showing the other namespaces.', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          ),
        ),
      ]),
    );
  }
}
