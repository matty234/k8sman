/// "Grant `subject` `role` in `namespace` or cluster-wide": builds a RoleBinding
/// or ClusterRoleBinding (or adds the subject to an existing binding of the
/// same role), dry-runs it and applies after a diff.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart';
import '../widgets/searchable_picker.dart';
import 'access_api.dart';
import 'access_apply.dart';
import 'access_widgets.dart';
import 'permission_matrix.dart';
import 'rbac_model.dart';

Future<bool?> showGrantDialog(BuildContext context, {required AccessApi api, RbacSubject? subject, RbacRef? role, String? namespace}) => showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980, maxHeight: 780),
          child: GrantDialog(api: api, subject: subject, role: role, namespace: namespace),
        ),
      ),
    );

class GrantDialog extends StatefulWidget {
  final AccessApi api;
  final RbacSubject? subject;
  final RbacRef? role;
  final String? namespace;
  const GrantDialog({super.key, required this.api, this.subject, this.role, this.namespace});

  @override
  State<GrantDialog> createState() => _GrantDialogState();
}

class _RoleOption {
  final RbacRef ref;
  final Json object;
  const _RoleOption(this.ref, this.object);
}

class _GrantDialogState extends State<GrantDialog> {
  late String _kind = widget.subject?.kind ?? 'ServiceAccount';
  late final _subjectName = TextEditingController(text: widget.subject?.name ?? '');
  late String? _subjectNs = widget.subject?.namespace ?? widget.namespace;
  RbacRef? _role;

  /// Where: a namespace (RoleBinding), or null for cluster-wide.
  late String? _scope = widget.role?.kind == 'Role' ? widget.role!.namespace : (widget.namespace ?? widget.subject?.namespace);
  bool _clusterWide = false;
  final _bindingName = TextEditingController();
  bool _nameEdited = false;

  /// Existing binding to add the subject to (same role & scope), or null.
  Json? _addTo;

