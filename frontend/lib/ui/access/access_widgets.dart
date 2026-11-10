/// Building blocks of the Access workspace: subject icons, grant-path cards,
/// the cell explanation pane with "Verify with API server".
library;

import 'package:flutter/material.dart';

import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart';
import 'access_api.dart';

IconData subjectIcon(String kind) => switch (kind) {
      'ServiceAccount' => Icons.smart_toy_outlined,
      'Group' => Icons.groups_outlined,
      _ => Icons.person_outline,
    };

/// "ServiceAccount rbac-demo/app" with an icon.
class SubjectLabel extends StatelessWidget {
  final RbacSubject subject;
  final TextStyle? style;
  final bool showKind;
  const SubjectLabel(this.subject, {super.key, this.style, this.showKind = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = subject.kind == 'Group' ? wellKnownGroup(subject.name) : null;
    final text = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(subjectIcon(subject.kind), size: 14, color: theme.hintColor),
      const SizedBox(width: 5),
      Flexible(
        child: Text.rich(
          TextSpan(children: [
            if (showKind) TextSpan(text: '${subject.kind} ', style: TextStyle(color: theme.hintColor)),
            TextSpan(text: subject.label),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style ?? theme.textTheme.bodySmall,
        ),
      ),
    ]);
    return known == null ? text : Tooltip(message: '${subject.name}: $known', child: text);
  }
}

/// Small clickable RBAC object name (opens the inspector).
class RbacLink extends StatelessWidget {
  final RbacRef ref;
  final String? label;
  const RbacLink(this.ref, {super.key, this.label});

  @override
  Widget build(BuildContext context) {
    if (ref.isEmpty || ref.kind == 'SelfSubjectRulesReview') {
      return Text(label ?? ref.name, style: Theme.of(context).textTheme.bodySmall);
    }
    return ResourceLink(ref.objectRef, label: label ?? ref.label);
  }
}

/// The rule, with wildcards called out.
class RuleText extends StatelessWidget {
  final PolicyRuleData rule;
  const RuleText(this.rule, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = monoStyle(context, size: 11);
    final warn = severityColor(context, Severity.warn);
    TextSpan list(String key, List<String> v) => TextSpan(children: [
          TextSpan(text: '$key: ', style: mono.copyWith(color: theme.hintColor)),
          for (final (i, s) in v.indexed) ...[
            if (i > 0) TextSpan(text: ', ', style: mono),
            TextSpan(text: s.isEmpty ? '""' : s, style: s.contains('*') ? mono.copyWith(color: warn, fontWeight: FontWeight.w600) : mono),
          ],
          const TextSpan(text: '\n'),
        ]);
    return Text.rich(TextSpan(children: [
      if (rule.nonResourceURLs.isNotEmpty) list('nonResourceURLs', rule.nonResourceURLs) else ...[
        list('apiGroups', rule.apiGroups),
        list('resources', rule.resources),
        if (rule.resourceNames.isNotEmpty) list('resourceNames', rule.resourceNames),
      ],
      list('verbs', rule.verbs),
    ]));
  }
}

/// One grant path: binding → role (→ aggregation chain) → rule.
class PathCard extends StatelessWidget {
  final GrantPath path;
  const PathCard(this.path, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    final p = path;
    Widget arrow() => Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.arrow_forward, size: 12, color: theme.hintColor));
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      decoration: BoxDecoration(color: chipFill(context), borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 2, children: [
          if (!p.binding.isEmpty) ...[
            Text(p.binding.kind == 'ClusterRoleBinding' ? 'CRB ' : 'RB ', style: hint),
            RbacLink(p.binding),
            arrow(),
          ],
          if (!p.role.isEmpty) ...[
            Text(p.role.kind == 'ClusterRole' ? 'ClusterRole ' : '${p.role.kind} ', style: hint),
            RbacLink(p.role, label: p.role.name),
          ],
          if (p.aggregated) ...[
            for (final v in p.via) ...[arrow(), RbacLink(RbacRef('ClusterRole', v), label: v)],
            arrow(),
            RbacLink(p.source, label: p.source.name),
          ],
        ]),
        if (p.aggregated) Text('Aggregated: ${p.role.name} picks up ${p.source.name}\'s rules through its aggregationRule', style: hint),
        if (p.subject != null && p.subject!.kind == 'Group')
          Text('Through group ${p.subject!.name}${wellKnownGroup(p.subject!.name) == null ? '' : ' (${wellKnownGroup(p.subject!.name)})'}', style: hint),
        if (p.scope.isNotEmpty && p.scope != 'cluster') Text('Only in namespace ${p.scope}', style: hint),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('rule ${p.index + 1}  ', style: hint),
          Expanded(child: RuleText(p.rule)),
        ]),
      ]),
    );
  }
}

