/// The Access workspace: effective permissions per subject (explorer),
/// reverse lookup ("Who can…?"), the app's own access ("Can I…?"), and
/// entry points to the role editor and grant wizard.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart';
import '../widgets/searchable_picker.dart';
import 'access_api.dart';
import 'access_apply.dart';
import 'access_widgets.dart';
import 'grant_dialog.dart';
import 'permission_matrix.dart';
import 'role_editor.dart';
import '../widgets/resizable_split.dart';

/// A request to show something in the Access workspace (from inspector
/// panels and the Security page).
class AccessFocus {
  final RbacSubject? subject;
  final List<String> groups;

  /// 0 explorer, 1 who can, 2 can I.
  final int tab;
  final String? namespace;
  const AccessFocus({this.subject, this.groups = const [], this.tab = 0, this.namespace});

  static final request = ValueNotifier<AccessFocus?>(null);

  /// Switches the main view to Access showing [subject].
  static void open(AppState app, {RbacSubject? subject, List<String> groups = const [], int tab = 0, String? namespace}) {
    request.value = AccessFocus(subject: subject, groups: groups, tab: tab, namespace: namespace);
    app.showView(MainView.access);
  }
}

class AccessView extends StatefulWidget {
  /// Override the data source (tests).
  final AccessApi? source;
  const AccessView({super.key, this.source});

  @override
  State<AccessView> createState() => _AccessViewState();
}

class _AccessViewState extends State<AccessView> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this, animationDuration: Duration.zero);
  AccessApi? _api;
  final _explorer = GlobalKey<_ExplorerTabState>();
  int _reload = 0;

  AccessApi get api => _api ??= widget.source ?? AccessApi(context.read<ApiClient>());

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() => setState(() {}));
    AccessFocus.request.addListener(_focus);
    scheduleMicrotask(_focus);
  }

  @override
  void dispose() {
    AccessFocus.request.removeListener(_focus);
    _tabs.dispose();
    super.dispose();
  }

  void _focus() {
    final f = AccessFocus.request.value;
    if (f == null || !mounted) return;
    AccessFocus.request.value = null;
    _tabs.index = f.tab;
    if (f.subject != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _explorer.currentState?.select(f.subject!, groups: f.groups, namespace: f.namespace));
    }
  }

  void _explore(RbacSubject s, {List<String> groups = const [], String? namespace}) {
    _tabs.index = 0;
    _explorer.currentState?.select(s, groups: groups, namespace: namespace);
  }

  Future<void> _newRole() async {
    final ok = await showRoleEditor(context, api: api, namespace: context.read<AppState>().namespace);
    if (ok == true) setState(() => _reload++);
  }

  Future<void> _grant() async {
    final ex = _explorer.currentState;
    final ok = await showGrantDialog(context, api: api, subject: _tabs.index == 0 ? ex?.subject : null, namespace: ex?.namespace);
    if (ok == true) setState(() => _reload++);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final small = TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: 'Access',
        actions: [
          if (!app.readOnly) ...[
            TextButton.icon(style: small, onPressed: _newRole, icon: const Icon(Icons.post_add, size: 16), label: const Text('New role')),
            TextButton.icon(style: small, onPressed: _grant, icon: const Icon(Icons.person_add_alt, size: 16), label: const Text('Grant access')),
          ],
          IconButton(tooltip: 'Refresh', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: () => setState(() => _reload++)),
        ],
      ),
      const Divider(),
      Align(
        alignment: Alignment.centerLeft,
        child: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          tabs: const [Tab(text: 'Explorer', height: 34), Tab(text: 'Who can…?', height: 34), Tab(text: 'Can I…?', height: 34)],
        ),
      ),
      Divider(height: 1, color: AppColors.of(context).separator),
      Expanded(
        child: IndexedStack(index: _tabs.index, children: [
          _ExplorerTab(key: _explorer, api: api, reload: _reload),
          _WhoCanTab(api: api, reload: _reload, onExplore: _explore),
          _CanITab(api: api, reload: _reload, onExplain: (s, groups) => _explore(s, groups: groups)),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Scope picker
// ---------------------------------------------------------------------------

/// Cluster-wide ('') / any namespace ('*') / a namespace.
class ScopePicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final bool any;
  const ScopePicker({super.key, required this.value, required this.onChanged, this.any = false});

  static String label(String v) => v.isEmpty ? 'Cluster-wide' : (v == '*' ? 'Any namespace' : v);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    return SearchablePicker<String>(
      tooltip: 'Cluster-wide counts ClusterRoleBindings only; a namespace adds its RoleBindings',
      pinned: () => [
        const PickerOption('', 'Cluster-wide', detail: 'ClusterRoleBindings'),
        if (any) const PickerOption('*', 'Any namespace', detail: 'every binding'),
      ],
      items: () => [for (final n in app.namespaces) PickerOption(n, n)],
      selected: value,
      hint: 'Namespace',
      onSelected: onChanged,
      builder: (h) => Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(color: h ? AppColors.of(context).hover : chipFill(context), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(value.isEmpty || value == '*' ? Icons.public : Icons.folder_outlined, size: 14, color: theme.hintColor),
          const SizedBox(width: 6),
          Text(label(value), style: theme.textTheme.bodySmall),
          const SizedBox(width: 2),
          Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
        ]),
      ),
    );
  }
}

