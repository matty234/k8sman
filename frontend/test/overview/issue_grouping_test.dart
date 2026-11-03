import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/overview/overview_api.dart';

import 'overview_test.dart' show pumpOverview;

Map<String, dynamic> _issue(String kind, String name, {String group = '', Map<String, String>? owner, String category = 'alertWarning'}) => {
      'severity': 'warning',
      'category': category,
      'kind': kind,
      'group': group,
      'namespace': 'monitoring',
      'name': name,
      'reason': 'KubeSomethingAlert',
      'message': 'synthetic',
      'since': DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String(),
      'owner': ?owner,
    };

const _dep = {'group': 'apps', 'kind': 'Deployment', 'name': 'exporter'};

Map<String, dynamic> _overview(List<Map<String, dynamic>> issues) => {
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'namespace': '',
      'counts': <String, dynamic>{},
      'categories': <dynamic>[],
      'issues': issues,
      'nodes': <dynamic>[],
      'topWarnings': <dynamic>[],
    };

void main() {
  // Regression: Alertmanager alerts on a Deployment itself (no owner) share a
  // group key with pod alerts owned by that Deployment, and the tile used to
  // force-unwrap the first issue's (null) owner.
  final mixed = [
    _issue('Deployment', 'exporter', group: 'apps'),
    _issue('Pod', 'exporter-abc', owner: _dep),
    _issue('Pod', 'exporter-def', owner: _dep),
  ];

  test('a mixed group resolves its owner from any issue', () {
    final groups = groupIssues(mixed.map(OverviewIssue.fromJson));
    expect(groups, hasLength(1));
    expect(groups.single.owner, const OverviewOwner(group: 'apps', kind: 'Deployment', name: 'exporter'));
  });

  test('a multi-issue group with no owners falls back to the object itself', () {
    final g = groupIssues([_issue('Deployment', 'exporter', group: 'apps'), _issue('Deployment', 'exporter', group: 'apps')].map(OverviewIssue.fromJson)).single;
    expect(g.owner, isNull);
    expect(g.subject, const OverviewOwner(group: 'apps', kind: 'Deployment', name: 'exporter'));
  });

  for (final (label, issues) in [
    ('mixed owner/no-owner', mixed),
    ('several owner-less alerts on one object', [_issue('Deployment', 'exporter', group: 'apps'), _issue('Deployment', 'exporter', group: 'apps')]),
  ]) {
    testWidgets('renders without errors: $label', (tester) async {
      await pumpOverview(tester, _overview(issues));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('exporter'), findsWidgets);
    });
  }

  testWidgets('mixed kinds are counted as issues', (tester) async {
    await pumpOverview(tester, _overview(mixed));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('3 issues'), findsOneWidget);
  });
}