  List<_RoleOption> _roles = const [];
  List<Json> _bindings = const [];
  SubjectList? _subjects;
  Object? _loadError;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _role = widget.role;
    _load();
  }

  @override
  void dispose() {
    _subjectName.dispose();
    _bindingName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      final res = await Future.wait([
        api.items(const ResourceRef(group: rbacApiGroup, resource: 'clusterroles')),
        api.items(const ResourceRef(group: rbacApiGroup, resource: 'roles')),
        api.items(const ResourceRef(group: rbacApiGroup, resource: 'rolebindings')),
        api.items(const ResourceRef(group: rbacApiGroup, resource: 'clusterrolebindings')),
      ]);
      final subjects = await widget.api.subjects().then<SubjectList?>((s) => s, onError: (_) => null);
      if (!mounted) return;
      setState(() {
        _roles = [
          for (final r in res[0]) _RoleOption(RbacRef('ClusterRole', dig<String>(r, ['metadata', 'name']) ?? ''), r),
          for (final r in res[1]) _RoleOption(RbacRef('Role', dig<String>(r, ['metadata', 'name']) ?? '', dig<String>(r, ['metadata', 'namespace'])), r),
        ];
        _bindings = [...res[2], ...res[3]];
        _subjects = subjects;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  RbacSubject? get _subject {
    final n = _subjectName.text.trim();
    if (n.isEmpty) return null;
    if (_kind == 'ServiceAccount') return _subjectNs == null ? null : RbacSubject.sa(_subjectNs!, n);
    return RbacSubject(kind: _kind, name: n);
  }

  /// RoleBinding namespace; null = ClusterRoleBinding.
  String? get _bindingNs => _role?.kind == 'Role' ? _role!.namespace : (_clusterWide ? null : _scope);

  _RoleOption? get _roleOption => _roles.where((r) => r.ref == _role).firstOrNull;

  /// Bindings of the chosen role in the chosen scope.
  List<Json> get _sameRoleBindings {
    final role = _role;
    if (role == null) return const [];
    final ns = _bindingNs;
    return [
      for (final b in _bindings)
        if (dig<String>(b, ['roleRef', 'kind']) == role.kind &&
            dig<String>(b, ['roleRef', 'name']) == role.name &&
            dig<String>(b, ['metadata', 'namespace']) == ns &&
            (ns != null || b['kind'] == 'ClusterRoleBinding' || dig<String>(b, ['metadata', 'namespace']) == null))
          b,
    ];
  }

  String get _suggestedName => _role == null || _subject == null ? '' : suggestBindingName(_role!.name, _subject!);

  Json? get _object {
    final s = _subject, role = _role;
    if (s == null || role == null) return null;
    final ns = _bindingNs;
    if (role.kind == 'ClusterRole' && !_clusterWide && ns == null) return null;
    final existing = _addTo;
    // List items carry no apiVersion/kind.
    if (existing != null) return bindingWith({...existing, 'apiVersion': '$rbacApiGroup/v1', 'kind': ns == null ? 'ClusterRoleBinding' : 'RoleBinding'}, s);
    final name = _nameEdited ? _bindingName.text.trim() : _suggestedName;
    if (name.isEmpty) return null;
    return buildBinding(name: name, namespace: ns, roleKind: role.kind, roleName: role.name, subjects: [s.toSubjectJson()]);
  }

  void _change(VoidCallback f) => setState(() {
        f();
        _error = null;
        if (!_nameEdited) _bindingName.text = _suggestedName;
        if (_addTo != null && !_sameRoleBindings.any((b) => dig(b, ['metadata', 'name']) == dig(_addTo, ['metadata', 'name']))) _addTo = null;
      });

  Future<void> _apply() async {
    final obj = _object;
    final s = _subject;
    if (obj == null || s == null) return;
    setState(() => _busy = true);
    final where = _bindingNs == null ? 'cluster-wide' : 'in ${_bindingNs!}';
    final res = await reviewAndApply(
      context,
      api: widget.api,
      object: obj,
      title: 'Grant ${_role!.kind} ${_role!.name} to ${s.label} $where?',
      message: _addTo != null ? 'Adds ${s.label} to the existing ${obj['kind']} ${dig(obj, ['metadata', 'name'])}.' : null,
      confirmLabel: 'Grant',
      onError: (e) => setState(() => _error = e),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res != null) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final obj = _object;
    final role = _roleOption;
    Widget label(String t) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(t, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
        child: Row(children: [
          Text('Grant access', style: theme.textTheme.titleMedium),
          const Spacer(),
          IconButton(tooltip: 'Close', icon: const Icon(Icons.close, size: 18), onPressed: _busy ? null : () => Navigator.pop(context, false)),
        ]),
      ),
      const Divider(),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            flex: 5,
            child: PageScroll(padding: const EdgeInsets.fromLTRB(20, 4, 16, 16), children: [
              if (_loadError != null) ErrorNotice(_loadError!, title: "Couldn't load roles and bindings"),
              label('Who'),
              Row(children: [
                SegmentedButton<String>(
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'ServiceAccount', label: Text('ServiceAccount')),
                    ButtonSegment(value: 'User', label: Text('User')),
                    ButtonSegment(value: 'Group', label: Text('Group')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => _change(() => _kind = s.first),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                if (_kind == 'ServiceAccount') ...[
                  _Picker(
                    value: _subjectNs,
                    placeholder: 'Namespace',
                    icon: Icons.folder_outlined,
                    options: () => [for (final n in app.namespaces) PickerOption(n, n)],
                    onPicked: (ns) => _change(() => _subjectNs = ns),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: SizedBox(
                    height: 30,
                    child: TextField(
                      controller: _subjectName,
                      style: monoStyle(context, size: 12),
                      decoration: InputDecoration(isDense: true, hintText: _kind == 'User' ? 'jane@example.com' : (_kind == 'Group' ? 'team-devs' : 'ServiceAccount name')),
                      onChanged: (_) => _change(() {}),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _Picker(
                  value: null,
                  placeholder: 'Known…',
                  icon: subjectIcon(_kind),
                  width: 340,
                  options: () {
                    final s = _subjects;
                    if (s == null) return const [];
                    final list = switch (_kind) { 'ServiceAccount' => s.serviceAccounts, 'Group' => s.groups, _ => s.users };
                    return [
                      for (final i in list)
                        if (_kind != 'ServiceAccount' || _subjectNs == null || i.subject.namespace == _subjectNs)
                          PickerOption(i.subject.label, i.subject.label, detail: '${i.bindings} binding${i.bindings == 1 ? '' : 's'}'),
                    ];
                  },
                  onPicked: (v) => _change(() {
                    if (_kind == 'ServiceAccount' && v.contains('/')) {
                      _subjectNs = v.split('/').first;
                      _subjectName.text = v.split('/').sublist(1).join('/');
                    } else {
                      _subjectName.text = v;
                    }
                  }),
                ),
              ]),
              if (_kind == 'Group' && wellKnownGroup(_subjectName.text.trim()) != null)
                Padding(padding: const EdgeInsets.only(top: 4), child: Text('${_subjectName.text.trim()}: ${wellKnownGroup(_subjectName.text.trim())}', style: hint)),
              label('Role'),
              _Picker(
                value: _role == null ? null : '${_role!.kind} ${_role!.label}',
                placeholder: 'Pick a ClusterRole or Role',
                icon: Icons.admin_panel_settings_outlined,
                width: 420,
                options: () => [
                  for (final r in _roles)
                    if (r.ref.kind == 'ClusterRole' || _scope == null || r.ref.namespace == _scope)
                      PickerOption('${r.ref.kind} ${r.ref.label}', r.ref.label, detail: '${r.ref.kind}${_dangerHint(r.object)}'),
                ],
                onPicked: (v) => _change(() {
                  _role = _roles.firstWhere((r) => '${r.ref.kind} ${r.ref.label}' == v).ref;
                  if (_role!.kind == 'Role') {
                    _scope = _role!.namespace;
                    _clusterWide = false;
                  }
                }),
              ),
              label('Where'),
              if (_role?.kind == 'Role')
                Text('In namespace ${_role!.namespace} (a Role can only be bound in its own namespace).', style: hint)
              else ...[
                _Radio(
                  selected: !_clusterWide,
                  onTap: () => _change(() => _clusterWide = false),
                  child: Row(children: [
                    const Text('In namespace '),
                    _Picker(
                      value: _scope,
                      placeholder: 'Namespace',
                      icon: Icons.folder_outlined,
                      options: () => [for (final n in app.namespaces) PickerOption(n, n)],
                      onPicked: (ns) => _change(() {
                        _scope = ns;
                        _clusterWide = false;
                      }),
                    ),
                    const SizedBox(width: 8),
                    Flexible(child: Text('RoleBinding', style: hint)),
                  ]),
                ),
                _Radio(
                  selected: _clusterWide,
                  onTap: () => _change(() => _clusterWide = true),
                  child: Row(children: [
                    const Text('Cluster-wide'),
                    const SizedBox(width: 8),
                    Flexible(child: Text('ClusterRoleBinding: every namespace, plus cluster-scoped resources', style: hint)),
                  ]),
                ),
              ],
              label('Binding'),
              _Radio(
                selected: _addTo == null,
                onTap: () => _change(() => _addTo = null),
                child: Row(children: [
                  const Text('New '),
                  SizedBox(
                    width: 280,
                    height: 28,
                    child: TextField(
                      controller: _bindingName,
                      enabled: _addTo == null,
                      style: monoStyle(context, size: 12),
                      decoration: const InputDecoration(isDense: true, hintText: 'binding name'),
                      onChanged: (_) => setState(() {
                        _nameEdited = true;
                        _error = null;
                      }),
                    ),
                  ),
                ]),
              ),
              for (final b in _sameRoleBindings)
                _Radio(
                  selected: _addTo != null && dig(_addTo, ['metadata', 'name']) == dig(b, ['metadata', 'name']),
                  onTap: () => _change(() => _addTo = b),
                  child: Text.rich(TextSpan(children: [
                    const TextSpan(text: 'Add to existing '),
                    TextSpan(text: '${dig(b, ['metadata', 'name'])}', style: monoStyle(context, size: 12)),
                    TextSpan(text: '  ${asMapList(b['subjects']).length} subject${asMapList(b['subjects']).length == 1 ? '' : 's'}', style: hint),
                  ])),
                ),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 14), child: ApplyErrorView(_error!)),
            ]),
          ),
          VerticalDivider(width: 1, color: AppColors.of(context).separator),
          Expanded(
            flex: 4,
            child: PageScroll(padding: const EdgeInsets.fromLTRB(14, 12, 14, 14), children: [
              if (role != null) ...[
                Text('What ${role.ref.name} grants', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                RoleRulesMatrix(rules: asMapList(role.object['rules']), role: role.ref),
                if (_bindingNs != null && role.ref.kind == 'ClusterRole')
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Bound with a RoleBinding, only namespaced resources in ${_bindingNs!} are granted; cluster-scoped rules and URLs are ignored.', style: hint),
                  ),
                const SizedBox(height: 14),
              ],
              Text('YAML', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              SelectableText(obj == null ? '# Pick a subject, a role and where' : toYaml(_addTo == null ? obj : _stripForPreview(obj)), style: monoStyle(context, size: 11.5)),
            ]),
          ),
        ]),
      ),
      const Divider(),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 16, 14),
        child: Row(children: [
          Expanded(
            child: Text(
              app.readOnly ? 'The backend is read-only: you can preview but not apply.' : 'Validated by the API server (dry run) before you confirm. You can\'t grant permissions you don\'t hold.',
              style: hint,
            ),
          ),
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _busy || obj == null || app.readOnly ? null : _apply,
            child: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Review & grant…'),
          ),
        ]),
      ),
    ]);
  }

  static String _dangerHint(Json role) {
    final dangers = {for (final r in asMapList(role['rules'])) ...editableRuleDangers(EditableRule.fromJson(r))};
    return dangers.isEmpty ? '' : ' · ${dangers.first}';
  }

  static Json _stripForPreview(Json obj) {
    final meta = Map<String, dynamic>.from(asMap(obj['metadata']));
    for (final k in ['resourceVersion', 'uid', 'creationTimestamp', 'annotations', 'labels']) {
      meta.remove(k);
    }
    return {...obj, 'metadata': meta};
  }
}

class _Radio extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  const _Radio({required this.selected, required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: onTap,
      builder: (h) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 16, color: selected ? theme.colorScheme.primary : theme.hintColor),
          const SizedBox(width: 8),
          Expanded(child: DefaultTextStyle.merge(style: theme.textTheme.bodySmall, child: child)),
        ]),
      ),
    );
  }
}

class _Picker extends StatelessWidget {
  final String? value;
  final String placeholder;
  final IconData icon;
  final List<PickerOption<String>> Function() options;
  final ValueChanged<String> onPicked;
  final double width;
  const _Picker({required this.value, required this.placeholder, required this.icon, required this.options, required this.onPicked, this.width = 280});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SearchablePicker<String>(
      items: options,
      selected: value,
      hint: placeholder,
      width: width,
      onSelected: onPicked,
      builder: (h) => Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(color: h ? AppColors.of(context).hover : chipFill(context), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: theme.hintColor),
          const SizedBox(width: 6),
          Text(value ?? placeholder, style: theme.textTheme.bodySmall?.copyWith(color: value == null ? theme.hintColor : null)),
          Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
        ]),
      ),
    );
  }
}
