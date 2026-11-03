import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'overview_actions.dart';
import 'overview_api.dart';

Color issueColor(BuildContext context, IssueSeverity s) => severityColor(context, s.badge);

IconData issueIcon(IssueSeverity s) => switch (s) {
      IssueSeverity.critical => Icons.error,
      IssueSeverity.warning => Icons.warning_amber_rounded,
      IssueSeverity.info => Icons.info_outline,
    };

/// Opens [ref] in the detail sidebar, replacing the stack (like a table row).
void openObject(BuildContext context, ObjectRef ref) {
  final app = context.read<AppState>();
  final t = app.typeFor(ref.group, ref.kind);
  if (t == null) return;
  app.openDetail(DetailTarget(type: t, name: ref.name, namespace: t.namespaced ? ref.namespace : null));
}

String _plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

String _kindPlural(String kind) {
  final k = kind == 'PersistentVolumeClaim' ? 'PVC' : kind;
  return k.endsWith('s') ? '${k}es' : '${k}s';
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

/// Sentinel for "all namespaces" in the scope picker.
const _all = '\u0000all';

class OverviewHeader extends StatelessWidget {
  final String? namespace;

  /// Namespaces offered in the scope picker (null selection = all).
  final List<String> namespaces;
  final ValueChanged<String?>? onNamespaceChanged;
  final DateTime? updatedAt;
  final bool loading;
  final bool paused;
  final Duration interval;
  final VoidCallback onTogglePause;
  final VoidCallback? onRefresh;

  const OverviewHeader({
    super.key,
    required this.namespace,
    this.namespaces = const [],
    this.onNamespaceChanged,
    required this.updatedAt,
    required this.loading,
    required this.paused,
    required this.interval,
    required this.onTogglePause,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return PageHeader(
      title: 'Overview',
      subtitle: onNamespaceChanged == null
          ? Text(namespace ?? 'All namespaces')
          : MenuSelect<String>(
              tooltip: 'Scope',
              value: namespace ?? _all,
              options: [
                (_all, const Text('All namespaces')),
                for (final ns in namespaces) (ns, Text(ns, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => onNamespaceChanged!(v == _all ? null : v),
            ),
      actions: [
        if (loading) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
        if (updatedAt != null)
          Tooltip(
            message: paused ? 'Auto-refresh paused' : 'Refreshes every ${interval.inSeconds}s',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (paused) Text('Paused · ', style: hint),
              AgeText(updatedAt!.toUtc().toIso8601String(), suffix: ' ago'),
            ]),
          ),
        IconButton(
          tooltip: paused ? 'Resume auto-refresh (every ${interval.inSeconds}s)' : 'Pause auto-refresh',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          icon: Icon(paused ? Icons.play_arrow : Icons.pause),
          onPressed: onTogglePause,
        ),
        IconButton(
          tooltip: 'Refresh now',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh),
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Inventory strip: totals per type
// ---------------------------------------------------------------------------

class InventoryStrip extends StatelessWidget {
  final OverviewData data;
  const InventoryStrip({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <(String, String, String?)>[];
    void add(String type, String label, String good, {String? extra}) {
      final total = data.count(type, 'total');
      if (total == 0) return;
      items.add((label, '${data.count(type, good)}/$total', extra));
    }

    final pods = data.count('pods', 'total');
    if (pods > 0) {
      final completed = data.count('pods', 'completed');
      items.add(('pods ready', '${data.count('pods', 'ready')}/${pods - completed}', completed > 0 ? '+$completed completed' : null));
    }
    add('deployments', 'deployments', 'healthy');
    add('statefulSets', 'statefulsets', 'healthy');
    add('daemonSets', 'daemonsets', 'healthy');
    final jobs = data.count('jobs', 'total');
    if (jobs > 0) {
      final failed = data.count('jobs', 'failed');
      items.add(('jobs succeeded', '${data.count('jobs', 'succeeded')}/$jobs', failed > 0 ? '$failed failed' : null));
    }
    final cron = data.count('cronJobs', 'total');
    if (cron > 0) items.add((cron == 1 ? 'cronjob' : 'cronjobs', '$cron', null));
    add('nodes', 'nodes ready', 'ready');
    add('pvcs', 'PVCs bound', 'bound');

    final numStyle = theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Wrap(spacing: 18, runSpacing: 4, children: [
      for (final (label, value, extra) in items)
        Text.rich(TextSpan(children: [
          TextSpan(text: value, style: numStyle),
          TextSpan(text: ' $label', style: hint),
          if (extra != null) TextSpan(text: ' ($extra)', style: hint),
        ])),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Summary tiles
// ---------------------------------------------------------------------------

class SummaryTiles extends StatelessWidget {
  final OverviewData data;
  final String? namespace;
  final String? selected;
  final ValueChanged<String> onSelect;
  const SummaryTiles({super.key, required this.data, required this.namespace, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final problems = data.categories.where((c) => c.severity != IssueSeverity.info).toList();
    final info = data.categories.where((c) => c.severity == IssueSeverity.info).toList();
    return LayoutBuilder(builder: (context, box) {
      // 2 to 6 columns; tiles stretch to fill each row.
      const gap = 10.0;
      final cols = (box.maxWidth / 190).floor().clamp(2, 6);
      final w = ((box.maxWidth - gap * (cols - 1)) / cols).floorToDouble();
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (problems.isEmpty)
          _HealthyTile(data: data, namespace: namespace)
        else
          Wrap(spacing: gap, runSpacing: gap, children: [
            for (final c in problems)
              SizedBox(
                width: w,
                child: _CategoryTile(category: c, sublabel: _sublabel(c), selected: selected == c.id, onTap: () => onSelect(c.id)),
              ),
          ]),
        if (info.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final c in info)
              _InfoChip(category: c, tooltip: _sublabel(c), selected: selected == c.id, onTap: () => onSelect(c.id)),
          ]),
        ],
      ]);
    });
  }

  String _sublabel(OverviewCategory c) {
    final issues = data.issues.where((i) => i.category == c.id).toList();
    if (issues.isEmpty) return c.section;
    final first = issues.first;
    if (first.kind == 'Pod') {
      final owners = {for (final i in issues) if (i.owner != null) '${i.namespace}/${i.owner!.kind}/${i.owner!.name}'};
      final bare = issues.where((i) => i.owner == null).length;
      if (issues.length == 1) return first.owner != null ? 'pod of ${first.owner!.name}' : 'pod ${first.name}';
      if (owners.length == 1 && bare == 0) return '${_plural(issues.length, 'pod')} of ${first.owner!.name}';
      return '${_plural(issues.length, 'pod')} · ${_plural(owners.length + bare, 'workload')}';
    }
    if (issues.length == 1) return '${first.kind == 'PersistentVolumeClaim' ? 'PVC' : first.kind.toLowerCase()} ${first.name}';
    return '${issues.length} ${_kindPlural(first.kind).toLowerCase()}';
  }
}

class _CategoryTile extends StatelessWidget {
  final OverviewCategory category;
  final String sublabel;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryTile({required this.category, required this.sublabel, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = issueColor(context, category.severity);
    final muted = category.severity == IssueSeverity.info;
    return Material(
      color: selected ? c.withValues(alpha: 0.16) : theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: selected ? c : theme.colorScheme.outlineVariant.withValues(alpha: 0.5), width: selected ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: selected ? 'Show all issues' : 'Show only ${category.label}',
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: c.withValues(alpha: muted ? 0.5 : 1), width: 3))),
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('${category.count}',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: muted ? theme.colorScheme.onSurface : c,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    )),
                const Spacer(),
                Icon(issueIcon(category.severity), size: 16, color: c.withValues(alpha: 0.85)),
              ]),
              const SizedBox(height: 6),
              Text(category.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(sublabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Informational categories (paused, suspended, rolling, cordoned) are not
/// problems, so they get a quiet chip rather than a tile.
class _InfoChip extends StatelessWidget {
  final OverviewCategory category;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  const _InfoChip({required this.category, required this.tooltip, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = issueColor(context, category.severity);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? c.withValues(alpha: 0.16) : theme.colorScheme.surfaceContainerLow,
        shape: StadiumBorder(side: BorderSide(color: selected ? c : theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(issueIcon(category.severity), size: 13, color: c),
              const SizedBox(width: 6),
              Text(category.label, style: theme.textTheme.bodySmall),
              const SizedBox(width: 6),
              Text('${category.count}', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700, color: c)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _HealthyTile extends StatelessWidget {
  final OverviewData data;
  final String? namespace;
  const _HealthyTile({required this.data, required this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = severityColor(context, Severity.ok);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: ok.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ok.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Icon(Icons.check_circle_outline, color: ok, size: 30),
        const SizedBox(width: 14),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('All healthy', style: theme.textTheme.titleMedium?.copyWith(color: ok, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              'Nothing is crashlooping, stuck or failing ${namespace == null ? 'in the cluster' : 'in $namespace'}.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Issues
// ---------------------------------------------------------------------------

class IssueList extends StatefulWidget {
  final List<OverviewIssue> issues;
  final VoidCallback onChanged;
  final String emptyText;
  const IssueList({super.key, required this.issues, required this.onChanged, required this.emptyText});

  @override
  State<IssueList> createState() => _IssueListState();
}

class _IssueListState extends State<IssueList> {
  static const _pageSize = 60;
  final _expanded = <String>{};
  int _limit = _pageSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = groupIssues(widget.issues);
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: InlineMessage(widget.emptyText, icon: Icons.check_circle_outline),
      );
    }
    final shown = groups.take(_limit).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < shown.length; i++) ...[
        if (i > 0) const Divider(height: 1),
        IssueGroupTile(
          key: ValueKey(shown[i].key),
          group: shown[i],
          expanded: _expanded.contains(shown[i].key),
          onToggle: () => setState(() => _expanded.contains(shown[i].key) ? _expanded.remove(shown[i].key) : _expanded.add(shown[i].key)),
          onChanged: widget.onChanged,
        ),
      ],
      if (groups.length > shown.length)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _limit += _pageSize),
              child: Text('Show ${groups.length - shown.length} more', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
            ),
          ),
        ),
    ]);
  }
}

/// One row per owner group (expandable to its pods) or per ungrouped object.
class IssueGroupTile extends StatelessWidget {
  final IssueGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onChanged;
  const IssueGroupTile({super.key, required this.group, required this.expanded, required this.onToggle, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final first = group.first;
    final owner = group.owner;
    final multi = group.issues.length > 1;
    final app = context.watch<AppState>();
    final actions = app.readOnly ? const <QuickAction>[] : quickActionsFor(group, includeObject: !multi);

    if (!multi) {
      return _IssueRow(
        issue: first,
        title: ObjectRef(group: first.group, kind: first.kind, name: first.name, namespace: first.namespace),
        context2: owner == null ? null : ObjectRef(group: owner.group, kind: owner.kind, name: owner.name, namespace: first.namespace),
        since: first.since,
        actions: actions,
        onChanged: onChanged,
      );
    }
    final ownerRef = ObjectRef(group: owner!.group, kind: owner.kind, name: owner.name, namespace: first.namespace);
    final kindWord = first.kind == 'Pod' ? 'pod' : first.kind.toLowerCase();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _IssueRow(
        issue: first,
        title: ownerRef,
        countLabel: _plural(group.issues.length, kindWord),
        since: group.latestSince,
        expanded: expanded,
        onToggle: onToggle,
        actions: actions,
        onChanged: onChanged,
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.only(left: 30, bottom: 6),
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6), width: 2))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final i in group.issues)
                _IssueRow(
                  issue: i,
                  title: i.ref,
                  since: i.since,
                  dense: true,
                  actions: app.readOnly ? const [] : quickActionsFor(IssueGroup([i]), includeOwner: false),
                  onChanged: onChanged,
                ),
            ]),
          ),
        ),
    ]);
  }
}

class _IssueRow extends StatelessWidget {
  final OverviewIssue issue;
  final ObjectRef title;

  /// The owner, shown under an ungrouped pod.
  final ObjectRef? context2;
  final String? countLabel;
  final String? since;
  final bool dense;
  final bool? expanded;
  final VoidCallback? onToggle;
  final List<QuickAction> actions;
  final VoidCallback onChanged;

  const _IssueRow({
    required this.issue,
    required this.title,
    required this.actions,
    required this.onChanged,
    this.context2,
    this.countLabel,
    this.since,
    this.dense = false,
    this.expanded,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final c = issueColor(context, issue.severity);
    final kindLabel = title.kind == 'PersistentVolumeClaim' ? 'PVC' : title.kind;

    // Wrap (not Row) so narrow widths — e.g. with the sidebar open — flow
    // onto a second line instead of overflowing.
    final nameLine = Wrap(spacing: 6, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (!dense) Text(kindLabel, style: hint),
      _Link(ref: title, strong: !dense),
      if (countLabel != null) Text(countLabel!, style: hint?.copyWith(fontWeight: FontWeight.w600)),
      StatusBadge(issue.reason, dense: true, severity: issue.severity.badge),
      if (context2 != null)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('of ${context2!.kind} ', style: hint),
          Flexible(child: _Link(ref: context2!)),
        ]),
    ]);

    final meta = Row(mainAxisSize: MainAxisSize.min, children: [
      if (title.namespace != null && !dense)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: Text(title.namespace!, overflow: TextOverflow.ellipsis, style: hint),
        ),
      if (since != null) ...[
        const SizedBox(width: 10),
        SizedBox(width: 48, child: Align(alignment: Alignment.centerRight, child: AgeText(since))),
      ],
    ]);

    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 5 : 8, horizontal: dense ? 10 : 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!dense)
            SizedBox(
              width: 24,
              child: onToggle == null
                  ? Padding(padding: const EdgeInsets.only(top: 1), child: Icon(issueIcon(issue.severity), size: 17, color: c))
                  : Icon(expanded == true ? Icons.expand_more : Icons.chevron_right, size: 20, color: theme.hintColor),
            ),
          if (!dense && onToggle != null) ...[
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(issueIcon(issue.severity), size: 17, color: c)),
            const SizedBox(width: 4),
          ],
          const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              nameLine,
              if (issue.message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(issue.message, maxLines: dense ? 1 : 2, overflow: TextOverflow.ellipsis, style: hint),
                ),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            meta,
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(spacing: 6, children: [for (final a in actions) QuickActionButton(action: a, onDone: onChanged)]),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// Object name that opens the sidebar.
class _Link extends StatelessWidget {
  final ObjectRef ref;
  final bool strong;
  const _Link({required this.ref, this.strong = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = context.read<AppState>().typeFor(ref.group, ref.kind) != null;
    final style = (strong ? theme.textTheme.bodyMedium : theme.textTheme.bodySmall)?.copyWith(
      color: known ? theme.colorScheme.primary : null,
      fontWeight: strong ? FontWeight.w600 : null,
    );
    final text = Text(ref.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    if (!known) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => openObject(context, ref), child: Tooltip(message: 'Open ${ref.kind} ${ref.name}', child: text)),
    );
  }
}

