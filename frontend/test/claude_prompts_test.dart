import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/overview/overview_api.dart';
import 'package:k8sman/ui/terminal/claude_prompts.dart';

void main() {
  test('an issue prompt carries what the row knows', () {
    const pod = OverviewIssue(
      severity: IssueSeverity.critical,
      category: 'crashLoop',
      kind: 'Pod',
      group: '',
      namespace: 'prod',
      name: 'web-7f9c',
      reason: 'CrashLoopBackOff',
      message: 'container main exited 1',
      since: '2026-11-13T13:04:00Z',
      count: 6,
      owner: OverviewOwner(group: 'apps', kind: 'Deployment', name: 'web'),
    );
    expect(
      issuePrompt(IssueGroup([pod])),
      'Using the k8sman tools, investigate why Pod web-7f9c in namespace prod is CrashLoopBackOff: "container main exited 1" '
      '(since 2026-11-13T13:04:00Z, 6 restarts, owned by Deployment web). Find the root cause and suggest a fix.',
    );
    // Several pods of one owner: ask about the owner, not one pod.
    expect(issuePrompt(IssueGroup([pod, pod])), contains('2 objects of Deployment web in namespace prod'));
  });
}
