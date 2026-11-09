/// Structured editor for Role / ClusterRole rules: API group and resource
/// pickers fed from discovery, verb toggles, resourceNames and
/// nonResourceURLs, templates, a live YAML / matrix preview, and a
/// dry-run + diff before applying.
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
import 'permission_matrix.dart';
import 'rbac_model.dart';

/// Opens the editor. [existing] is the current object (edit), else a new
/// role is created ([cluster] / [namespace] preset it). Returns true when
/// something was applied.
Future<bool?> showRoleEditor(BuildContext context, {required AccessApi api, Json? existing, bool cluster = false, String? namespace, String? template}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180, maxHeight: 860),
        child: RoleEditor(api: api, existing: existing, cluster: cluster, namespace: namespace, template: template),
      ),
    ),
  );
}

class RoleEditor extends StatefulWidget {
  final AccessApi api;
  final Json? existing;
  final bool cluster;
  final String? namespace;
  final String? template;
  const RoleEditor({super.key, required this.api, this.existing, this.cluster = false, this.namespace, this.template});

  @override
  State<RoleEditor> createState() => _RoleEditorState();
}

class _RoleEditorState extends State<RoleEditor> {
  late bool _cluster;
  late final TextEditingController _name;
  String? _namespace;
  late List<EditableRule> _rules;
  List<ApiResourceInfo> _resources = const [];
  Object? _resourcesError;
  Object? _error;
  bool _busy = false;
  String _preview = 'matrix';