// ---------------------------------------------------------------------------
// Nodes
// ---------------------------------------------------------------------------

class NodesStrip extends StatelessWidget {
  final List<NodeHealth> nodes;
  const NodesStrip({super.key, required this.nodes});

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: [for (final n in nodes) _NodeChip(node: n)]);
  }
}

class _NodeChip extends StatelessWidget {
  final NodeHealth node;
  const _NodeChip({required this.node});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sev = !node.ready ? Severity.error : (node.pressure.isNotEmpty ? Severity.warn : (node.cordoned ? Severity.warn : Severity.ok));
    final c = severityColor(context, sev);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: sev == Severity.ok ? theme.colorScheme.outlineVariant.withValues(alpha: 0.5) : c.withValues(alpha: 0.6)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => openObject(context, ObjectRef(kind: 'Node', name: node.name)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(node.name, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (node.roles.isNotEmpty) ...[const SizedBox(width: 6), Text(node.roles.join(','), style: hint)],
            const SizedBox(width: 10),
            Text(_plural(node.pods, 'pod'), style: hint),
            if (!node.ready) ...[const SizedBox(width: 8), const StatusBadge('NotReady', dense: true, severity: Severity.error)],
            for (final p in node.pressure) ...[const SizedBox(width: 6), StatusBadge(p, dense: true, severity: Severity.warn)],
            if (node.cordoned) ...[const SizedBox(width: 6), const StatusBadge('Cordoned', dense: true, severity: Severity.warn)],
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Warning events
// ---------------------------------------------------------------------------

class WarningEventList extends StatelessWidget {
  final List<WarningReason> reasons;
  const WarningEventList({super.key, required this.reasons});

  @override
  Widget build(BuildContext context) {
    if (reasons.isEmpty) return const InlineMessage('No warning events in the last hour.', icon: Icons.check_circle_outline);
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final warn = severityColor(context, Severity.warn);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < reasons.length; i++) ...[
        if (i > 0) const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 52,
              child: Text('×${reasons[i].count}', textAlign: TextAlign.right, style: monoStyle(context, size: 12, color: warn).copyWith(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(reasons[i].reason, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  if (reasons[i].example != null) ...[
                    const SizedBox(width: 8),
                    Text(reasons[i].example!.kind == 'PersistentVolumeClaim' ? 'PVC' : reasons[i].example!.kind, style: hint),
                    const SizedBox(width: 4),
                    Flexible(child: _Link(ref: reasons[i].example!)),
                  ],
                  if (reasons[i].objects > 1) ...[
                    const SizedBox(width: 6),
                    Text('+${reasons[i].objects - 1} more', style: hint),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(reasons[i].latestMessage, maxLines: 2, overflow: TextOverflow.ellipsis, style: hint),
              ]),
            ),
            const SizedBox(width: 8),
            if (reasons[i].lastSeen != null) AgeText(reasons[i].lastSeen, suffix: ' ago'),
          ]),
        ),
      ],
    ]);
  }
}