class _FilterField extends StatelessWidget {
  final ValueChanged<String> onChanged;
  const _FilterField({required this.onChanged});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 180,
        height: 26,
        child: TextField(
          style: Theme.of(context).textTheme.bodySmall,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 14), hintText: 'Filter resources', isDense: true),
          onChanged: onChanged,
        ),
      );
}

class _Toggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Toggle({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onChanged(!value),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 18, child: Transform.scale(scale: 0.6, child: Switch(value: value, onChanged: onChanged))),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Explorer
// ---------------------------------------------------------------------------

class _ExplorerTab extends StatefulWidget {
  final AccessApi api;
  final int reload;
  const _ExplorerTab({super.key, required this.api, required this.reload});

  @override
  State<_ExplorerTab> createState() => _ExplorerTabState();
}

class _ExplorerTabState extends State<_ExplorerTab> {
  // Panel widths while the app runs (null = default); not persisted.
  double? _listWidth;
  double? _sideWidth;
  SubjectList? _subjects;
  Object? _subjectsError;
  RbacSubject? subject;
  List<String> _groups = const [];

  /// '' = cluster-wide.
  String namespaceScope = '';
  String? get namespace => namespaceScope.isEmpty ? null : namespaceScope;
  PermissionMatrixData? _data;
  Object? _error;
  bool _loading = false;
  int _seq = 0;
  String _filter = '';
  String _subjectFilter = '';
  bool _hideEmpty = true;
  (MatrixRow, String)? _cell;

  @override
  void initState() {
    super.initState();
    _loadSubjects();
  }

  @override
  void didUpdateWidget(_ExplorerTab old) {
    super.didUpdateWidget(old);
    if (old.reload != widget.reload) {
      _loadSubjects();
      _loadMatrix();
    }
  }

  Future<void> _loadSubjects() async {
    try {
      final s = await widget.api.subjects();
      if (mounted) setState(() => _subjects = s);
    } catch (e) {
      if (mounted) setState(() => _subjectsError = e);
    }
  }

  void select(RbacSubject s, {List<String> groups = const [], String? namespace}) {
    setState(() {
      subject = s;
      _groups = groups;
      _cell = null;
      if (namespace != null) namespaceScope = namespace;
      _data = null;
    });
    _loadMatrix();
  }

  Future<void> _loadMatrix() async {
    final s = subject;
    if (s == null) return;
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final d = await widget.api.matrix(s, namespace: namespace, groups: _groups);
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = d;
        _error = null;
        _loading = false;
        if (_cell != null) {
          final row = d.rows.where((r) => r.key == _cell!.$1.key).firstOrNull;
          _cell = row == null ? null : (row, _cell!.$2);
        }
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _otherSubject() async {
    final name = TextEditingController();
    final groups = TextEditingController();
    var kind = 'User';
    final picked = await showDialog<RbacSubject>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Explore another subject'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [ButtonSegment(value: 'User', label: Text('User')), ButtonSegment(value: 'Group', label: Text('Group'))],
                selected: {kind},
                onSelectionChanged: (s) => set(() => kind = s.first),
              ),
              const SizedBox(height: 10),
              TextField(controller: name, autofocus: true, decoration: InputDecoration(labelText: kind == 'User' ? 'User name' : 'Group name')),
              if (kind == 'User') ...[
                const SizedBox(height: 8),
                TextField(controller: groups, decoration: const InputDecoration(labelText: 'Groups (comma-separated, optional)')),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, name.text.trim().isEmpty ? null : RbacSubject(kind: kind, name: name.text.trim())),
              child: const Text('Explore'),
            ),
          ],
        ),
      ),
    );
    if (picked != null) select(picked, groups: [for (final g in groups.text.split(',')) if (g.trim().isNotEmpty) g.trim()]);
  }

  Future<void> _remove(BindingSummary b) async {
    final s = subject;
    if (s == null) return;
    if (await removeSubjectFromBinding(context, api: widget.api, binding: b.binding, subject: b.subject)) {
      _loadSubjects();
      _loadMatrix();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ResizableSplit(
      start: _subjectList(context),
      startWidth: _listWidth,
      onStartChanged: (w) => setState(() => _listWidth = w),
      center: subject == null ? _empty(context) : _main(context),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.manage_accounts_outlined, size: 36, color: theme.hintColor),
          const SizedBox(height: 10),
          Text('Pick a ServiceAccount, user or group', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'See everything it can do as a resource × verb matrix, and for every cell which binding, role and rule grant it.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ]),
      ),
    );
  }

  Widget _subjectList(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final s = _subjects;
    final q = _subjectFilter.toLowerCase();
    bool m(SubjectInfo i) => q.isEmpty || i.subject.label.toLowerCase().contains(q);
    final items = <Object>[];
    if (s != null) {
      for (final (title, list) in [('Users', s.users), ('Groups', s.groups), ('ServiceAccounts', s.serviceAccounts)]) {
        final shown = list.where(m).toList();
        if (shown.isEmpty) continue;
        items.add('$title · ${shown.length}');
        items.addAll(shown);
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        child: SizedBox(
          height: 26,
          child: TextField(
            style: theme.textTheme.bodySmall,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 14), hintText: 'Find subject', isDense: true),
            onChanged: (v) => setState(() => _subjectFilter = v.trim()),
          ),
        ),
      ),
      if (_subjectsError != null) Padding(padding: const EdgeInsets.all(10), child: ErrorNotice(_subjectsError!, title: "Couldn't list RBAC", onRetry: _loadSubjects)),
      if (s?.serviceAccountsError != null)
        Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 6), child: ErrorNotice(s!.serviceAccountsError!, title: "Couldn't list ServiceAccounts", severity: Severity.warn)),
      Expanded(
        child: s == null && _subjectsError == null
            ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final it = items[i];
                  if (it is String) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 10, 3),
                      child: Text(it, style: theme.textTheme.labelSmall?.copyWith(color: colors.faint, fontWeight: FontWeight.w600)),
                    );
                  }
                  final info = it as SubjectInfo;
                  final sel = info.subject == subject;
                  return Hoverable(
                    cursor: SystemMouseCursors.basic,
                    onTap: () => select(info.subject),
                    builder: (h) => Container(
                      height: 24,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(color: sel ? colors.selection : (h ? colors.hover : null), borderRadius: BorderRadius.circular(5)),
                      child: Row(children: [
                        Icon(subjectIcon(info.subject.kind), size: 13, color: sel ? theme.colorScheme.primary : theme.hintColor),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Tooltip(
                            message: info.subject.kind == 'Group' && wellKnownGroup(info.subject.name) != null
                                ? '${info.subject.name}: ${wellKnownGroup(info.subject.name)}'
                                : '${info.subject.kind} ${info.subject.label} · ${info.bindings} binding${info.bindings == 1 ? '' : 's'}${info.exists ? '' : ' · does not exist'}',
                            waitDuration: const Duration(milliseconds: 700),
                            child: Text(info.subject.label,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: info.exists ? null : theme.hintColor,
                                  decoration: info.exists ? null : TextDecoration.lineThrough,
                                )),
                          ),
                        ),
                        if (info.bindings > 0) Text('${info.bindings}', style: theme.textTheme.labelSmall?.copyWith(color: colors.faint)),
                      ]),
                    ),
                  );
                },
              ),
      ),
      const Divider(height: 1),
      TextButton.icon(onPressed: _otherSubject, icon: const Icon(Icons.person_search_outlined, size: 15), label: const Text('Other user or group…')),
    ]);
  }

  Widget _main(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final s = subject!;
    final d = _data;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 8),
        child: Row(children: [
          Flexible(flex: 4, child: SubjectLabel(s, showKind: true, style: theme.textTheme.titleSmall)),
          if (s.objectRef != null) ...[
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Open ServiceAccount in the inspector',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.open_in_new),
              onPressed: () => app.openRef(s.objectRef!),
            ),
          ],
          const SizedBox(width: 12),
          ScopePicker(value: namespaceScope, onChanged: (v) {
            setState(() {
              namespaceScope = v;
              _cell = null;
            });
            _loadMatrix();
          }),
          const Spacer(flex: 1),
          if (_loading) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))),
          _FilterField(onChanged: (v) => setState(() => _filter = v)),
          const SizedBox(width: 8),
          _Toggle(label: 'Only granted', value: _hideEmpty, onChanged: (v) => setState(() => _hideEmpty = v)),
          if (!app.readOnly) ...[
            const SizedBox(width: 6),
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () async {
                final ok = await showGrantDialog(context, api: widget.api, subject: s, namespace: namespace ?? s.namespace);
                if (ok == true) _loadMatrix();
              },
              icon: const Icon(Icons.add, size: 15),
              label: const Text('Grant'),
            ),
          ],
        ]),
      ),
      if (d != null && d.identity.groups.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(d.identity.user.isEmpty ? 'Evaluated as a member of' : 'Authenticates as ${d.identity.user} in groups', style: hint),
            for (final g in d.identity.groups) Tooltip(message: wellKnownGroup(g) ?? g, child: Chipish(text: g)),
          ]),
        ),
      if (_error != null && d != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: ErrorNotice(_error!, title: 'Refresh failed', note: 'Showing the last result.', onRetry: _loadMatrix)),
      if (d != null) ..._callouts(context, d),
      const Divider(height: 1),
      Expanded(
        child: d == null
            ? (_error == null ? const Center(child: CircularProgressIndicator()) : LoadFailure(_error!, onRetry: _loadMatrix))
            : ResizableSplit(
                endWidth: _sideWidth,
                onEndChanged: (w) => setState(() => _sideWidth = w),
                center: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
                  child: PermissionMatrix(
                    data: d,
                    filter: _filter,
                    hideEmpty: _hideEmpty,
                    selected: _cell == null ? null : (_cell!.$1.key, _cell!.$2),
                    onSelect: (row, verb) => setState(() => _cell = (row, verb)),
                  ),
                ),
                end: _cell != null
                    ? CellExplanation(
                        data: d,
                        row: _cell!.$1,
                        verb: _cell!.$2,
                        subject: s,
                        groups: _groups,
                        api: widget.api,
                        onClose: () => setState(() => _cell = null),
                      )
                    : _summary(context, d),
              ),
      ),
    ]);
  }

  List<Widget> _callouts(BuildContext context, PermissionMatrixData d) {
    final theme = Theme.of(context);
    final warn = severityColor(context, Severity.warn);
    final out = <Widget>[];
    Widget banner(IconData icon, Color c, Widget child) => Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withValues(alpha: 0.45))),
          child: Row(children: [Icon(icon, size: 15, color: c), const SizedBox(width: 8), Expanded(child: child)]),
        );
    if (d.fullWildcard) {
      final via = d.paths.where((p) => p.fullWildcard).map((p) => p.binding.isEmpty ? p.role.name : p.binding.name).toSet().join(', ');
      out.add(banner(Icons.warning_amber_rounded, severityColor(context, Severity.error),
          Text('Full access: * on * in every API group (cluster-admin equivalent), via $via.', style: theme.textTheme.bodySmall)));
    }
    if (d.namespace.isEmpty && d.roleBindingNamespaces.isNotEmpty) {
      out.add(banner(
        Icons.folder_outlined,
        theme.colorScheme.primary,
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 2, children: [
          Text('RoleBindings add more in:', style: theme.textTheme.bodySmall),
          for (final ns in d.roleBindingNamespaces.take(8))
            Hoverable(
              onTap: () {
                setState(() => namespaceScope = ns);
                _loadMatrix();
              },
              builder: (h) => Text(ns, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary, decoration: h ? TextDecoration.underline : null)),
            ),
          if (d.roleBindingNamespaces.length > 8) Text('+${d.roleBindingNamespaces.length - 8} more', style: theme.textTheme.bodySmall),
        ]),
      ));
    }
    if (d.missingRoles.isNotEmpty) {
      out.add(banner(Icons.link_off, warn,
          Text('Bound to missing ${d.missingRoles.map((r) => '${r.kind} ${r.label}').join(', ')}: grants nothing today, but would as soon as someone creates it.', style: theme.textTheme.bodySmall)));
    }
    return out;
  }

  Widget _summary(BuildContext context, PermissionMatrixData d) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final app = context.read<AppState>();
    // The count as a big figure, the lists under the app's section heading.
    return PageScroll(padding: const EdgeInsets.fromLTRB(16, 12, 14, 16), children: [
      FigureCaption(d.namespace.isEmpty ? 'Cluster-wide' : 'In ${d.namespace}'),
      const SizedBox(height: 2),
      BigFigure(
        '${d.grantedCells}',
        d.grantedCells == 1 ? 'permission' : 'permissions',
      ),
      if (d.dangerousCells > 0)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('${d.dangerousCells} sensitive', style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn))),
        ),
      const SizedBox(height: 10),
      const MatrixLegend(),
      const SizedBox(height: 6),
      Text('Hover a cell for the reason; click it for every grant and to verify with the API server.', style: hint),
      EditorialSection(
        title: 'Granted by',
        top: 20,
        collapsible: false,
        trailing: Text('${d.bindings.length}'),
        child: BindingList(d.bindings, onRemove: app.readOnly ? null : _remove),
      ),
      if (d.nonResource.isNotEmpty) ...[
        const SizedBox(height: 18),
        const SectionHeader(title: 'Non-resource URLs'),
        const SizedBox(height: 6),
        for (final n in d.nonResource)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Tooltip(
              message: [for (final i in n.paths) pathLine(d.paths[i])].join('\n'),
              child: Text('${n.verbs.join(', ')}  ${n.urls.join(', ')}', style: monoStyle(context, size: 11)),
            ),
          ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Who can…?
// ---------------------------------------------------------------------------

class _Preset {
  final String label;
  final AccessRequest request;
  const _Preset(this.label, this.request);
}

const _presets = [
  _Preset('Read Secrets', AccessRequest(verb: 'get', resource: 'secrets', namespace: '*')),
  _Preset('Exec into pods', AccessRequest(verb: 'create', resource: 'pods/exec', namespace: '*')),
  _Preset('Create pods in kube-system', AccessRequest(verb: 'create', resource: 'pods', namespace: 'kube-system')),
  _Preset('Escalate roles', AccessRequest(verb: 'escalate', group: rbacApiGroup, resource: 'clusterroles')),
  _Preset('Bind roles', AccessRequest(verb: 'bind', group: rbacApiGroup, resource: 'clusterroles')),
  _Preset('Impersonate users', AccessRequest(verb: 'impersonate', resource: 'users')),
  _Preset('nodes/proxy', AccessRequest(verb: 'get', resource: 'nodes/proxy')),
  _Preset('* on *', AccessRequest(verb: '*', group: '*', resource: '*')),
];

class _WhoCanTab extends StatefulWidget {
  final AccessApi api;
  final int reload;
  final void Function(RbacSubject s, {String? namespace}) onExplore;
  const _WhoCanTab({required this.api, required this.reload, required this.onExplore});

  @override
  State<_WhoCanTab> createState() => _WhoCanTabState();
}

class _WhoCanTabState extends State<_WhoCanTab> {
  String _verb = 'get';
  String _group = '';
  String _resource = 'secrets';
  String _scope = '*';
  final _name = TextEditingController();
  List<ApiResourceInfo> _resources = const [];
  Future<WhoCanResult>? _result;
  AccessRequest? _asked;
  final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    widget.api.resources().then((r) {
      if (mounted) setState(() => _resources = r);
    }, onError: (_) {});
    _ask();
  }

  @override
  void didUpdateWidget(_WhoCanTab old) {
    super.didUpdateWidget(old);
    if (old.reload != widget.reload) _ask();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _ask() {
    final r = AccessRequest(verb: _verb, group: _group, resource: _resource, namespace: _scope.isEmpty ? null : _scope, name: _name.text.trim());
    setState(() {
      _asked = r;
      _open.clear();
      _result = widget.api.whoCan(r);
    });
  }

  void _preset(_Preset p) {
    _verb = p.request.verb;
    _group = p.request.group;
    _resource = p.request.resource;
    _scope = p.request.namespace ?? '';
    _name.clear();
    _ask();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final verbs = ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete', 'deletecollection', 'escalate', 'bind', 'impersonate', 'approve', 'use', '*'];
    final resourceLabel = '$_resource${_group.isEmpty ? '' : ' · $_group'}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Who can', style: theme.textTheme.titleSmall),
          MenuSelect<String>(value: _verb, options: [for (final v in verbs) (v, Text(v, style: monoStyle(context, size: 12)))], onChanged: (v) {
            _verb = v;
            _ask();
          }),
          SearchablePicker<String>(
            width: 360,
            hint: 'Resource',
            pinned: () => const [PickerOption('*|*', '*', detail: 'every resource in every group')],
            items: () => [for (final r in _resources) PickerOption('${r.group}|${r.resource}', r.resource, detail: r.groupLabel)],
            selected: '$_group|$_resource',
            onSelected: (v) {
              final parts = v.split('|');
              _group = parts[0];
              _resource = parts[1];
              _ask();
            },
            builder: (h) => Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(color: h ? AppColors.of(context).hover : chipFill(context), borderRadius: BorderRadius.circular(6)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(resourceLabel, style: monoStyle(context, size: 12)),
                Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
              ]),
            ),
          ),
          ScopePicker(value: _scope, any: true, onChanged: (v) {
            _scope = v;
            _ask();
          }),
          SizedBox(
            width: 170,
            height: 26,
            child: TextField(
              controller: _name,
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(hintText: 'named (optional)', isDense: true),
              onSubmitted: (_) => _ask(),
            ),
          ),
          FilledButton.tonal(style: FilledButton.styleFrom(visualDensity: VisualDensity.compact), onPressed: _ask, child: const Text('Ask')),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Sensitive:', style: hint),
          for (final p in _presets)
            Hoverable(
              cursor: SystemMouseCursors.basic,
              onTap: () => _preset(p),
              builder: (h) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: chipFill(context, hovered: h), borderRadius: BorderRadius.circular(10)),
                child: Text(p.label, style: theme.textTheme.labelSmall),
              ),
            ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: FutureBuilder<WhoCanResult>(
          future: _result,
          builder: (context, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(16), child: ErrorNotice(snap.error!));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return _results(context, snap.data!);
          },
        ),
      ),
    ]);
  }

  Widget _results(BuildContext context, WhoCanResult r) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final asked = _asked!;
    final where = ScopePicker.label(asked.namespace ?? '');
    final full = r.entries.where((e) => !e.partial).length;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 20), children: [
      Row(children: [
        Text('${r.entries.length} subject${r.entries.length == 1 ? '' : 's'}', style: theme.textTheme.titleSmall),
        const SizedBox(width: 8),
        Flexible(child: Text('can ${asked.label} · $where${full != r.entries.length ? ' · ${r.entries.length - full} only for named objects' : ''}', style: hint)),
      ]),
      if (r.danger != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Icon(Icons.warning_amber_rounded, size: 15, color: severityColor(context, Severity.warn)),
            const SizedBox(width: 6),
            Expanded(child: Text(r.danger!, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn)))),
          ]),
        ),
      const SizedBox(height: 4),
      Text('From RBAC bindings. system:masters and non-RBAC authorizers (Node, webhooks) are not listed.', style: hint),
      const SizedBox(height: 10),
      for (final e in r.entries) _entry(context, e),
    ]);
  }

  Widget _entry(BuildContext context, WhoCanEntry e) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final key = '${e.subject.kind}/${e.subject.label}';
    final open = _open.contains(key);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    final roles = e.paths.map((p) => p.role.name).toSet().join(', ');
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.separator.withValues(alpha: 0.6)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Hoverable(
          cursor: SystemMouseCursors.basic,
          onTap: () => setState(() => open ? _open.remove(key) : _open.add(key)),
          builder: (h) => Container(
            color: h ? colors.hover : null,
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
            child: Row(children: [
              Icon(open ? Icons.expand_more : Icons.chevron_right, size: 14, color: theme.hintColor),
              const SizedBox(width: 4),
              SizedBox(width: 300, child: SubjectLabel(e.subject, showKind: true)),
              if (e.fullWildcard) ...[const StatusBadge('* on *', severity: Severity.error), const SizedBox(width: 6)],
              // Long name lists: the first two and a count, all of them in
              // the tooltip, so the pill never pushes the row off screen.
              if (e.partial) ...[
                Flexible(child: Tooltip(
                  message: 'Only these objects:\n${e.names.join('\n')}',
                  child: StatusBadge(
                    'only ${e.names.take(2).join(', ')}${e.names.length > 2 ? ' +${e.names.length - 2} more' : ''}',
                    severity: Severity.info,
                  ),
                )),
                const SizedBox(width: 6),
              ],
              for (final s in e.scopes.take(3)) ...[StatusBadge(s, dense: true, severity: s == 'cluster' ? Severity.warn : Severity.info), const SizedBox(width: 8)],
              Expanded(child: Text('via $roles', style: hint, overflow: TextOverflow.ellipsis)),
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () => widget.onExplore(e.subject, namespace: e.scopes.where((s) => s != 'cluster').firstOrNull),
                child: const Text('Explore'),
              ),
            ]),
          ),
        ),
        if (open) Padding(padding: const EdgeInsets.fromLTRB(24, 2, 8, 8), child: Column(children: [for (final p in e.paths) PathCard(p)])),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Can I…?
