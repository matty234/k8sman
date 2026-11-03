import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'rbac.dart';
import 'widgets.dart';

class ServiceAccountPanel extends ResourcePanel {
  const ServiceAccountPanel();

  @override
  Set<String> get kinds => {'/ServiceAccount'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final theme = Theme.of(context);
    final automount = ctx.object['automountServiceAccountToken'];
    final secrets = asMapList(ctx.object['secrets']);
    final pullSecrets = asMapList(ctx.object['imagePullSecrets']);
    Widget secretLinks(List<Json> refs) => refs.isEmpty
        ? Text('none', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))
        : Wrap(spacing: 10, runSpacing: 2, children: [
            for (final s in refs) ResourceLink(ObjectRef(kind: 'Secret', name: '${s['name']}', namespace: s['namespace'] as String? ?? ctx.namespace), label: '${s['name']}'),
          ]);

    return [
      DetailSection(
        title: 'Service account',
        icon: Icons.badge_outlined,
        child: KeyValueTable([
          (
            'Automount token',
            Row(children: [
              StatusBadge(automount == false ? 'false' : 'true', dense: true, severity: automount == false ? Severity.neutral : Severity.ok),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  automount == null ? 'default; pods may override' : (automount == false ? 'pods must opt in' : 'explicit; pods may override'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
              ),
            ]),
          ),
          ('Secrets', secretLinks(secrets)),
          ('Image pull secrets', secretLinks(pullSecrets)),
          ('Username', SelectableText('system:serviceaccount:${ctx.namespace}:${ctx.name}', style: monoStyle(context, size: 11.5))),
        ], keyWidth: 130),
      ),
      _SaUsedBy(key: ValueKey('${ctx.uid}/usedby'), ctx: ctx),
      _Permissions(key: ValueKey('${ctx.uid}/rbac'), ctx: ctx),
    ];
  }
}

/// Pods whose spec.serviceAccountName is this SA.
List<Json> podsUsingServiceAccount(List<Json> pods, String name) => [
      for (final p in pods)
        if ((dig<String>(p, ['spec', 'serviceAccountName']) ?? dig<String>(p, ['spec', 'serviceAccount']) ?? 'default') == name) p,
    ]..sort((a, b) => '${dig(a, ['metadata', 'name'])}'.compareTo('${dig(b, ['metadata', 'name'])}'));

class _SaUsedBy extends StatefulWidget {
  final PanelContext ctx;
  const _SaUsedBy({super.key, required this.ctx});

  @override
  State<_SaUsedBy> createState() => _SaUsedByState();
}

class _SaUsedByState extends State<_SaUsedBy> {
  late Future<List<Json>> _pods;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() => _pods = widget.ctx.api.items(const ResourceRef(resource: 'pods'), namespace: widget.ctx.namespace);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<Json>>(
      future: _pods,
      builder: (context, snap) {
        final pods = snap.hasData ? podsUsingServiceAccount(snap.data!, widget.ctx.name) : null;
        return DetailSection(
          title: 'Used by',
          icon: Icons.link,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (pods != null) CountPill('${pods.length} pod${pods.length == 1 ? '' : 's'}'),
            RefreshButton(() => setState(_fetch)),
          ]),
          child: () {
            if (snap.hasError) return InlineMessage('Could not list pods: ${snap.error}', isError: true);
            if (pods == null) return const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)));
            if (pods.isEmpty) return const InlineMessage('No pods in this namespace run as this ServiceAccount.');
            final saAutomount = widget.ctx.object['automountServiceAccountToken'] != false;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final p in pods)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Icon(Icons.view_in_ar, size: 14, color: theme.hintColor),
                    const SizedBox(width: 6),
                    Flexible(child: ResourceLink(ObjectRef(kind: 'Pod', name: '${dig(p, ['metadata', 'name'])}', namespace: widget.ctx.namespace), label: '${dig(p, ['metadata', 'name'])}')),
                    const SizedBox(width: 6),
                    if (dig<String>(p, ['status', 'phase']) case final phase?) StatusBadge(phase, dense: true),
                    const Spacer(),
                    Text(
                      (dig<bool>(p, ['spec', 'automountServiceAccountToken']) ?? saAutomount) ? 'token mounted' : 'no token',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11),
                    ),
                  ]),
                ),
            ]);
          }(),
        );
      },
    );
  }
}

/// A matched binding plus its resolved role (or the error resolving it).
class _ResolvedBinding {
  final BindingMatch match;
  final Json? role;
  final String? error;
  const _ResolvedBinding(this.match, this.role, this.error);
}

