import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/issues_feed.dart';
import '../../util/k8s.dart' show Severity;
import '../theme.dart';
import '../widgets/editorial.dart' show PageScroll;
import '../widgets/error_notice.dart';
import 'overview_api.dart';
import 'overview_widgets.dart';
import '../widgets/namespace_picker.dart' show PageScope;

/// The dock's Issues pane: the Overview's issue list, from the shared
/// [IssuesFeed], so problems stay in view while browsing other pages.
class IssuesDockView extends StatelessWidget {
  const IssuesDockView({super.key});

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<IssuesFeed?>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    if (feed == null) return const SizedBox.shrink();
    final data = feed.data;
    final issues = [for (final i in feed.issues) if (i.severity != IssueSeverity.info) i];
    final critical = feed.count(IssueSeverity.critical);
    final warnings = feed.count(IssueSeverity.warning);
    final scope = PageScope.of('overview');

    Widget summary;
    if (data == null) {
      summary = Text(feed.error == null ? 'Checking…' : 'Couldn\'t load issues', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    } else if (critical + warnings == 0) {
      summary = feed.partial
          ? Text('Still checking…', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))
          : Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.check_circle_outline, size: 14, color: severityColor(context, Severity.ok)),
              const SizedBox(width: 6),
              Text('No issues', style: theme.textTheme.bodySmall),
            ]);
    } else {
      summary = Text(
        [if (critical > 0) '$critical critical', if (warnings > 0) '$warnings warning${warnings == 1 ? '' : 's'}'].join(' · '),
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      );
    }

    final Widget body;
    if (data == null) {
      body = feed.error == null
          ? const SizedBox.shrink()
          : Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12), child: ErrorNotice(feed.error!, title: "Couldn't load issues", onRetry: feed.refresh));
    } else {
      body = PageScroll(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        children: [
          if (feed.error != null) ...[
            ErrorNotice(feed.error!, title: 'Refresh failed', note: 'Showing the last result.', onRetry: feed.refresh),
            const SizedBox(height: 8),
          ],
          IssueList(
            issues: issues,
            onChanged: feed.refresh,
            emptyText: 'Nothing needs attention.',
            loading: feed.partial,
            dense: true,
          ),
        ],
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 34,
        child: Row(children: [
          const SizedBox(width: 10),
          Flexible(child: Align(alignment: Alignment.centerLeft, child: summary)),
          if (!scope.isAll) ...[
            const SizedBox(width: 10),
            Flexible(child: Text(scope.label, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint))),
          ],
          const Spacer(),
          IconButton(
            tooltip: 'Refresh',
            icon: feed.loading ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)) : const Icon(Icons.refresh),
            onPressed: feed.loading ? null : feed.refresh,
          ),
          const SizedBox(width: 6),
        ]),
      ),
      if (feed.loading && data == null)
        const LinearProgressIndicator(minHeight: 2)
      else
        Divider(height: 1, color: colors.separator),
      Expanded(child: body),
    ]);
  }
}