/// Why a subject can (or can't) do something: every path, plus a button
/// to ask the API server (SubjectAccessReview) and compare.
class CellExplanation extends StatefulWidget {
  final PermissionMatrixData data;
  final MatrixRow row;
  final String verb;

  /// The subject, for SubjectAccessReview; null = the app's own identity
  /// (SelfSubjectAccessReview).
  final RbacSubject? subject;
  final List<String> groups;
  final AccessApi api;
  final VoidCallback? onClose;
  const CellExplanation({super.key, required this.data, required this.row, required this.verb, this.subject, this.groups = const [], required this.api, this.onClose});

  @override
  State<CellExplanation> createState() => _CellExplanationState();
}

class _CellExplanationState extends State<CellExplanation> {
  Future<CheckResult>? _check;
  final _name = TextEditingController();

  @override
  void didUpdateWidget(CellExplanation old) {
    super.didUpdateWidget(old);
    if (old.row.key != widget.row.key || old.verb != widget.verb || old.subject != widget.subject || old.data.namespace != widget.data.namespace) {
      _check = null;
      _name.clear();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  AccessRequest get _request => AccessRequest(
        verb: widget.verb == '*' ? 'get' : widget.verb,
        group: widget.row.group == '*' ? '' : widget.row.group,
        resource: widget.row.resource,
        namespace: widget.row.namespaced && widget.data.namespace.isNotEmpty ? widget.data.namespace : null,
        name: _name.text.trim().isEmpty ? (widget.row.cells[widget.verb]?.names.firstOrNull) : _name.text.trim(),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final c = widget.row.cells[widget.verb];
    final paths = [for (final i in c?.paths ?? const <int>[]) if (i < widget.data.paths.length) widget.data.paths[i]];
    final where = widget.data.namespace.isEmpty ? (widget.row.namespaced ? 'in every namespace' : 'cluster-wide') : 'in ${widget.data.namespace}';
    final what = widget.verb == '*' ? 'every verb on' : widget.verb;
    return PageScroll(padding: const EdgeInsets.fromLTRB(14, 10, 14, 16), children: [
      Row(children: [
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$what ', style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: widget.row.resource, style: monoStyle(context, size: 12.5).copyWith(fontWeight: FontWeight.w600)),
              TextSpan(text: '  ${widget.row.groupLabel}', style: hint),
            ]),
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (widget.onClose != null) IconButton(tooltip: 'Close', iconSize: 16, visualDensity: VisualDensity.compact, icon: const Icon(Icons.close), onPressed: widget.onClose),
      ]),
      const SizedBox(height: 6),
      if (c == null)
        Text('Not allowed $where. No binding grants a rule that matches.', style: hint)
      else ...[
        Row(children: [
          StatusBadge(c.limited ? 'only named objects' : 'allowed', severity: c.limited ? Severity.info : Severity.ok),
          const SizedBox(width: 8),
          Flexible(child: Text(where, style: hint)),
        ]),
        if (c.limited) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Only: ${c.names.join(', ')}', style: hint)),
        if (c.danger != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 15, color: severityColor(context, Severity.warn)),
              const SizedBox(width: 6),
              Expanded(child: Text(c.danger!, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn)))),
            ]),
          ),
        const SizedBox(height: 10),
        Text('${paths.length} grant${paths.length == 1 ? '' : 's'}', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        for (final p in paths) PathCard(p),
      ],
      const SizedBox(height: 10),
      const Divider(),
      const SizedBox(height: 6),
      Text('Verify with the API server', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text(
        widget.subject == null
            ? 'Asks a SelfSubjectAccessReview. Nothing is changed.'
            : 'Asks a SubjectAccessReview as ${widget.subject!.label}. Nothing is changed; the review includes every authorizer, not just RBAC.',
        style: hint,
      ),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: SizedBox(
            height: 28,
            child: TextField(controller: _name, style: theme.textTheme.bodySmall, decoration: const InputDecoration(hintText: 'Object name (optional)')),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: () {
            final f = widget.api.check(_request, subject: widget.subject, groups: widget.groups);
            setState(() {
              _check = f;
            });
          },
          child: const Text('Verify'),
        ),
      ]),
      if (_check != null)
        FutureBuilder<CheckResult>(
          future: _check,
          builder: (context, snap) {
            if (snap.hasError) {
              final e = snap.error!;
              return Padding(padding: const EdgeInsets.only(top: 8), child: ErrorNotice(e));
            }
            if (!snap.hasData) return const Padding(padding: EdgeInsets.only(top: 8), child: SectionSpinner());
            return Padding(padding: const EdgeInsets.only(top: 8), child: CheckResultView(snap.data!, request: _request));
          },
        ),
    ]);
  }
}