class _Permissions extends StatefulWidget {
  final PanelContext ctx;
  const _Permissions({super.key, required this.ctx});

  @override
  State<_Permissions> createState() => _PermissionsState();
}

class _PermissionsState extends State<_Permissions> {
  late Future<List<_ResolvedBinding>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_ResolvedBinding>> _load() async {
    final api = widget.ctx.api;
    final ns = widget.ctx.namespace ?? 'default';
    final results = await Future.wait([
      api.items(const ResourceRef(group: rbacGroup, resource: 'rolebindings'), namespace: ns),
      api.items(const ResourceRef(group: rbacGroup, resource: 'clusterrolebindings')),
    ]);
    final matches = matchBindings(saName: widget.ctx.name, saNamespace: ns, roleBindings: results[0], clusterRoleBindings: results[1]);
    final cache = <String, Future<Json>>{};
    return Future.wait([
      for (final m in matches)
        () async {
          final r = m.roleRef;
          final res = ResourceRef(group: rbacGroup, resource: r.kind == 'Role' ? 'roles' : 'clusterroles');
          try {
            final role = await (cache['${r.kind}/${r.namespace}/${r.name}'] ??= api.object(res, namespace: r.namespace, name: r.name));
            return _ResolvedBinding(m, role, null);
          } catch (e) {
            return _ResolvedBinding(m, null, e is ApiException && e.status == 404 ? '${r.kind} not found (dangling binding)' : '$e');
          }
        }(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_ResolvedBinding>>(
      future: _future,
      builder: (context, snap) {
        final list = snap.data;
        final direct = list?.where((b) => !b.match.inherited).length ?? 0;
        return DetailSection(
          title: 'Permissions',
          icon: Icons.admin_panel_settings_outlined,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (list != null) CountPill('$direct direct · ${list.length - direct} inherited'),
            RefreshButton(() => setState(() => _future = _load())),
          ]),
          child: () {
            if (snap.hasError) return InlineMessage('Could not load RBAC bindings: ${snap.error}', isError: true);
            if (list == null) return const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)));
            if (list.isEmpty) return const InlineMessage('No RoleBindings or ClusterRoleBindings grant anything to this ServiceAccount.');
            final children = <Widget>[];
            if (direct == 0) {
              children.add(const Padding(padding: EdgeInsets.only(bottom: 6), child: InlineMessage('No bindings name this ServiceAccount directly.')));
            } else {
              children.add(const _GroupHeader('Direct', first: true));
            }
            for (var i = 0; i < list.length; i++) {
              final b = list[i];
              if (b.match.inherited && (i == 0 || !list[i - 1].match.inherited)) {
                children.add(_GroupHeader('Inherited via groups', first: i == 0 && direct == 0));
              } else if (i > 0) {
                children.add(const Divider(height: 14));
              }
              children.add(_BindingView(b));
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
          }(),
        );
      },
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String text;
  final bool first;
  const _GroupHeader(this.text, {required this.first});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 12, bottom: 6),
      child: Row(children: [
        Text(text.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, letterSpacing: 0.6, fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        const Expanded(child: Divider()),
      ]),
    );
  }
}

class _BindingView extends StatelessWidget {
  final _ResolvedBinding b;
  const _BindingView(this.b);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = b.match;
    final rules = summarizeRules(asMapList(b.role?['rules']));
    final aggregated = b.role?['aggregationRule'] != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ResourceLink(m.bindingRef, label: '${m.cluster ? 'ClusterRoleBinding' : 'RoleBinding'}/${m.name}'),
        Icon(Icons.arrow_forward, size: 13, color: theme.hintColor),
        ResourceLink(m.roleRef, label: '${m.roleKind}/${m.roleName}'),
        StatusBadge(m.scope, dense: true, severity: m.cluster ? Severity.warn : Severity.neutral),
        if (m.viaGroup != null) StatusBadge('via ${m.viaGroup}', dense: true, severity: Severity.info),
        if (aggregated) const StatusBadge('aggregated', dense: true, severity: Severity.neutral),
      ]),
      const SizedBox(height: 4),
      if (b.error != null)
        InlineMessage(b.error!, isError: true)
      else if (rules.isEmpty)
        Text('no rules', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))
      else
        for (final r in rules)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 150,
                child: Text(r.verbs == '*' ? '* (all verbs)' : r.verbs,
                    style: monoStyle(context, size: 11, color: r.wildcard ? severityColor(context, Severity.warn) : theme.colorScheme.tertiary)),
              ),
              Expanded(child: SelectableText(r.targets, style: monoStyle(context, size: 11))),
            ]),
          ),
    ]);
  }
}
