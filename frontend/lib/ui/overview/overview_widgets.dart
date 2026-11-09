import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'overview_actions.dart';
import 'overview_api.dart';
import '../../util/text.dart';
import '../widgets/namespace_picker.dart';

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

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class OverviewHeader extends StatelessWidget {
  final NamespaceScope namespace;
  final ValueChanged<NamespaceScope>? onNamespaceChanged;
  final DateTime? updatedAt;
  final bool loading;
  final bool paused;
  final Duration interval;
  final VoidCallback onTogglePause;
  final VoidCallback? onRefresh;

  const OverviewHeader({
    super.key,
    required this.namespace,
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
          ? Text(namespace.label)
          : PageScopePicker(value: namespace, onChanged: onNamespaceChanged!),
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

/// A quiet grey bar standing in for a value that is still loading.
class SkeletonBar extends StatelessWidget {
  final double? width;
  final double height;
  const SkeletonBar({super.key, this.width, this.height = 12});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(4)),
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

  /// Some sources are still loading, so an empty list isn't "nothing wrong".
  final bool loading;
  const IssueList({super.key, required this.issues, required this.onChanged, required this.emptyText, this.loading = false});

  @override
  State<IssueList> createState() => _IssueListState();
}

class _IssueListState extends State<IssueList> {
  static const _pageSize = 60;
  final _expanded = <String>{};
  int _limit = _pageSize;

  static String _heading(IssueSeverity s) => switch (s) {
        IssueSeverity.critical => 'Errors',
        IssueSeverity.warning => 'Warnings',
        IssueSeverity.info => 'Info',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = groupIssues(widget.issues);
    if (groups.isEmpty && widget.loading) {
      return Padding(
        key: const ValueKey('pending-issues'),
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          const SkeletonBar(width: 120, height: 12),
          const SizedBox(width: 10),
          Text('Still checking…', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ]),
      );
    }
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: InlineMessage(widget.emptyText, icon: Icons.check_circle_outline),
      );
    }
    final shown = groups.take(_limit).toList();
    final counts = <IssueSeverity, int>{};
    for (final i in widget.issues) {
      counts[i.severity] = (counts[i.severity] ?? 0) + 1;
    }
    final children = <Widget>[];
    IssueSeverity? current;
    for (final g in shown) {
      if (g.severity != current) {
        current = g.severity;
        children.add(_SeverityHeading(label: _heading(current), count: counts[current] ?? 0, first: children.isEmpty));
      } else {
        children.add(Divider(height: 1, indent: 32, color: AppColors.of(context).separator.withValues(alpha: 0.7)));
      }
      children.add(IssueGroupTile(
        key: ValueKey(g.key),
        group: g,
        expanded: _expanded.contains(g.key),
        onToggle: () => setState(() => _expanded.contains(g.key) ? _expanded.remove(g.key) : _expanded.add(g.key)),
        onChanged: widget.onChanged,
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...children,
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

class _SeverityHeading extends StatelessWidget {
  final String label;
  final int count;
  final bool first;
  const _SeverityHeading({required this.label, required this.count, required this.first});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(2, first ? 2 : 14, 2, 2),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: label, style: TextStyle(color: theme.hintColor, fontWeight: FontWeight.w600)),
          TextSpan(text: '  $count', style: TextStyle(color: AppColors.of(context).faint, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
        style: theme.textTheme.labelMedium,
      ),
    );
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
    final subject = group.subject;
    final ownerRef = ObjectRef(group: subject.group, kind: subject.kind, name: subject.name, namespace: first.namespace);
    // Mixed groups (e.g. alerts on a Deployment and on its pods) count "issues".
    final kinds = {for (final i in group.issues) i.kind};
    final kindWord = kinds.length > 1 ? 'issue' : (first.kind == 'Pod' ? 'pod' : first.kind.toLowerCase());
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _IssueRow(
        issue: first,
        title: ownerRef,
        countLabel: plural(group.issues.length, kindWord),
        since: group.latestSince,
        expanded: expanded,
        onToggle: onToggle,
        actions: actions,
        onChanged: onChanged,
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.only(left: 32, bottom: 6),
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: AppColors.of(context).separator, width: 2))),
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

/// The reason as a small label on a faint tint of the severity colour.
class _ReasonChip extends StatelessWidget {
  final String text;
  final IssueSeverity severity;
  const _ReasonChip(this.text, this.severity);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = issueColor(context, severity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: theme.brightness == Brightness.dark ? 0.14 : 0.09),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(fontSize: 11.5, height: 1.4, color: theme.colorScheme.onSurface.withValues(alpha: 0.88)),
      ),
    );
  }
}

class _IssueRow extends StatefulWidget {
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
  State<_IssueRow> createState() => _IssueRowState();
}

