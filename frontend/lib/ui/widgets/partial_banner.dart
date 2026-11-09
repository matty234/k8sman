import 'package:flutter/material.dart';

import '../../state/cluster_error.dart';
import 'error_notice.dart';

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
/// deleted): one amber notice, "Couldn't read 2 namespaces · team-5,
/// team-6: not allowed. Showing the other namespaces.", the raw messages
/// under Details. Tables and pages share it.
class PartialBanner extends StatelessWidget {
  final Map<String, ClusterError> errors;
  const PartialBanner({super.key, required this.errors});

  @override
  Widget build(BuildContext context) {
    final names = errors.keys.toList()..sort();
    return Padding(
      key: const ValueKey('partial-banner'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: ErrorNotice.parts(
        {for (final n in names) n: errors[n]!},
        title: names.length == 1 ? "Couldn't read namespace ${names.single}" : "Couldn't read ${names.length} namespaces",
        note: 'Showing the other namespaces.',
      ),
    );
  }
}
