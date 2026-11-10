import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/issues_feed.dart';
import '../../util/k8s.dart' show Severity;
import '../theme.dart';
import 'overview_api.dart';

/// Issue count for the dock's Issues tab: critical issues (red), or the
/// warnings (amber) when there are none; nothing when there are neither.
class IssuesNavBadge extends StatelessWidget {
  /// Space before the badge when it shows.
  final double leading;
  const IssuesNavBadge({super.key, this.leading = 0});

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<IssuesFeed?>();
    if (feed == null) return const SizedBox.shrink();
    final critical = feed.count(IssueSeverity.critical);
    final n = critical > 0 ? critical : feed.count(IssueSeverity.warning);
    if (n == 0) return const SizedBox.shrink();
    final c = severityColor(context, critical > 0 ? Severity.error : Severity.warn);
    final what = critical > 0 ? 'critical issue' : 'warning';
    return Padding(
      padding: EdgeInsets.only(left: leading),
      child: Tooltip(
        message: '$n $what${n == 1 ? '' : 's'}',
        child: Container(
          constraints: const BoxConstraints(minWidth: 16),
          height: 16,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)),
          child: Text('$n', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c)),
        ),
      ),
    );
  }
}