// ---------------------------------------------------------------------------

class _CanITab extends StatefulWidget {
  final AccessApi api;
  final int reload;
  final void Function(RbacSubject s, List<String> groups) onExplain;
  const _CanITab({required this.api, required this.reload, required this.onExplain});

  @override
  State<_CanITab> createState() => _CanITabState();
}

class _CanITabState extends State<_CanITab> {
  String _scope = '';
  Future<SelfAccess>? _future;
  String _filter = '';
  bool _hideEmpty = true;
  (MatrixRow, String)? _cell;

  @override
  void initState() {
    super.initState();
    _scope = context.read<AppState>().namespace ?? '';
    _load();
  }

  @override
  void didUpdateWidget(_CanITab old) {
    super.didUpdateWidget(old);
    if (old.reload != widget.reload) _load();
  }

  void _load() => setState(() {
        _cell = null;
        _future = widget.api.self(namespace: _scope.isEmpty ? null : _scope);
      });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SelfAccess>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) return Padding(padding: const EdgeInsets.all(16), child: ErrorNotice(snap.error!));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        return _body(context, snap.data!);
      },
    );
  }

  Widget _body(BuildContext context, SelfAccess s) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final id = s.identity;
    final groups = id?.groups.where((g) => g != 'system:authenticated').toList() ?? const <String>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.badge_outlined, size: 16, color: theme.hintColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text.rich(TextSpan(children: [
                const TextSpan(text: 'k8sman connects to '),
                TextSpan(text: s.context, style: monoStyle(context, size: 12)),
                const TextSpan(text: ' as '),
                TextSpan(text: id?.user ?? 'an unknown user', style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600)),
                if (s.identitySource.isNotEmpty) TextSpan(text: '  (from the ${s.identitySource})', style: hint),
              ])),
            ),
            if (s.readOnly) ...[const SizedBox(width: 8), const StatusBadge('backend read-only', severity: Severity.info)],
            const Spacer(),
            ScopePicker(value: _scope, onChanged: (v) {
              _scope = v;
              _load();
            }),
            const SizedBox(width: 8),
            _FilterField(onChanged: (v) => setState(() => _filter = v)),
            const SizedBox(width: 8),
            _Toggle(label: 'Only granted', value: _hideEmpty, onChanged: (v) => setState(() => _hideEmpty = v)),
          ]),
          const SizedBox(height: 6),
          if (id != null && id.groups.isNotEmpty)
            Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Groups', style: hint),
              for (final g in id.groups) Tooltip(message: wellKnownGroup(g) ?? g, child: Chipish(text: g)),
              if (id.user.isNotEmpty)
                TextButton(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => widget.onExplain(RbacSubject.user(id.user), groups),
                  child: const Text('Explain via bindings'),
                ),
            ]),
          if (id == null && s.identityError != null) Text('Could not ask who we are (SelfSubjectReview): ${s.identityError}', style: hint),
          const SizedBox(height: 4),
          Text(
            'What the API server says these credentials may do (SelfSubjectRulesReview in ${s.evaluatedIn}). '
            'Anything the app shows as forbidden or read-only comes from here${s.readOnly ? ', or from the backend running with --read-only' : ''}.',
            style: hint,
          ),
          if (id != null && id.groups.contains('system:masters'))
            Padding(padding: const EdgeInsets.only(top: 6), child: InlineMessage('Member of system:masters: the API server allows everything, whatever RBAC says.', icon: Icons.shield_outlined)),
          if (s.incomplete)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: InlineMessage('The list is incomplete${s.evaluationError == null ? '' : ': ${s.evaluationError}'}. Another authorizer (e.g. a webhook) may allow more; use Verify on a cell to be sure.',
                  icon: Icons.info_outline),
            ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
              child: PermissionMatrix(
                data: s.matrix,
                filter: _filter,
                hideEmpty: _hideEmpty,
                selected: _cell == null ? null : (_cell!.$1.key, _cell!.$2),
                onSelect: (row, verb) => setState(() => _cell = (row, verb)),
              ),
            ),
          ),
          VerticalDivider(width: 1, color: AppColors.of(context).separator),
          SizedBox(
            width: 310,
            child: _cell == null
                ? PageScroll(padding: const EdgeInsets.all(14), children: [
                    const MatrixLegend(),
                    const SizedBox(height: 8),
                    Text('Click a cell to ask the API server directly (SelfSubjectAccessReview) and compare with the RBAC bindings.', style: hint),
                    if (s.matrix.nonResource.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text('NON-RESOURCE URLS', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
                      for (final n in s.matrix.nonResource) Text('${n.verbs.join(', ')}  ${n.urls.join(', ')}', style: monoStyle(context, size: 11)),
                    ],
                  ])
                : CellExplanation(data: s.matrix, row: _cell!.$1, verb: _cell!.$2, api: widget.api, onClose: () => setState(() => _cell = null)),
          ),
        ]),
      ),
    ]);
  }
}