/// The API server's answer, and whether the local resolver agrees.
class CheckResultView extends StatelessWidget {
  final CheckResult result;
  final AccessRequest request;
  const CheckResultView(this.result, {super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final r = result;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        StatusBadge(r.allowed ? 'allowed' : (r.denied ? 'denied' : 'not allowed'), severity: r.allowed ? Severity.ok : Severity.error),
        const SizedBox(width: 8),
        Expanded(child: Text(request.label + (request.namespace == null ? '' : ' in ${request.namespace}'), style: monoStyle(context, size: 11))),
      ]),
      if (r.reason.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: SelectableText(r.reason, style: hint)),
      if (r.evaluationError != null) Padding(padding: const EdgeInsets.only(top: 4), child: InlineMessage(r.evaluationError!, isError: true)),
      if (r.agree != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Icon(r.agree! ? Icons.check_circle_outline : Icons.help_outline, size: 14, color: severityColor(context, r.agree! ? Severity.ok : Severity.warn)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                r.agree!
                    ? 'Matches the RBAC analysis (${r.resolverPaths.length} grant${r.resolverPaths.length == 1 ? '' : 's'}).'
                    : r.allowed
                        ? 'The API server allows this but no RBAC binding does: another authorizer (Node, webhook) or system:masters grants it.'
                        : 'RBAC bindings grant this, but the API server denied it (another authorizer denied, or RBAC changed since the analysis).',
                style: hint,
              ),
            ),
          ]),
        ),
    ]);
  }
}

/// A list of the subject's bindings with scope badges.
class BindingList extends StatelessWidget {
  final List<BindingSummary> bindings;
  final void Function(BindingSummary b)? onRemove;
  const BindingList(this.bindings, {super.key, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    if (bindings.isEmpty) return Text('No bindings name this subject.', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final b in bindings)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: StatusBadge(b.scope == 'cluster' ? 'cluster' : b.scope, dense: true, severity: b.scope == 'cluster' ? Severity.warn : Severity.info),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                  RbacLink(b.role, label: b.role.name),
                  if (b.roleMissing) Text('  missing', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)),
                ]),
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('via ', style: hint),
                  RbacLink(b.binding, label: b.binding.name),
                  if (b.inherited) Text('  as ${b.subject.name}', style: hint),
                ]),
              ]),
            ),
            if (onRemove != null && !b.inherited)
              IconButton(
                tooltip: 'Remove from ${b.binding.name}…',
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.person_remove_outlined),
                onPressed: () => onRemove!(b),
              ),
          ]),
        ),
    ]);
  }
}

/// Matrix legend.
class MatrixLegend extends StatelessWidget {
  const MatrixLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    Widget dot(Color c, {bool hollow = false}) => Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(shape: BoxShape.circle, color: hollow ? null : c.withValues(alpha: 0.85), border: hollow ? Border.all(color: c, width: 1.5) : null),
        );
    return Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [dot(theme.colorScheme.primary), const SizedBox(width: 4), Text('allowed', style: hint)]),
      Row(mainAxisSize: MainAxisSize.min, children: [dot(theme.colorScheme.primary, hollow: true), const SizedBox(width: 4), Text('named objects only', style: hint)]),
      Row(mainAxisSize: MainAxisSize.min, children: [dot(severityColor(context, Severity.warn)), const SizedBox(width: 4), Text('sensitive', style: hint)]),
    ]);
  }
}