  bool get _editing => widget.existing != null;
  bool get _aggregated => widget.existing?['aggregationRule'] != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _cluster = e != null ? e['kind'] == 'ClusterRole' : widget.cluster;
    _name = TextEditingController(text: dig<String>(e, ['metadata', 'name']) ?? '');
    _namespace = dig<String>(e, ['metadata', 'namespace']) ?? widget.namespace;
    _rules = e != null ? [for (final r in asMapList(e['rules'])) EditableRule.fromJson(r)] : [EditableRule()];
    if (widget.template != null) {
      final t = roleTemplates.where((t) => t.id == widget.template).firstOrNull;
      if (t != null) _rules = t.rules();
    }
    widget.api.resources().then((r) {
      if (mounted) setState(() => _resources = r);
    }, onError: (Object e) {
      if (mounted) setState(() => _resourcesError = e);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Json get _object => buildRole(cluster: _cluster, name: _name.text.trim(), namespace: _namespace, rules: _rules, base: widget.existing);

  List<String> get _problems => [
        if (_name.text.trim().isEmpty) 'Name is required',
        if (!_cluster && (_namespace == null || _namespace!.isEmpty)) 'Pick a namespace',
        for (final (i, r) in _rules.indexed)
          for (final p in r.problems(clusterRole: _cluster)) 'Rule ${i + 1}: $p',
      ];

  void _change(VoidCallback f) => setState(() {
        f();
        _error = null;
      });

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final kind = _cluster ? 'ClusterRole' : 'Role';
    final res = await reviewAndApply(
      context,
      api: widget.api,
      object: _object,
      title: _editing ? 'Update $kind ${_name.text.trim()}?' : 'Create $kind ${_name.text.trim()}?',
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
    final problems = _problems;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Title bar.
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
        child: Row(children: [
          Text(_editing ? 'Edit ${_cluster ? 'ClusterRole' : 'Role'} rules' : 'New ${_cluster ? 'ClusterRole' : 'Role'}', style: theme.textTheme.titleMedium),
          const Spacer(),
          MenuButton<RoleTemplate>(
            tooltip: 'Replace the rules with a template',
            onSelected: (t) => _change(() => _rules = t.rules()),
            items: () => [
              for (final t in roleTemplates)
                PopupMenuItem(
                  value: t,
                  height: 44,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(t.label),
                    Text(t.description, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor), maxLines: 2),
                  ]),
                ),
            ],
            builder: (h) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: h ? AppColors.of(context).hover : null, borderRadius: BorderRadius.circular(6)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.auto_awesome_motion_outlined, size: 15, color: theme.hintColor),
                const SizedBox(width: 6),
                Text('Templates', style: theme.textTheme.bodySmall),
                Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
              ]),
            ),
          ),
          IconButton(tooltip: 'Close', icon: const Icon(Icons.close, size: 18), onPressed: _busy ? null : () => Navigator.pop(context, false)),
        ]),
      ),
      // Identity row.
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Row(children: [
          SegmentedButton<bool>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: false, label: Text('Role')), ButtonSegment(value: true, label: Text('ClusterRole'))],
            selected: {_cluster},
            onSelectionChanged: _editing ? null : (s) => _change(() => _cluster = s.first),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 260,
            child: TextField(
              controller: _name,
              enabled: !_editing,
              decoration: const InputDecoration(labelText: 'Name', isDense: true),
              style: monoStyle(context, size: 12.5),
              onChanged: (_) => _change(() {}),
            ),
          ),
          if (!_cluster) ...[
            const SizedBox(width: 12),
            Text('in', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(width: 8),
            _NamespaceButton(value: _namespace, namespaces: app.namespaces, enabled: !_editing, onChanged: (ns) => _change(() => _namespace = ns)),
          ],
        ]),
      ),
      if (_aggregated)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: InlineMessage('This ClusterRole has an aggregationRule: the controller overwrites its rules with those of the ClusterRoles it selects. Edit those instead.',
              icon: Icons.merge_type),
        ),
      if (_resourcesError != null)
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: ErrorNotice(_resourcesError!, title: "Couldn't load API resources for the pickers", severity: Severity.warn)),
      const Divider(),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Rules.
          Expanded(
            flex: 6,
            child: PageScroll(padding: const EdgeInsets.fromLTRB(20, 12, 16, 20), children: [
              for (final (i, r) in _rules.indexed)
                _RuleCard(
                  key: ObjectKey(r),
                  index: i,
                  rule: r,
                  cluster: _cluster,
                  resources: _resources,
                  onChanged: () => _change(() {}),
                  onDelete: _rules.length == 1 ? null : () => _change(() => _rules.removeAt(i)),
                  onDuplicate: () => _change(() => _rules.insert(i + 1, r.copy())),
                ),
              Row(children: [
                TextButton.icon(onPressed: () => _change(() => _rules.add(EditableRule())), icon: const Icon(Icons.add, size: 16), label: const Text('Add rule')),
                if (_cluster)
                  TextButton.icon(
                    onPressed: () => _change(() => _rules.add(EditableRule(nonResourceURLs: ['/healthz'], verbs: ['get']))),
                    icon: const Icon(Icons.link, size: 16),
                    label: const Text('Add non-resource URL rule'),
                  ),
              ]),
            ]),
          ),
          VerticalDivider(width: 1, color: AppColors.of(context).separator),
          // Preview.
          Expanded(
            flex: 5,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: Row(children: [
                  SegmentedButton<String>(
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    showSelectedIcon: false,
                    segments: const [ButtonSegment(value: 'matrix', label: Text('Matrix')), ButtonSegment(value: 'yaml', label: Text('YAML'))],
                    selected: {_preview},
                    onSelectionChanged: (s) => setState(() => _preview = s.first),
                  ),
                  const Spacer(),
                  if (_preview == 'yaml')
                    IconButton(
                      tooltip: 'Copy YAML',
                      iconSize: 16,
                      icon: const Icon(Icons.copy),
                      onPressed: () => copyToClipboard(context, toYaml(_object), label: 'YAML'),
                    ),
                ]),
              ),
              Expanded(
                child: _preview == 'yaml'
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                        child: SelectableText(toYaml(_object), style: monoStyle(context, size: 11.5)),
                      )
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: PermissionMatrix(data: matrixFromRules([for (final r in _rules) r.toJson()]), compact: true, hideEmpty: true),
                      ),
              ),
            ]),
          ),
        ]),
      ),
      const Divider(),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: ApplyErrorView(_error!)),
          Row(children: [
            Expanded(
              child: problems.isEmpty
                  ? Text(
                      app.readOnly ? 'The backend is read-only: you can preview but not apply.' : 'Validated by the API server (dry run) before you confirm.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    )
                  : Text(problems.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn))),
            ),
            TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy || problems.isNotEmpty || app.readOnly ? null : _apply,
              child: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : Text(_editing ? 'Review changes…' : 'Review & create…'),
            ),
          ]),
        ]),
      ),
    ]);
  }
}

