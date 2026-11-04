import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/access/access_api.dart';
import '../../ui/access/access_view.dart';
import '../../ui/access/grant_dialog.dart';
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
    final theme = Theme.of(context);
    return FutureBuilder<List<_ResolvedBinding>>(
      future: _future,
      builder: (context, snap) {
        final list = snap.data;
        final defaults = list?.where((b) => isDefaultBinding(b.match)).toList() ?? const <_ResolvedBinding>[];
        final own = list?.where((b) => !isDefaultBinding(b.match)).toList() ?? const <_ResolvedBinding>[];
        List<EffectivePermission> perms(List<_ResolvedBinding> bs) =>
            effectivePermissions([for (final b in bs) if (b.role != null) (b.match, b.role!)]);
        final ownPerms = perms(own);
        return DetailSection(
          title: 'Permissions',
          icon: Icons.admin_panel_settings_outlined,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (list != null)
              Text(
                own.isEmpty ? 'defaults only' : '${ownPerms.length} grant${ownPerms.length == 1 ? '' : 's'} · ${own.length} binding${own.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            RefreshButton(() => setState(() => _future = _load())),
          ]),
          child: () {
            final sa = RbacSubject.sa(widget.ctx.namespace ?? 'default', widget.ctx.name);
            final small = TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6));
            final links = Wrap(spacing: 4, children: [
              TextButton.icon(
                style: small,
                icon: const Icon(Icons.grid_on, size: 14),
                label: const Text('Open in Access explorer'),
                onPressed: () => AccessFocus.open(widget.ctx.app, subject: sa, namespace: sa.namespace),
              ),
              if (!widget.ctx.app.readOnly)
                TextButton.icon(
                  style: small,
                  icon: const Icon(Icons.person_add_alt, size: 14),
                  label: const Text('Grant…'),
                  onPressed: () async {
                    final ok = await showGrantDialog(context, api: AccessApi(widget.ctx.api), subject: sa, namespace: sa.namespace);
                    if (ok == true && mounted) {
                      setState(() {
                        _future = _load();
                      });
                    }
                  },
                ),
            ]);
            if (snap.hasError) return InlineMessage('Could not load RBAC bindings: ${snap.error}', isError: true);
            if (list == null) return const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)));
            final errors = [for (final b in list) if (b.error != null) b];
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (own.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('Nothing beyond the cluster defaults. No RoleBinding or ClusterRoleBinding grants this ServiceAccount anything specific.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                )
              else ...[
                const _Label('Can do'),
                _PermissionTable(ownPerms),
                const _Label('Granted by'),
                for (final b in own) _BindingLine(b),
              ],
              for (final b in errors) Padding(padding: const EdgeInsets.only(top: 4), child: InlineMessage('${b.match.roleKind}/${b.match.roleName}: ${b.error}', isError: true)),
              if (defaults.isNotEmpty) _DefaultAccess(defaults: defaults, perms: perms(defaults)),
              const SizedBox(height: 4),
              Align(alignment: Alignment.centerLeft, child: links),
            ]);
          }(),
        );
      },
    );
  }
}

/// Small sentence-case sub-heading inside a section.
class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
    );
  }
}

/// "What can it do": one row per target. Neutral by default; a small dot
/// marks write (amber) and high-risk (red) grants. Scope and granting roles
/// are on hover.
class _PermissionTable extends StatelessWidget {
  final List<EffectivePermission> perms;
  const _PermissionTable(this.perms);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.hintColor;
    final colors = AppColors.of(context);
    final resources = perms.where((p) => !p.nonResource).toList();
    final urls = perms.where((p) => p.nonResource).toList();
    Widget row(EffectivePermission p) {
      final dot = switch (p.risk) {
        PermissionRisk.high => severityColor(context, Severity.error),
        PermissionRisk.write => severityColor(context, Severity.warn),
        PermissionRisk.read => null,
      };
      final scope = p.scopes.length == 1 ? (p.scopes.first == 'cluster-wide' ? 'cluster' : p.scopes.first.replaceFirst('namespace ', '')) : '${p.scopes.length} scopes';
      return Tooltip(
        waitDuration: const Duration(milliseconds: 500),
        message: [
          'Scope: ${p.scopes.join(', ')}',
          'Granted by: ${p.grantedBy.join(', ')}',
          if (p.risk == PermissionRisk.high) 'High risk: wildcard, secrets, exec or escalation',
        ].join('\n'),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.separator, width: 0.5))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 14,
              child: dot == null
                  ? null
                  : Padding(padding: const EdgeInsets.only(top: 5), child: Container(width: 6, height: 6, decoration: BoxDecoration(color: dot, shape: BoxShape.circle))),
            ),
            Expanded(flex: 5, child: Text(p.target, style: monoStyle(context, size: 11.5))),
            const SizedBox(width: 8),
            Expanded(flex: 4, child: Text(p.sortedVerbs.join(' · '), style: monoStyle(context, size: 11.5, color: muted))),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 90),
              child: Text(scope, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final p in resources) row(p),
      if (urls.isNotEmpty) ...[
        if (resources.isNotEmpty) const SizedBox(height: 6),
        Text('Non-resource URLs', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
        for (final p in urls) row(p),
      ],
    ]);
  }
}

/// One binding as a quiet line: role (link) then muted provenance.
class _BindingLine extends StatelessWidget {
  final _ResolvedBinding b;
  const _BindingLine(this.b);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = b.match;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ResourceLink(m.roleRef, label: m.roleName),
        Text(m.roleKind, style: muted),
        Text('· bound by', style: muted),
        ResourceLink(m.bindingRef, label: m.name),
        Text('· ${m.scope}${m.viaGroup != null ? ' · via group ${m.viaGroup}' : ''}', style: muted),
        if (b.role?['aggregationRule'] != null) Text('· aggregated', style: muted),
      ]),
    );
  }
}

/// The built-in bindings every identity inherits, collapsed to one line.
class _DefaultAccess extends StatefulWidget {
  final List<_ResolvedBinding> defaults;
  final List<EffectivePermission> perms;
  const _DefaultAccess({required this.defaults, required this.perms});

  @override
  State<_DefaultAccess> createState() => _DefaultAccessState();
}

class _DefaultAccessState extends State<_DefaultAccess> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final n = widget.defaults.length;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Hoverable(
          onTap: () => setState(() => _open = !_open),
          builder: (h) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 15, color: h ? theme.colorScheme.onSurface : theme.hintColor),
              const SizedBox(width: 2),
              Text('Default access', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    '$n built-in binding${n == 1 ? '' : 's'} every identity gets: ${widget.defaults.map((b) => b.match.roleName.replaceFirst('system:', '')).join(', ')}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
              ),
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: 17, top: 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _PermissionTable(widget.perms),
              const SizedBox(height: 4),
              for (final b in widget.defaults) _BindingLine(b),
            ]),
          ),
      ]),
    );
  }
}
