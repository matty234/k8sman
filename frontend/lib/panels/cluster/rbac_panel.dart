import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/access/access_api.dart';
import '../../ui/access/access_apply.dart';
import '../../ui/access/access_view.dart';
import '../../ui/access/grant_dialog.dart';
import '../../ui/access/permission_matrix.dart';
import '../../ui/access/role_editor.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'logic.dart';
import 'widgets.dart';
import '../../ui/inspector/inspector.dart' show Callout;

const rbacGroup = 'rbac.authorization.k8s.io';

class RolePanel extends ResourcePanel {
  const RolePanel();

  @override
  Set<String> get kinds => {'$rbacGroup/Role', '$rbacGroup/ClusterRole'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final theme = Theme.of(context);
    final isCluster = ctx.type.kind == 'ClusterRole' || ctx.object['kind'] == 'ClusterRole';
    final rules = asMapList(ctx.object['rules']);
    final dangers = rulesDangers(rules);
    final agg = asMap(ctx.object['aggregationRule']);
    final selectors = asMapList(agg['clusterRoleSelectors']);
    final into = aggregatesInto(asMap(ctx.metadata['labels']));
    final role = RbacRef(isCluster ? 'ClusterRole' : 'Role', ctx.name, isCluster ? null : ctx.namespace);
    // Big (typically aggregated) roles start with the matrix folded.
    final matrixRows = matrixFromRules(rules, role: role).rows.length;
    return [
      if (rules.isNotEmpty)
        DetailSection(
          title: 'Permission matrix',
          icon: Icons.grid_on,
          initiallyExpanded: matrixRows <= 24,
          trailing: _RoleActions(ctx: ctx, role: role),
          child: RoleRulesMatrix(rules: rules, role: role),
        ),
      DetailSection(
        title: 'Rules',
        icon: Icons.rule,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dangers.isNotEmpty) ...[const StatusBadge('dangerous', dense: true, severity: Severity.error), const SizedBox(width: 6)],
          Text('${rules.length}', style: theme.textTheme.labelSmall),
        ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DangerCallout(dangers),
          if (selectors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('Rules are aggregated by the controller from matching ClusterRoles; edits are overwritten.',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
            ),
          RulesTable(rules),
        ]),
      ),
      if (isCluster && (selectors.isNotEmpty || into.isNotEmpty))
        DetailSection(
          title: 'Aggregation',
          icon: Icons.merge_type,
          child: KeyValueTable([
            ('Aggregates from',
                selectors.isEmpty
                    ? null
                    : Wrap(spacing: 4, runSpacing: 4, children: [
                        for (final s in selectors) Chipish(text: selectorToString(s).isEmpty ? '<all>' : selectorToString(s)),
                      ])),
            ('Aggregated into',
                into.isEmpty
                    ? null
                    : Wrap(spacing: 8, runSpacing: 4, children: [
                        for (final n in into) ResourceLink(ObjectRef(group: rbacGroup, kind: 'ClusterRole', name: n), label: n),
                      ])),
          ], keyWidth: 120),
        ),
      DetailSection(
        title: 'Bound by',
        icon: Icons.link,
        child: _BoundBy(key: ValueKey(ctx.uid), api: ctx.api, kind: isCluster ? 'ClusterRole' : 'Role', name: ctx.name, namespace: ctx.namespace),
      ),
    ];
  }
}

class _BoundBy extends StatefulWidget {
  final ApiClient api;
  final String kind;
  final String name;
  final String? namespace;
  const _BoundBy({super.key, required this.api, required this.kind, required this.name, this.namespace});

  @override
  State<_BoundBy> createState() => _BoundByState();
}

