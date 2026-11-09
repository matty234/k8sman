import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'kyverno_common.dart';
import '../../ui/widgets/atoms.dart';

/// PolicyReport and ClusterPolicyReport: the summary and the results,
/// failures first, with a filter by result.
class PolicyReportPanel extends ResourcePanel {
  const PolicyReportPanel();

  @override
  Set<String> get kinds => {'$reportGroup/PolicyReport', '$reportGroup/ClusterPolicyReport'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final summary = asMap(ctx.object['summary']);
    final scope = asMap(ctx.object['scope']);
    final results = sortResults(flattenReport(ctx.object));
    return [
      DetailSection(
        title: 'Summary',
        icon: Icons.fact_check_outlined,
        card: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InlineWrap([
            for (final k in const ['fail', 'error', 'warn', 'skip', 'pass'])
              StatusBadge('${summary[k] ?? 0} $k', severity: (summary[k] ?? 0) == 0 ? Severity.neutral : resultSeverity(k)),
          ]),
          if (scope.isNotEmpty) ...[
            const SizedBox(height: 6),
            KeyValueTable([
              ('Scope', ResourceLink(ObjectRef.fromOwnerRef(scope, namespace: ctx.namespace), label: '${scope['kind']}/${scope['name']}')),
            ], keyWidth: 100),
          ],
        ]),
      ),
      DetailSection(
        title: 'Results',
        icon: Icons.list_alt,
        trailing: HintText('${results.length}'),
        child: results.isEmpty ? const HintText('No results') : _Filtered(key: ValueKey('results-${ctx.uid}'), results: results),
      ),
    ];
  }
}

class _Filtered extends StatefulWidget {
  final List<PolicyResult> results;
  const _Filtered({super.key, required this.results});

  @override
  State<_Filtered> createState() => _FilteredState();
}

class _FilteredState extends State<_Filtered> {
  String? _only;

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final r in widget.results) {
      counts[r.result] = (counts[r.result] ?? 0) + 1;
    }
    final keys = counts.keys.toList()..sort((a, b) => resultRank(a).compareTo(resultRank(b)));
    final shown = [for (final r in widget.results) if (_only == null || r.result == _only) r];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 6, runSpacing: 4, children: [
        for (final k in keys)
          FilterChip(
            label: Text('$k ${counts[k]}'),
            visualDensity: VisualDensity.compact,
            selected: _only == k,
            onSelected: (on) => setState(() => _only = on ? k : null),
          ),
      ]),
      const SizedBox(height: 6),
      ResultsList(shown),
    ]);
  }
}