class _NamespaceButton extends StatelessWidget {
  final String? value;
  final List<String> namespaces;
  final bool enabled;
  final ValueChanged<String> onChanged;
  const _NamespaceButton({required this.value, required this.namespaces, required this.onChanged, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.folder_outlined, size: 14, color: theme.hintColor),
      const SizedBox(width: 6),
      Text(value ?? 'Namespace', style: theme.textTheme.bodySmall?.copyWith(color: value == null ? theme.hintColor : null)),
      if (enabled) Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
    ]);
    if (!enabled) return label;
    return SearchablePicker<String>(
      items: () => [for (final n in namespaces) PickerOption(n, n)],
      selected: value,
      hint: 'Namespace',
      onSelected: onChanged,
      builder: (h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: h ? AppColors.of(context).hover : chipFill(context), borderRadius: BorderRadius.circular(6)),
        child: label,
      ),
    );
  }
}

/// One rule: groups, resources, verbs, names (or non-resource URLs).
class _RuleCard extends StatelessWidget {
  final int index;
  final EditableRule rule;
  final bool cluster;
  final List<ApiResourceInfo> resources;
  final VoidCallback onChanged;
  final VoidCallback? onDelete;
  final VoidCallback onDuplicate;
  const _RuleCard({
    super.key,
    required this.index,
    required this.rule,
    required this.cluster,
    required this.resources,
    required this.onChanged,
    required this.onDuplicate,
    this.onDelete,
  });

  List<String> get _groups {
    final gs = {for (final r in resources) r.group}.toList()..sort((a, b) => a.isEmpty ? -1 : (b.isEmpty ? 1 : a.compareTo(b)));
    return gs;
  }

  List<ApiResourceInfo> get _resourceOptions {
    final any = rule.apiGroups.contains('*');
    return [for (final r in resources) if (any || rule.apiGroups.contains(r.group)) r];
  }