class _BoundByState extends State<_BoundBy> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<List<Json>> _fetch() async {
    final rbs = widget.api.items(const ResourceRef(group: rbacGroup, resource: 'rolebindings'),
        namespace: widget.kind == 'Role' ? widget.namespace : null);
    final crbs = widget.kind == 'ClusterRole'
        ? widget.api.items(const ResourceRef(group: rbacGroup, resource: 'clusterrolebindings'))
        : Future.value(const <Json>[]);
    final all = await Future.wait([rbs, crbs]);
    return [
      ...bindingsFor(all[1], kind: widget.kind, name: widget.name),
      ...bindingsFor(all[0], kind: widget.kind, name: widget.name, namespace: widget.namespace),
    ];
  }

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
        future: _future,
        builder: (context, bindings) {
          if (bindings.isEmpty) {
            return InlineMessage('No bindings reference this ${widget.kind}: it grants nothing to anyone${widget.kind == 'ClusterRole' ? ' (unless aggregated)' : ''}');
          }
          final theme = Theme.of(context);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final b in bindings)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    StatusBadge(
                      b['kind'] == 'ClusterRoleBinding' || dig(b, ['metadata', 'namespace']) == null ? 'cluster-wide' : 'ns: ${dig(b, ['metadata', 'namespace'])}',
                      dense: true,
                      severity: dig(b, ['metadata', 'namespace']) == null ? Severity.warn : Severity.info,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ResourceLink(
                          ObjectRef(
                            group: rbacGroup,
                            kind: dig(b, ['metadata', 'namespace']) == null ? 'ClusterRoleBinding' : 'RoleBinding',
                            name: '${dig(b, ['metadata', 'name'])}',
                            namespace: dig<String>(b, ['metadata', 'namespace']),
                          ),
                          label: '${dig(b, ['metadata', 'name'])}',
                        ),
                      ),
                    ),
                  ]),
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 2),
                    child: asMapList(b['subjects']).isEmpty
                        ? Text('no subjects', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor))
                        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            for (final s in asMapList(b['subjects'])) SubjectRow(s, bindingNamespace: dig<String>(b, ['metadata', 'namespace'])),
                          ]),
                  ),
                ]),
              ),
          ]);
        },
      );
}

class BindingPanel extends ResourcePanel {
  const BindingPanel();

  @override
  Set<String> get kinds => {'$rbacGroup/RoleBinding', '$rbacGroup/ClusterRoleBinding'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final theme = Theme.of(context);
    final roleRef = asMap(ctx.object['roleRef']);
    final refKind = '${roleRef['kind'] ?? ''}';
    final refName = '${roleRef['name'] ?? ''}';
    final ns = ctx.namespace;
    final subjects = asMapList(ctx.object['subjects']);
    final scope = ns == null
        ? 'Grants these permissions cluster-wide, in every namespace.'
        : (refKind == 'ClusterRole'
            ? 'Grants the ClusterRole\'s permissions only within namespace $ns.'
            : 'Grants the Role\'s permissions within namespace $ns.');
    return [
      DetailSection(
        title: 'Role reference',
        icon: Icons.badge_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            StatusBadge(refKind, dense: true, severity: refKind == 'ClusterRole' ? Severity.warn : Severity.info),
            const SizedBox(width: 8),
            ResourceLink(ObjectRef(group: rbacGroup, kind: refKind, name: refName, namespace: refKind == 'Role' ? ns : null), label: refName),
          ]),
          const SizedBox(height: 4),
          Text(scope, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        ]),
      ),
      DetailSection(
        title: 'Subjects',
        icon: Icons.people_outline,
        trailing: Text('${subjects.length}', style: theme.textTheme.labelSmall),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (subjects.isEmpty) const InlineMessage('No subjects: this binding grants nothing'),
          for (final s in subjects)
            Row(children: [
              Expanded(child: SubjectRow(s, bindingNamespace: ns)),
              _SubjectActions(ctx: ctx, subject: _subjectOf(s, ns)),
            ]),
          if (!ctx.app.readOnly)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.person_add_alt, size: 15),
                label: const Text('Grant this role to someone else…'),
                onPressed: () => showGrantDialog(context, api: AccessApi(ctx.api), role: RbacRef(refKind, refName, refKind == 'Role' ? ns : null), namespace: ns),
              ),
            ),
        ]),
      ),
      DetailSection(
        title: 'Granted rules',
        icon: Icons.rule,
        child: _GrantedRules(key: ValueKey('${ctx.uid}/$refKind/$refName'), api: ctx.api, kind: refKind, name: refName, namespace: ns),
      ),
    ];
  }
}