class _IssueRowState extends State<_IssueRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final c = issueColor(context, w.issue.severity);
    final kindLabel = w.title.kind == 'PersistentVolumeClaim' ? 'PVC' : w.title.kind;
    final dense = w.dense;

    // Wrap (not Row) so narrow widths — e.g. with the sidebar open — flow
    // onto a second line instead of overflowing.
    final nameLine = Wrap(spacing: 6, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (!dense) Text(kindLabel, style: hint),
      _Link(ref: w.title, strong: !dense),
      if (w.countLabel != null) Text(w.countLabel!, style: hint?.copyWith(fontWeight: FontWeight.w600)),
      _ReasonChip(w.issue.reason, w.issue.severity),
      if (w.context2 != null)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('of ${w.context2!.kind} ', style: hint),
          Flexible(child: _Link(ref: w.context2!)),
        ]),
    ]);

    final meta = Row(mainAxisSize: MainAxisSize.min, children: [
      if (w.title.namespace != null && !dense)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: Text(w.title.namespace!, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint)),
        ),
      if (w.since != null) ...[
        const SizedBox(width: 10),
        SizedBox(width: 44, child: Align(alignment: Alignment.centerRight, child: AgeText(w.since))),
      ],
    ]);

    final icon = Padding(padding: const EdgeInsets.only(top: 1), child: Icon(issueIcon(w.issue.severity), size: 16, color: c));
    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 5 : 8, horizontal: dense ? 10 : 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!dense)
          SizedBox(
            width: 22,
            child: w.onToggle == null ? icon : Icon(w.expanded == true ? Icons.expand_more : Icons.chevron_right, size: 18, color: theme.hintColor),
          ),
        if (!dense && w.onToggle != null) ...[icon, const SizedBox(width: 4)],
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            nameLine,
            if (w.issue.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(w.issue.message, maxLines: dense ? 1 : 2, overflow: TextOverflow.ellipsis, style: hint),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        meta,
      ]),
    );

    // Actions appear over the right edge on hover or keyboard focus, so rows
    // keep one height and nothing shifts.
    final show = _hovered || _focused;
    final bg = Color.alphaBlend(colors.hover, theme.colorScheme.surface);
    final actions = w.actions.isEmpty
        ? null
        : Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (f) => setState(() => _focused = f),
              child: IgnorePointer(
                ignoring: !show,
                child: Opacity(
                  opacity: show ? 1 : 0,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 24,
                      decoration: BoxDecoration(gradient: LinearGradient(colors: [bg.withValues(alpha: 0), bg])),
                    ),
                    Container(
                      color: bg,
                      padding: const EdgeInsets.only(left: 2, right: 6),
                      alignment: Alignment.center,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final a in w.actions) ...[
                          if (a != w.actions.first) const SizedBox(width: 6),
                          QuickActionButton(action: a, onDone: w.onChanged),
                        ],
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: w.onToggle,
        hoverColor: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(color: _hovered ? colors.hover : null, borderRadius: BorderRadius.circular(6)),
          child: Stack(children: [row, ?actions]),
        ),
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
// Warning events
// ---------------------------------------------------------------------------

/// Placeholder rows for a section whose list is still loading.
class PendingRows extends StatelessWidget {
  final int rows;
  const PendingRows({super.key, this.rows = 1});

  @override
  Widget build(BuildContext context) {
    return Column(key: const ValueKey('pending-rows'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < rows; i++) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: SkeletonBar(height: 14)),
    ]);
  }
}

/// One line per reason; click a line for the whole latest message.
class WarningEventList extends StatefulWidget {
  final List<WarningReason> reasons;
  const WarningEventList({super.key, required this.reasons});

  @override
  State<WarningEventList> createState() => _WarningEventListState();
}

class _WarningEventListState extends State<WarningEventList> {
  final _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final reasons = widget.reasons;
    if (reasons.isEmpty) return const InlineMessage('No warning events in the last hour.', icon: Icons.check_circle_outline);
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < reasons.length; i++) ...[
        if (i > 0) Divider(height: 1, color: colors.separator.withValues(alpha: 0.7)),
        _eventRow(context, reasons[i], hint, colors),
      ],
    ]);
  }

  Widget _eventRow(BuildContext context, WarningReason r, TextStyle? hint, AppColors colors) {
    final theme = Theme.of(context);
    final open = _open.contains(r.reason);
    final ex = r.example;
    return Hoverable(
      onTap: () => setState(() => open ? _open.remove(r.reason) : _open.add(r.reason)),
      builder: (hovered) => Container(
        decoration: BoxDecoration(color: hovered ? colors.hover : null, borderRadius: BorderRadius.circular(6)),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            SizedBox(
              width: 44,
              child: Text('×${r.count}', textAlign: TextAlign.right, style: monoStyle(context, size: 11.5, color: colors.faint)),
            ),
            const SizedBox(width: 12),
            // Reason and example keep their width (capped); the message
            // fills what is left and is the first to be cut.
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Row(children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * 0.3),
                    child: Text(r.reason, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (ex != null) ...[
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * 0.35),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(child: Text(ex.kind == 'PersistentVolumeClaim' ? 'PVC' : ex.kind, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
                        const SizedBox(width: 4),
                        Flexible(flex: 2, child: _Link(ref: ex)),
                        if (r.objects > 1) Text(' +${r.objects - 1}', style: hint),
                      ]),
                    ),
                  ],
                  const SizedBox(width: 12),
                  Expanded(child: open ? const SizedBox.shrink() : Text(r.latestMessage, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            if (r.lastSeen != null) SizedBox(width: 60, child: Align(alignment: Alignment.centerRight, child: AgeText(r.lastSeen, suffix: ' ago'))),
          ]),
          if (open)
            Padding(
              padding: const EdgeInsets.only(left: 56, top: 4, right: 68),
              child: Text(r.latestMessage, style: hint),
            ),
        ]),
      ),
    );
  }
}