  /// Verbs the selected resources support (discovery), to hint unused toggles.
  Set<String> get _supported {
    final out = <String>{};
    for (final r in _resourceOptions) {
      if (rule.resources.contains('*') || rule.resources.contains(r.resource)) out.addAll(r.verbs);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    final dangers = rule.isNonResource ? const <String>[] : editableRuleDangers(rule);
    final problems = rule.problems(clusterRole: cluster);
    final supported = _supported;
    Widget field(String label, Widget child) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 92, child: Padding(padding: const EdgeInsets.only(top: 5), child: Text(label, style: hint))),
            Expanded(child: child),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
      decoration: BoxDecoration(
        border: Border.all(color: problems.isNotEmpty ? severityColor(context, Severity.warn).withValues(alpha: 0.6) : AppColors.of(context).separator),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('Rule ${index + 1}', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          if (rule.isNonResource) Text('non-resource URLs', style: hint),
          for (final d in dangers) ...[const SizedBox(width: 6), StatusBadge(d, severity: Severity.warn)],
          const Spacer(),
          IconButton(tooltip: 'Duplicate rule', iconSize: 15, visualDensity: VisualDensity.compact, icon: const Icon(Icons.copy_all_outlined), onPressed: onDuplicate),
          IconButton(tooltip: 'Delete rule', iconSize: 15, visualDensity: VisualDensity.compact, icon: const Icon(Icons.delete_outline), onPressed: onDelete),
        ]),
        const SizedBox(height: 4),
        if (rule.isNonResource)
          field(
            'URLs',
            _TokenField(
              values: rule.nonResourceURLs,
              hintText: '/healthz, /metrics, /logs/*',
              onChanged: (v) {
                rule.nonResourceURLs = v;
                onChanged();
              },
            ),
          )
        else ...[
          field(
            'API groups',
            _Tokens(
              values: rule.apiGroups,
              display: (g) => g.isEmpty ? 'core' : g,
              onRemove: (g) {
                rule.apiGroups.remove(g);
                onChanged();
              },
              add: _AddButton(
                label: 'group',
                options: () => [const PickerOption('*', '*', detail: 'every group'), for (final g in _groups) if (!rule.apiGroups.contains(g)) PickerOption(g, g.isEmpty ? 'core' : g)],
                onPicked: (g) {
                  if (g == '*') rule.apiGroups.clear();
                  rule.apiGroups.add(g);
                  onChanged();
                },
              ),
            ),
          ),
          field(
            'Resources',
            _Tokens(
              values: rule.resources,
              onRemove: (r) {
                rule.resources.remove(r);
                onChanged();
              },
              add: _AddButton(
                label: 'resource',
                width: 340,
                options: () => [
                  const PickerOption('*', '*', detail: 'every resource and subresource'),
                  for (final r in _resourceOptions)
                    if (!rule.resources.contains(r.resource)) PickerOption(r.resource, r.resource, detail: '${r.groupLabel}${r.namespaced ? '' : ' · cluster'}${r.virtual ? ' · virtual' : ''}'),
                ],
                onPicked: (r) {
                  if (r == '*') rule.resources.clear();
                  rule.resources.add(r);
                  onChanged();
                },
              ),
            ),
          ),
        ],
        field(
          'Verbs',
          Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final v in rule.isNonResource ? const ['get', 'post', 'put', 'delete', 'head'] : standardVerbs)
              _VerbToggle(
                verb: v,
                selected: rule.verbs.contains(v) || rule.verbs.contains('*'),
                dim: !rule.isNonResource && supported.isNotEmpty && !supported.contains(v),
                onTap: () {
                  if (rule.verbs.contains('*')) rule.verbs = rule.isNonResource ? ['get', 'post', 'put', 'delete', 'head'] : [...standardVerbs];
                  rule.verbs.contains(v) ? rule.verbs.remove(v) : rule.verbs.add(v);
                  onChanged();
                },
              ),
            if (!rule.isNonResource)
              for (final v in specialVerbs.where((v) => rule.verbs.contains(v))) _VerbToggle(verb: v, selected: true, onTap: () {
                rule.verbs.remove(v);
                onChanged();
              }),
            _VerbToggle(
              verb: '*',
              selected: rule.verbs.contains('*'),
              onTap: () {
                rule.verbs = rule.verbs.contains('*') ? [...readVerbs] : ['*'];
                onChanged();
              },
            ),
            if (!rule.isNonResource) ...[
              const SizedBox(width: 6),
              _QuickLink('read', () {
                rule.verbs = [...readVerbs];
                onChanged();
              }),
              _QuickLink('read + write', () {
                rule.verbs = [...readVerbs, ...writeVerbs];
                onChanged();
              }),
              MenuButton<String>(
                tooltip: 'Special verbs',
                onSelected: (v) {
                  if (!rule.verbs.contains(v)) rule.verbs.add(v);
                  onChanged();
                },
                items: () => [for (final v in specialVerbs) PopupMenuItem(value: v, height: 28, child: Text(v))],
                builder: (h) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text('more…', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary, decoration: h ? TextDecoration.underline : null)),
                ),
              ),
            ],
          ]),
        ),
        if (!rule.isNonResource)
          field(
            'Only names',
            _TokenField(
              values: rule.resourceNames,
              hintText: 'all objects (optional: comma-separated names)',
              onChanged: (v) {
                rule.resourceNames = v;
                onChanged();
              },
            ),
          ),
        if (problems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 92),
            child: Text(problems.join(' · '), style: theme.textTheme.labelSmall?.copyWith(color: severityColor(context, Severity.warn))),
          ),
      ]),
    );
  }
}