class _GrantedRules extends StatefulWidget {
  final ApiClient api;
  final String kind;
  final String name;
  final String? namespace;
  const _GrantedRules({super.key, required this.api, required this.kind, required this.name, this.namespace});

  @override
  State<_GrantedRules> createState() => _GrantedRulesState();
}

class _GrantedRulesState extends State<_GrantedRules> {
  late Future<Json?> _future;

  @override
  void initState() {
    super.initState();
    final isRole = widget.kind == 'Role';
    _future = widget.api
        .object(ResourceRef(group: rbacGroup, resource: isRole ? 'roles' : 'clusterroles'), namespace: isRole ? widget.namespace : null, name: widget.name)
        .then<Json?>((v) => v, onError: (Object e) => e is ApiException && e.isNotFound ? null : throw e);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Json?>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return InlineMessage('${snap.error}', isError: true);
          if (snap.connectionState != ConnectionState.done) {
            return const SectionSpinner();
          }
          final role = snap.data;
          if (role == null) {
            return Callout(
              severity: Severity.warn,
              icon: Icons.link_off,
              title: '${widget.kind} "${widget.name}" not found',
              body: 'This binding currently grants nothing.',
            );
          }
          final rules = asMapList(role['rules']);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DangerCallout(rulesDangers(rules)),
            RulesTable(rules),
          ]);
        },
      );
}

RbacSubject _subjectOf(Json s, String? bindingNs) {
  final kind = '${s['kind'] ?? 'User'}';
  final name = '${s['name'] ?? ''}';
  if (kind == 'ServiceAccount') return RbacSubject.sa((s['namespace'] as String?) ?? bindingNs ?? 'default', name);
  return RbacSubject(kind: kind, name: name);
}

/// "Edit rules" (structured editor) and "Grant…" for a Role/ClusterRole.
class _RoleActions extends StatelessWidget {
  final PanelContext ctx;
  final RbacRef role;
  const _RoleActions({required this.ctx, required this.role});

  @override
  Widget build(BuildContext context) {
    if (ctx.app.readOnly) return const SizedBox.shrink();
    final style = TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      TextButton.icon(
        style: style,
        icon: const Icon(Icons.edit_outlined, size: 14),
        label: const Text('Edit rules'),
        onPressed: () => showRoleEditor(context, api: AccessApi(ctx.api), existing: ctx.object),
      ),
      TextButton.icon(
        style: style,
        icon: const Icon(Icons.person_add_alt, size: 14),
        label: const Text('Grant…'),
        onPressed: () => showGrantDialog(context, api: AccessApi(ctx.api), role: role, namespace: role.namespace ?? ctx.app.namespace),
      ),
    ]);
  }
}

/// Per subject: open it in the Access explorer, or remove it from this binding.
class _SubjectActions extends StatelessWidget {
  final PanelContext ctx;
  final RbacSubject subject;
  const _SubjectActions({required this.ctx, required this.subject});

  @override
  Widget build(BuildContext context) {
    final binding = RbacRef(ctx.namespace == null ? 'ClusterRoleBinding' : 'RoleBinding', ctx.name, ctx.namespace);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'Open ${subject.label} in the Access explorer',
        iconSize: 14,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.manage_accounts_outlined),
        onPressed: () => AccessFocus.open(ctx.app, subject: subject, namespace: ctx.namespace),
      ),
      if (!ctx.app.readOnly)
        IconButton(
          tooltip: 'Remove ${subject.label} from this binding…',
          iconSize: 14,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.person_remove_outlined),
          onPressed: () => removeSubjectFromBinding(context, api: AccessApi(ctx.api), binding: binding, subject: subject),
        ),
    ]);
  }
}
