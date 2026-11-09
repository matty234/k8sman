/// Shared pieces of the workload inspectors' status headers (the header
/// itself is the shared `InspectorHeader`): condition insights and the
/// scale stepper as a fact.
library;

import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../ui/inspector/inspector.dart';
import '../../../util/k8s.dart';

/// Conditions that are bad when True rather than when False.
const badWhenTrue = {'ReplicaFailure', 'ScalingLimited'};

/// Whether condition [c] says something is wrong.
bool conditionIsBad(Json c) => badWhenTrue.contains(c['type']) ? c['status'] == 'True' : c['status'] != 'True';

/// An insight per condition that is wrong (False, or True for
/// [badWhenTrue]): "Available: MinimumReplicasUnavailable" over its
/// message. A missed progress deadline, replica failures and the types in
/// [errors] are errors; the rest warnings.
List<Insight> conditionInsights(List<Json> conditions, {Set<String> skip = const {}, Set<String> errors = const {}}) => [
      for (final c in conditions)
        if (!skip.contains(c['type']) && conditionIsBad(c))
          Insight(
            c['type'] == 'ReplicaFailure' || errors.contains(c['type']) || c['reason'] == 'ProgressDeadlineExceeded' ? Severity.error : Severity.warn,
            [c['type'], c['reason']].whereType<String>().join(': '),
            c['message'] as String?,
          ),
    ];

/// The scale stepper as a fact; shrinks rather than overflowing when its
/// apply/reset buttons show in a narrow inspector.
/// Its buttons overhang the 18px row (centred on the label's line) and
/// the minus sits under the other values' left edge.
Widget scaleFact(Widget control) => SizedBox(
      height: 18,
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minHeight: 0,
        maxHeight: 48,
        child: Transform.translate(
          offset: const Offset(-8, 0),
          child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: control),
        ),
      ),
    );