class _Tokens extends StatelessWidget {
  final List<String> values;
  final String Function(String)? display;
  final void Function(String) onRemove;
  final Widget add;
  const _Tokens({required this.values, required this.onRemove, required this.add, this.display});

  @override
  Widget build(BuildContext context) {
    final warn = severityColor(context, Severity.warn);
    return Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final v in values)
        Hoverable(
          cursor: SystemMouseCursors.basic,
          onTap: () => onRemove(v),
          builder: (h) => Container(
            padding: const EdgeInsets.fromLTRB(7, 2, 4, 2),
            decoration: BoxDecoration(color: chipFill(context, hovered: h), borderRadius: BorderRadius.circular(5)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(display?.call(v) ?? v, style: monoStyle(context, size: 11.5, color: v.contains('*') ? warn : null)),
              const SizedBox(width: 3),
              Icon(Icons.close, size: 11, color: h ? Theme.of(context).colorScheme.onSurface : Theme.of(context).hintColor),
            ]),
          ),
        ),
      add,
    ]);
  }
}

class _AddButton extends StatelessWidget {
  final String label;
  final List<PickerOption<String>> Function() options;
  final void Function(String) onPicked;
  final double width;
  const _AddButton({required this.label, required this.options, required this.onPicked, this.width = 280});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SearchablePicker<String>(
      items: options,
      hint: 'Add $label',
      width: width,
      onSelected: onPicked,
      builder: (h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: theme.colorScheme.primary.withValues(alpha: h ? 0.8 : 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add, size: 12, color: theme.colorScheme.primary),
          const SizedBox(width: 2),
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
        ]),
      ),
    );
  }
}

/// Comma-separated free text (names, URLs).
class _TokenField extends StatefulWidget {
  final List<String> values;
  final String hintText;
  final ValueChanged<List<String>> onChanged;
  const _TokenField({required this.values, required this.hintText, required this.onChanged});

  @override
  State<_TokenField> createState() => _TokenFieldState();
}

class _TokenFieldState extends State<_TokenField> {
  late final _c = TextEditingController(text: widget.values.join(', '));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 28,
        child: TextField(
          controller: _c,
          style: monoStyle(context, size: 11.5),
          decoration: InputDecoration(hintText: widget.hintText, isDense: true),
          onChanged: (v) => widget.onChanged([for (final s in v.split(',')) if (s.trim().isNotEmpty) s.trim()]),
        ),
      );
}

class _VerbToggle extends StatelessWidget {
  final String verb;
  final bool selected;
  final bool dim;
  final VoidCallback onTap;
  const _VerbToggle({required this.verb, required this.selected, required this.onTap, this.dim = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final special = verb == '*' || specialVerbs.contains(verb);
    final c = special ? severityColor(context, Severity.warn) : theme.colorScheme.primary;
    return Tooltip(
      message: dim ? '$verb: not served by the selected resources' : verb,
      waitDuration: const Duration(milliseconds: 600),
      child: Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: onTap,
        builder: (h) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: selected ? c.withValues(alpha: 0.18) : (h ? AppColors.of(context).hover : null),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: selected ? c.withValues(alpha: 0.7) : AppColors.of(context).separator),
          ),
          child: Text(verb,
              style: monoStyle(context, size: 11.5, color: selected ? c : (dim ? AppColors.of(context).faint : null))
                  .copyWith(fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
        ),
      ),
    );
  }
}

class _QuickLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _QuickLink(this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Hoverable(
      cursor: SystemMouseCursors.click,
      onTap: onTap,
      builder: (h) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary, decoration: h ? TextDecoration.underline : null)),
      ),
    );
  }
}
