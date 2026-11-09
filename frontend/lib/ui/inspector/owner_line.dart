import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The object's owner as a link: the controller (or the first owner),
/// "Kind/name", with "+N" (listing the rest in a tooltip) when there are
/// more. Empty when the object has no owner.
///
/// Status headers put it in their facts (see [ownerFact]) and set
/// `ResourcePanel.ownerInHeader`; for every other kind the inspector shows
/// it as one quiet line at the top of the Overview (with [prefix]).
class OwnerLine extends StatelessWidget {
  final Json object;

  /// Before the link, in the hint colour, e.g. "Owned by ". Null: none.
  final String? prefix;
  const OwnerLine(this.object, {super.key, this.prefix});

  /// The owner shown first: the controller if one is marked, else the first.
  static List<ObjectRef> ordered(Json object) {
    final raw = asMapList(dig(object, ['metadata', 'ownerReferences']));
    final refs = ownerRefs(object);
    final i = raw.indexWhere((o) => o['controller'] == true);
    if (i <= 0) return refs;
    return [refs[i], for (var j = 0; j < refs.length; j++) if (j != i) refs[j]];
  }

  static bool hasOwner(Json object) => asMapList(dig(object, ['metadata', 'ownerReferences'])).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final owners = ordered(object);
    if (owners.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final rest = owners.skip(1).toList();
    return Row(key: const ValueKey('owner-line'), mainAxisSize: MainAxisSize.min, children: [
      if (prefix != null) Text(prefix!, style: hint),
      Flexible(child: ResourceLink(owners.first, singleLine: true)),
      if (rest.isNotEmpty)
        Tooltip(
          message: rest.map((o) => '${o.kind}/${o.name}').join('\n'),
          child: Text('  +${rest.length}', style: hint),
        ),
    ]);
  }
}

/// The owner as a `KeyValueTable` row for a status header's facts
/// ("Owner  ReplicaSet/web-…"), or null when there is none:
/// `[..., ?ownerFact(ctx.object)]`.
(String, Object?)? ownerFact(Json object) => OwnerLine.hasOwner(object) ? ('Owner', OwnerLine(object)) : null;

/// The quiet line at the top of an inspector's Overview: "Terminating · 2m"
/// while the object is being deleted, and (unless [showOwner] is false,
/// because the panel's status header has it) "Owned by Kind/name". Nothing
/// when neither applies.
class OverviewTopLine extends StatelessWidget {
  final Json object;
  final bool showOwner;
  const OverviewTopLine(this.object, {super.key, this.showOwner = true});

  @override
  Widget build(BuildContext context) {
    final deleting = dig(object, ['metadata', 'deletionTimestamp']);
    final owner = showOwner && OwnerLine.hasOwner(object);
    if (deleting == null && !owner) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(children: [
        if (deleting != null) ...[
          StatusBadge('Terminating · ${formatAge(parseTime(deleting))}', severity: Severity.warn, dense: true),
          if (owner) const SizedBox(width: 10),
        ],
        if (owner)
          Flexible(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.subdirectory_arrow_right, size: 12, color: AppColors.of(context).faint),
              const SizedBox(width: 4),
              Flexible(child: OwnerLine(object, prefix: 'Owned by ')),
            ]),
          ),
      ]),
    );
  }
}
