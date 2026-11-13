import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../app/window_chrome.dart';
import '../../plugins/plugin_host.dart' show pluginHost;
import '../../plugins/plugin_icons.dart';
import '../../state/app_state.dart';
import '../../util/diff.dart';
import '../../util/k8s.dart';
import '../../util/yaml_lines.dart';
import '../detail/yaml_editor.dart' show DiffView;
import '../keys.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart';
import 'resource_templates.dart';
import 'yaml_code_editor.dart';
import '../widgets/dialogs.dart';
import '../../panels/argocd/argo_managed.dart';

/// Opens [target] in the full-window YAML editor.
Future<void> openResourceEditor(BuildContext context, DetailTarget target, {bool statusMode = false}) =>
    Navigator.of(context).push(_route(ResourceEditorScreen(target: target, statusMode: statusMode)));

/// Opens the full-window editor to create resources, starting from [kind]'s
/// template (or a Deployment) in [namespace] (else the app's namespace).
Future<void> openCreateResource(BuildContext context, {ResourceType? kind, String? namespace}) =>
    Navigator.of(context).push(_route(ResourceEditorScreen(kind: kind, namespace: namespace)));

/// Full-window and instant, like switching to a native editor window.
PageRoute<void> _route(Widget child) => PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => child,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );

/// A problem pointed at a line (1-based) of the editor, when known.
typedef _Problem = ({int? line, String message});

/// Split-screen YAML editor: the editor on the left, and on the right a live
/// diff and validation (editing an object) or templates and per-document
/// dry-run results (creating). Every write is confirmed with the target
/// context named.
class ResourceEditorScreen extends StatefulWidget {
  /// The object to edit; null to create.
  final DetailTarget? target;

  /// Create mode: the kind whose template to start from, and the namespace.
  final ResourceType? kind;
  final String? namespace;
  /// Edit the object's `status` subresource: only `.status` is saved.
  final bool statusMode;
  const ResourceEditorScreen({super.key, this.target, this.kind, this.namespace, this.statusMode = false});

  @override
  State<ResourceEditorScreen> createState() => _ResourceEditorScreenState();
}

class _ResourceEditorScreenState extends State<ResourceEditorScreen> with SingleTickerProviderStateMixin {
  final _controller = CodeLineEditingController();
  final _scroll = CodeScrollController();
  late final _find = CodeFindController(_controller);
  late final _tabs = TabController(length: 2, vsync: this, animationDuration: Duration.zero);

  ApiClient get _api => context.read<ApiClient>();
  DetailTarget? get _t => widget.target;
  bool get _creating => _t == null;
  bool get _status => widget.statusMode && !_creating;

  /// The diff the user cares about: whole text, or just `.status` in status mode.
  List<DiffLine> _diffOf(String from, String to) => _status ? diffLines(_statusPart(from), _statusPart(to)) : diffLines(from, to);

  /// Whether the text differs from the server copy outside `.status`.
  bool get _editedOutsideStatus => _status && !_loading && _withoutStatus(_original) != _withoutStatus(_controller.text);

  // Edit mode: the server copy and its live state.
  String _original = '';
  String _baseRv = '';
  String _liveRv = '';
  bool _loading = false;
  String? _loadError;
  bool _serverChanged = false;
  bool _deleted = false;
  StreamSubscription<WatchMessage>? _watch;

  // Create mode: the namespace, and the template text last put in the editor.
  late String _namespace;
  ResourceTemplate? _template;
  String _pristine = '';

  /// Create mode: the plugins' templates (for the kind, when one is given),
  /// how many placeholders are left in the text, and the one Tab last
  /// selected (to copy what replaced it into its namesakes).
  List<ResourceTemplate> _pluginTemplates = const [];
  int _placeholders = 0;
  ({String name, int line, int start})? _filling;
  late final _editorFocus = FocusNode(debugLabel: 'ResourceEditor', onKeyEvent: _onEditorKey);

  bool _busy = false;
  bool _sideOpen = true;
  double _sideWidth = 460;

  /// The live diff (edit mode), recomputed shortly after typing stops.
  List<DiffLine> _diff = const [];
  Timer? _debounce;
  bool _wasDirty = false;

  // The last validate/apply outcome, and the text it was for.
  String? _checkedText;
  bool? _checkOk;
  String? _checkMessage;
  List<_Problem> _problems = const [];
  ManifestResult? _applyResult;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _namespace = widget.namespace ?? app.namespace ?? app.namespaceScope.namespaces.firstOrNull ?? (app.namespaces.contains('default') || app.namespaces.isEmpty ? 'default' : app.namespaces.first);
    if (_creating) {
      _setTemplate(templateFor(widget.kind));
      _loadPluginTemplates();
    } else {
      _load();
      _startWatch();
    }
    _controller.addListener(_onEdit);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _watch?.cancel();
    _controller.removeListener(_onEdit);
    _find.dispose();
    _editorFocus.dispose();
    _controller.dispose();
    _scroll.dispose();
    _tabs.dispose();
    super.dispose();
  }

  bool get _dirty => _creating ? _controller.text.trim().isNotEmpty && _controller.text != _pristine : !_loading && _controller.text != _original;

  bool _readOnly(AppState app) => app.readOnly || (!_creating && !_t!.type.can('update'));

  void _onEdit() {
    if (!_creating) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 250), () {
        if (mounted) setState(() => _diff = _diffOf(_original, _controller.text));
      });
    }
    // Rebuild on dirty flips, placeholder count changes and to mark results
    // out of date, not per key.
    final dirty = _dirty, stale = _checkedText != null && _checkedText != _controller.text;
    final placeholders = _creating ? placeholderRe.allMatches(_controller.text).length : 0;
    if (dirty != _wasDirty || placeholders != _placeholders || (stale && _problems.isNotEmpty)) {
      _wasDirty = dirty;
      _placeholders = placeholders;
      setState(() {});
    }
  }

  // ---- edit mode -----------------------------------------------------------

  Future<void> _load() async {
    final t = _t!;
    setState(() => (_loading = true, _loadError = null));
    try {
      final y = _status
          ? await _api.subresourceYaml(t.type.ref, 'status', namespace: t.namespace, name: t.name)
          : await _api.objectYaml(t.type.ref, namespace: t.namespace, name: t.name);
      if (!mounted) return;
      setState(() {
        _original = y;
        _baseRv = RegExp(r'^\s*resourceVersion:\s*"?(\d+)"?', multiLine: true).firstMatch(y)?.group(1) ?? '';
        _liveRv = _baseRv;
        _controller.text = y;
        _diff = _diffOf(y, y);
        _loading = false;
        _serverChanged = false;
        _deleted = false;
        _wasDirty = false;
      });
    } catch (e) {
      if (mounted) setState(() => (_loading = false, _loadError = '$e'));
    }
  }

  /// Follows the object's resourceVersion to flag concurrent changes.
  void _startWatch() {
    final t = _t!;
    void seen(String type, TableRowData? row) {
      if (!mounted || _loading) return;
      if (type == 'DELETED') {
        setState(() => _deleted = true);
        return;
      }
      final rv = row?.resourceVersion ?? '';
      if (rv.isEmpty || rv == _liveRv) return;
      setState(() {
        _liveRv = rv;
        if (rv != _baseRv) _serverChanged = true;
      });
    }

    try {
      _watch = _api.watch(t.type.ref, namespace: t.namespace, fieldSelector: 'metadata.name=${t.name}').listen((m) {
        for (final e in m.frames) {
          switch (e.type) {
            case 'SNAPSHOT':
              final row = e.table?.rows.where((r) => r.name == t.name).firstOrNull;
              row == null ? seen('DELETED', null) : seen('MODIFIED', row);
            case 'ADDED' || 'MODIFIED' || 'DELETED':
              seen(e.type, e.row);
          }
        }
      }, onError: (Object _) {}, cancelOnError: true);
    } catch (_) {
      // No live updates; applying still fails safely on a conflict.
    }
  }

  // ---- create mode ---------------------------------------------------------

  void _setTemplate(ResourceTemplate t) {
    _template = t;
    _pristine = t.build(_namespace);
    _controller.text = _pristine;
    _placeholders = placeholderRe.allMatches(_pristine).length;
    _filling = null;
    _clearCheck();
    _selectPlaceholder(0, 0);
  }

  /// The active plugins' templates: for the kind being created, or all.
  Future<void> _loadPluginTemplates() async {
    try {
      final list = await _api.pluginTemplates(kind: widget.kind?.gk);
      if (mounted) setState(() => _pluginTemplates = [for (final j in list) ResourceTemplate.fromPlugin(j)]);
    } catch (_) {
      // No plugins (or an older backend): the built-in templates only.
    }
  }

  /// Selects the first placeholder at or after [line]:[offset] (wrapping),
  /// so typing replaces it. False when there is none.
  bool _selectPlaceholder(int line, int offset) {
    final lines = [for (final l in _controller.codeLines.toList()) l.text];
    final p = nextPlaceholder(lines, line, offset);
    if (p == null) return false;
    _filling = (name: p.name, line: p.line, start: p.start);
    _controller.selection = CodeLineSelection(baseIndex: p.line, baseOffset: p.start, extentIndex: p.line, extentOffset: p.end);
    _controller.makePositionCenterIfInvisible(CodeLinePosition(index: p.line, offset: p.start));
    return true;
  }

  /// Tab in create mode, while placeholders are left: copies what replaced
  /// the last one Tab selected into the others of its name, then selects
  /// the next. Otherwise Tab indents as usual.
  KeyEventResult _onEditorKey(FocusNode node, KeyEvent event) {
    final kb = HardwareKeyboard.instance;
    if (!_creating || event is KeyUpEvent || event.logicalKey != LogicalKeyboardKey.tab || kb.isShiftPressed || kb.isMetaPressed || kb.isControlPressed || kb.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (_placeholders == 0 || _readOnly(context.read<AppState>())) return KeyEventResult.ignored;
    final sel = _controller.selection;
    var line = sel.endIndex, offset = sel.endOffset;
    final f = _filling;
    if (f != null && sel.isCollapsed && sel.extentIndex == f.line && sel.extentOffset >= f.start && f.line < _controller.codeLines.length) {
      final text = _controller.codeLines[f.line].text;
      final still = placeholderRe.matchAsPrefix(text, f.start);
      final value = text.substring(f.start, sel.extentOffset);
      if ((still == null || still[1] != f.name) && value.isNotEmpty) {
        _controller.replaceAll(RegExp(r'\$\{' + RegExp.escape(f.name) + r'(?::[^}\n]*)?\}'), value);
        (line, offset) = (f.line, f.start + value.length);
      }
    }
    if (!_selectPlaceholder(line, offset)) _filling = null;
    return KeyEventResult.handled;
  }

  /// Replaces every `${name:default}` with its default.
  void _useDefaults() {
    final defaults = {for (final m in placeholderRe.allMatches(_controller.text)) if (m[2] != null) m[0]!: m[2]!};
    for (final e in defaults.entries) {
      _controller.replaceAll(e.key, e.value);
    }
    _filling = null;
    _editorFocus.requestFocus();
  }

  bool get _hasDefaults => placeholderRe.allMatches(_controller.text).any((m) => m[2] != null);

  Future<void> _pickTemplate(ResourceTemplate t) async {
    if (_dirty && !await _confirmDiscard('Replace your edits with the ${t.label} template?', 'Replace')) return;
    setState(() => _setTemplate(t));
    _editorFocus.requestFocus(); // so typing fills the selected placeholder
  }

  void _setNamespace(String ns) {
    setState(() {
      final pristine = !_dirty;
      _namespace = ns;
      if (pristine && _template != null) _setTemplate(_template!);
    });
  }

  // ---- validate / apply ----------------------------------------------------

  void _clearCheck() {
    _checkedText = null;
    _checkOk = null;
    _checkMessage = null;
    _problems = const [];
    _applyResult = null;
  }

  bool get _stale => _checkedText != null && _checkedText != _controller.text;

  void _showResults() {
    _sideOpen = true;
    _tabs.index = 1;
  }

  List<_Problem> _problemsFor(String text, String message, List<Map<String, dynamic>> causes, {int docStart = 1}) => [
        if (causes.isEmpty) (line: lineFromYamlError(message, docStart: docStart) ?? (docStart > 1 ? docStart : null), message: message),
        for (final c in causes)
          (
            line: lineForFieldPath(text, '${c['field'] ?? ''}', docStart: docStart) ?? docStart,
            message: [if ('${c['field'] ?? ''}'.isNotEmpty) '${c['field']}', '${c['message'] ?? ''}'].join(': '),
          ),
      ];

  /// Edit mode: PUT the object (optionally as a dry run).
  Future<bool> _submitEdit({required bool dryRun}) async {
    final t = _t!, text = _controller.text;
    setState(() => _busy = true);
    try {
      final res = _status
          ? await _api.updateSubresource(t.type.ref, 'status', namespace: t.namespace, name: t.name, yaml: text, dryRun: dryRun)
          : await _api.updateObject(t.type.ref, namespace: t.namespace, name: t.name, yaml: text, dryRun: dryRun);
      if (!mounted) return false;
      setState(() {
        _busy = false;
        _checkedText = text;
        _checkOk = true;
        _checkMessage = dryRun ? 'Valid: the API server accepted a dry run of this change.' : 'Applied · resourceVersion ${res.resourceVersion}';
        _problems = const [];
      });
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      setState(() {
        _busy = false;
        if (e.isConflict) _serverChanged = true;
        _checkedText = text;
        _checkOk = false;
        _checkMessage = e.isConflict ? 'Conflict: the object changed on the server since you started editing.' : e.message;
        _problems = e.isConflict ? const [] : _problemsFor(text, e.message, e.causes);
        _showResults();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _checkedText = text;
          _checkOk = false;
          _checkMessage = '$e';
          _problems = const [];
          _showResults();
        });
      }
    }
    return false;
  }

  /// Create mode: POST the documents (optionally as a dry run, or with
  /// server-side apply).
  Future<ManifestResult?> _submitCreate({required bool dryRun, bool serverSide = false}) async {
    final text = _controller.text;
    setState(() => _busy = true);
    try {
      final res = await _api.applyManifests(text, namespace: _namespace, dryRun: dryRun, serverSide: serverSide);
      if (!mounted) return null;
      setState(() {
        _busy = false;
        _checkedText = text;
        _applyResult = res;
        _checkOk = res.ok;
        final done = res.results.where((r) => r.ok).length;
        _checkMessage = res.ok
            ? (dryRun ? 'Valid: the API server accepted a dry run of ${_count(res.results.length)}.' : '${serverSide ? 'Applied' : 'Created'} ${_count(done)}.')
            : '${res.results.length - done} of ${_count(res.results.length)} ${dryRun ? 'would fail' : 'failed'}.';
        _problems = [
          for (final r in res.results)
            if (!r.ok) ..._problemsFor(text, r.error!, r.causes, docStart: r.line),
        ];
        if (!dryRun && done > 0) _pristine = text; // nothing left unsaved
        _showResults();
      });
      return res;
    } on ApiException catch (e) {
      _failCreate(text, e.message, e.causes);
    } catch (e) {
      _failCreate(text, '$e', const []);
    }
    return null;
  }

  void _failCreate(String text, String message, List<Map<String, dynamic>> causes) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _checkedText = text;
      _applyResult = null;
      _checkOk = false;
      _checkMessage = message;
      _problems = _problemsFor(text, message, causes);
      _showResults();
    });
  }

  static String _count(int n) => '$n object${n == 1 ? '' : 's'}';

  Future<void> _validate() async {
    if (_busy || _readOnly(context.read<AppState>())) return;
    _creating ? await _submitCreate(dryRun: true) : await _submitEdit(dryRun: true);
  }

  /// ⌘S: validate, review (the diff, or what will be created), then apply.
  Future<void> _reviewAndApply() => _apply(review: true);

  /// ⌘↩ and the Apply/Create button. With [review], a failed dry run stops
  /// before the confirmation.
  Future<void> _apply({bool review = false}) async {
    final app = context.read<AppState>();
    if (_busy || _readOnly(app) || _loading) return;
    if (_creating) return _create(app, review: review);
    final t = _t!;
    if (!_dirty) return;
    if (review && !await _submitEdit(dryRun: true)) return;
    if (!mounted) return;
    final lines = _diffOf(_original, _controller.text);
    final stats = diffStats(lines);
    final ok = await confirmAction(
      context,
      title: _status ? 'Apply status changes to ${t.type.kind} ${t.name}?' : 'Apply changes to ${t.type.kind} ${t.name}?',
      message: '${_status ? 'Only .status is written. ' : ''}+${stats.added} −${stats.removed} lines.${review ? ' Validated by a server-side dry run.' : ''}',
      kubeContext: app.currentContext,
      objectName: t.name,
      destructive: true,
      confirmLabel: 'Apply',
      width: 720,
      extra: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ArgoManagedNotice(target: t),
          SizedBox(height: 360, child: DiffView(lines: lines)),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    if (await _submitEdit(dryRun: false) && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Applied changes to ${t.name}')));
      final message = _checkMessage;
      await _load();
      if (mounted) setState(() => (_checkedText = _controller.text, _checkMessage = message));
    }
  }

  Future<void> _create(AppState app, {required bool review, bool serverSide = false}) async {
    if (_controller.text.trim().isEmpty) return;
    var docs = yamlDocumentSummaries(_controller.text);
    if (review) {
      final dry = await _submitCreate(dryRun: true, serverSide: serverSide);
      if (dry == null || !dry.ok || !mounted) return;
      docs = [for (final r in dry.results) (line: r.line, kind: r.kind, name: r.namespace == null ? r.name : '${r.namespace}/${r.name}')];
    }
    final verb = serverSide ? 'Apply' : 'Create';
    final ok = await confirmAction(
      context,
      title: '$verb ${docs.length == 1 ? '${docs.first.kind} ${docs.first.name}'.trim() : _count(docs.length)}?',
      message: [
        if (serverSide) 'Server-side apply creates what is missing and updates what exists (fields other tools own are not taken over).',
        'Objects without a namespace go to $_namespace.${review ? ' Validated by a server-side dry run.' : ''}',
      ].join(' '),
      kubeContext: app.currentContext,
      objectName: docs.firstOrNull?.name ?? '',
      confirmLabel: verb,
      extra: docs.length < 2
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final d in docs.take(12)) Text('${d.kind} ${d.name}', style: monoStyle(context, size: 12)),
                if (docs.length > 12) Text('… and ${docs.length - 12} more', style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
    );
    if (ok != true || !mounted) return;
    final res = await _submitCreate(dryRun: false, serverSide: serverSide);
    if (res != null && res.ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$verb${serverSide ? 'ed' : 'd'} ${_count(res.results.length)} in ${app.currentContext}')));
    }
  }

  /// Opens a created object in the inspector and closes the editor.
  void _openCreated(ManifestItem item) {
    final app = context.read<AppState>();
    final type = app.typeFor(item.group, item.kind);
    if (type == null) return;
    Navigator.of(context).pop();
    app.openDetail(DetailTarget(type: type, name: item.name, namespace: type.namespaced ? item.namespace : null));
  }

  void _jumpTo(int line) {
    final i = (line - 1).clamp(0, _controller.lineCount - 1);
    _controller.selection = CodeLineSelection.collapsed(index: i, offset: 0);
    _controller.makePositionCenterIfInvisible(CodeLinePosition(index: i, offset: 0));
  }

  Future<bool> _confirmDiscard(String title, String label) async {
    return showConfirm(context, title: title, confirmLabel: label, cancelLabel: 'Keep editing');
  }

  Future<void> _close() async {
    if (_dirty && !await _confirmDiscard('Discard unsaved changes?', 'Discard')) return;
    if (mounted) Navigator.of(context).pop();
  }

  void _escape() {
    if (_find.value != null) {
      _find.close();
    } else {
      _close();
    }
  }

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final readOnly = _readOnly(app);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: CallbackShortcuts(
        bindings: {
          primaryShortcut(LogicalKeyboardKey.keyS): _reviewAndApply,
          primaryShortcut(LogicalKeyboardKey.enter): _apply,
          primaryShortcut(LogicalKeyboardKey.numpadEnter): _apply,
          primaryShortcut(LogicalKeyboardKey.keyF): _find.findMode,
          const SingleActivator(LogicalKeyboardKey.escape): _escape,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: theme.colorScheme.surface,
            body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _titleBar(context, app, readOnly),
              const Divider(),
              if (readOnly) _readOnlyBanner(context, app),
              if (_status)
                EditorBanner(severityColor(context, Severity.info), Icons.info_outline,
                    'Only changes under .status are saved (the status subresource). The controller may overwrite them unless it\'s stopped.'),
              if (_editedOutsideStatus)
                EditorBanner(severityColor(context, Severity.warn), Icons.warning_amber_rounded, 'These changes won\'t be saved: you edited outside .status.'),
              if (_deleted)
                EditorBanner(severityColor(context, Severity.error), Icons.delete_outline, 'This object was deleted on the server. Applying will fail.')
              else if (_serverChanged)
                EditorBanner(
                  severityColor(context, Severity.warn),
                  Icons.sync_problem,
                  'This object changed on the server (now rv $_liveRv, you started from $_baseRv). Applying will be rejected.',
                  action: TextButton(onPressed: _busy ? null : _reloadFromServer, child: const Text('Reload (lose edits)')),
                ),
              Expanded(child: _body(context, readOnly)),
              _statusBar(context, readOnly),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _reloadFromServer() async {
    if (_dirty && !await _confirmDiscard('Reload from the server and lose your edits?', 'Reload')) return;
    setState(_clearCheck);
    await _load();
  }

  Widget _titleBar(BuildContext context, AppState app, bool readOnly) {
    final theme = Theme.of(context);
    final t = _t;
    // Leave room for the traffic lights in the unified titlebar.
    final lead = nativeMacChrome && !WindowChromeScope.isFullScreen(context) ? 78.0 : 10.0;
    final canWrite = !_busy && !_loading && (_creating ? _controller.text.trim().isNotEmpty : _dirty);
    return WindowDragArea(
      child: SizedBox(
        height: toolbarRowHeight(context),
        child: Padding(
          padding: EdgeInsets.fromLTRB(lead, 0, 10, 0),
          child: Row(children: [
            IconButton(tooltip: 'Close (Esc)', icon: const Icon(Icons.close, size: 18), onPressed: _close),
            const SizedBox(width: 4),
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: t == null ? 'New Resource' : (_status ? 'Editing status of ${t.type.kind}/' : 'Edit ${t.type.kind} ')),
                  if (t != null) TextSpan(text: t.name, style: monoStyle(context, size: 15).copyWith(fontWeight: FontWeight.w600)),
                  if (_dirty) TextSpan(text: '  •', style: TextStyle(color: theme.hintColor)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge,
              ),
            ),
            const SizedBox(width: 12),
            _ContextChip(context: app.currentContext, readOnly: app.readOnly),
            const SizedBox(width: 6),
            if (_creating) _namespaceChip(context, app) else if (t!.namespace != null) _Chip(icon: Icons.folder_outlined, label: t.namespace!, tooltip: 'Namespace'),
            const Spacer(),
            // Read-only: no write buttons at all; the banner says why.
            if (!readOnly) ...[
              if (_creating && _placeholders > 0) ...[
                Tooltip(
                  message: 'Tab selects the next \${…} placeholder; what you type there fills the others of the same name',
                  child: Text('$_placeholders placeholder${_placeholders == 1 ? '' : 's'} left',
                      style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn))),
                ),
                if (_hasDefaults)
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: _useDefaults,
                    child: const Text('Use defaults'),
                  ),
                const SizedBox(width: 8),
              ],
              OutlinedButton(
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: _busy || _loading || _controller.text.trim().isEmpty ? null : _validate,
                child: const Text('Validate'),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '${_creating ? 'Create' : 'Apply'} (${shortcutLabel('↩')}) · validate & review first: ${shortcutLabel('S')}',
                child: FilledButton(
                  style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: canWrite ? _reviewAndApply : null,
                  child: Text(_busy ? 'Working…' : (_creating ? 'Create…' : 'Review & Apply…')),
                ),
              ),
            ],
            const SizedBox(width: 4),
            IconButton(
              tooltip: _sideOpen ? 'Hide side pane' : 'Show side pane',
              isSelected: _sideOpen,
              icon: const Icon(Icons.vertical_split_outlined, size: 18),
              onPressed: () => setState(() => _sideOpen = !_sideOpen),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _namespaceChip(BuildContext context, AppState app) {
    final options = {...app.namespaces, _namespace}.toList()..sort();
    return Tooltip(
      message: 'Default namespace for objects without one',
      child: MenuSelect<String>(
        value: _namespace,
        options: [for (final ns in options) (ns, Text(ns, style: monoStyle(context, size: 12)))],
        onChanged: _setNamespace,
        hint: Text(_namespace),
      ).wrapChip(context),
    );
  }

  Widget _readOnlyBanner(BuildContext context, AppState app) => EditorBanner(
        severityColor(context, Severity.info),
        Icons.lock_outline,
        app.readOnly
            ? '${app.currentContext} is read-only: ${_creating ? 'creating resources' : 'editing'} is disabled. Unlock the context in the sidebar to make changes.'
            : 'You can\'t update ${_t!.type.kind} objects (the API doesn\'t allow update), so this editor is read-only.',
      );

  Widget _body(BuildContext context, bool readOnly) {
    if (_loadError != null) return Padding(padding: const EdgeInsets.all(16), child: InlineMessage(_loadError!, isError: true));
    if (_loading && _original.isEmpty) return const Center(child: CircularProgressIndicator());
    final stale = _stale;
    final editor = Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      child: YamlCodeEditor(
        controller: _controller,
        scrollController: _scroll,
        findController: _find,
        focusNode: _editorFocus,
        readOnly: readOnly,
        editing: !readOnly,
        autofocus: true,
        placeholders: _creating,
        problemLines: stale ? const {} : {for (final p in _problems) if (p.line != null) p.line! - 1},
      ),
    );
    if (!_sideOpen) return editor;
    return LayoutBuilder(builder: (context, box) {
      final width = _sideWidth.clamp(300.0, (box.maxWidth - 420).clamp(300.0, 1200.0));
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: editor),
        MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => setState(() => _sideWidth = (width - d.delta.dx).clamp(300.0, box.maxWidth - 420)),
            child: SizedBox(width: 7, child: Center(child: VerticalDivider(width: 1, color: Theme.of(context).dividerColor))),
          ),
        ),
        SizedBox(width: width, child: _sidePane(context, readOnly)),
      ]);
    });
  }

  Widget _sidePane(BuildContext context, bool readOnly) {
    final errors = _stale ? 0 : _problems.length;
    final resultLabel = _creating ? 'Results' : 'Validation';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TabBar(
        controller: _tabs,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        onTap: (_) => setState(() {}),
        tabs: [
          Tab(height: 34, text: _creating ? 'Templates' : (_dirty ? 'Diff •' : 'Diff')),
          Tab(
            height: 34,
            child: Row(children: [
              Text(resultLabel),
              if (errors > 0) ...[const SizedBox(width: 6), _CountBadge(errors)] else if (_checkOk == true && !_stale) ...[
                const SizedBox(width: 6),
                Icon(Icons.check_circle, size: 13, color: severityColor(context, Severity.ok)),
              ],
            ]),
          ),
        ],
      ),
      Expanded(
        child: IndexedStack(index: _tabs.index, sizing: StackFit.expand, children: [
          _creating ? _templatesPane(context, readOnly) : _diffPane(context),
          _resultsPane(context),
        ]),
      ),
    ]);
  }

  Widget _diffPane(BuildContext context) {
    final stats = diffStats(_diff);
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          Text('Against the server copy (rv $_baseRv)', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          const Spacer(),
          if (stats.added + stats.removed > 0) ...[
            Text('+${stats.added}', style: monoStyle(context, size: 11, color: severityColor(context, Severity.ok))),
            const SizedBox(width: 6),
            Text('−${stats.removed}', style: monoStyle(context, size: 11, color: severityColor(context, Severity.error))),
          ],
        ]),
      ),
      Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(8, 0, 10, 8), child: DiffView(lines: _diff))),
    ]);
  }

  Widget _templatesPane(BuildContext context, bool readOnly) {
    final theme = Theme.of(context);
    final app = context.read<AppState>();
    final kindType = widget.kind;
    final extra = kindType != null && !resourceTemplates.any((t) => t.group == kindType.group && t.kind == kindType.kind) ? templateFor(kindType) : null;
    Widget row(ResourceTemplate t) => _TemplateRow(
          template: t,
          selected: identical(t, _template) || (t.plugin == null && _template?.plugin == null && t.label == _template?.label && t.kind == _template?.kind),
          available: t.kind.isEmpty || app.types.isEmpty || app.typeFor(t.group, t.kind) != null,
          onTap: () => _pickTemplate(t),
        );
    // The plugins' templates, under each plugin's name and icon: first when
    // they're for the kind being created, else after the built-in ones.
    final plugins = [
      for (final (i, t) in _pluginTemplates.indexed) ...[
        if (i == 0 || _pluginTemplates[i - 1].plugin?.id != t.plugin?.id) _PluginHeader(plugin: t.plugin!),
        row(t),
      ],
    ];
    return ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 12), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
        child: Text('Start from a template. Namespaced templates use $_namespace; paste any manifest, several separated by ---.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      ),
      if (extra != null) row(extra),
      if (kindType != null) ...plugins,
      if (plugins.isNotEmpty) const _PluginHeader(plugin: null),
      for (final t in resourceTemplates) row(t),
      if (kindType == null) ...plugins,
    ]);
  }

  Widget _resultsPane(BuildContext context) {
    final theme = Theme.of(context);
    final stale = _stale;
    final children = <Widget>[];
    if (_checkMessage == null) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
        child: Text('Validate runs a server-side dry run: admission, schema and policy checks, without changing anything.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      ));
      if (_creating) children.add(_outline(context));
    } else {
      final ok = _checkOk == true;
      children.add(EditorBanner(
        severityColor(context, stale ? Severity.neutral : (ok ? Severity.ok : Severity.error)),
        ok ? Icons.check_circle_outline : Icons.error_outline,
        stale ? '$_checkMessage (edited since: validate again)' : _checkMessage!,
        margin: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      ));
      final res = _applyResult;
      if (res != null) {
        for (final r in res.results) {
          children.add(_ResultRow(
            item: r,
            dryRun: res.dryRun,
            serverSide: res.mode == 'apply',
            textFor: _controller.text,
            onJump: _jumpTo,
            onOpen: !res.dryRun && r.ok && res.results.length == 1 && context.read<AppState>().typeFor(r.group, r.kind) != null ? () => _openCreated(r) : null,
          ));
        }
        if (!res.dryRun && res.results.length > 1) {
          final opened = res.results.where((r) => r.ok && context.read<AppState>().typeFor(r.group, r.kind) != null).toList();
          if (opened.length == 1) {
            children.add(Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => _openCreated(opened.first), icon: const Icon(Icons.open_in_new, size: 14), label: Text('Open ${opened.first.kind} ${opened.first.name}'))));
          }
        }
        if (res.mode == 'create' && res.results.any((r) => r.reason == 'AlreadyExists') && !_readOnly(context.read<AppState>())) {
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Row(children: [
              Expanded(
                child: Text('Some objects already exist. Server-side apply updates them instead, and fails on fields another tool owns.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: _busy ? null : () => _create(context.read<AppState>(), review: true, serverSide: true),
                child: const Text('Server-side apply…'),
              ),
            ]),
          ));
        }
      } else {
        for (final p in _problems) {
          children.add(_ProblemRow(problem: p, onJump: _jumpTo));
        }
      }
    }
    return PageScroll(padding: const EdgeInsets.fromLTRB(8, 8, 8, 12), children: children);
  }

  /// The documents in the editor, before anything was validated.
  Widget _outline(BuildContext context) {
    final docs = yamlDocumentSummaries(_controller.text);
    final theme = Theme.of(context);
    if (docs.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
        child: Text(docs.length == 1 ? '1 document' : '${docs.length} documents', style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor)),
      ),
      for (final d in docs)
        Hoverable(
          onTap: () => _jumpTo(d.line),
          builder: (h) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(color: h ? AppColors.of(context).hover : null, borderRadius: BorderRadius.circular(4)),
            child: Row(children: [
              Expanded(child: Text('${d.kind.isEmpty ? '(no kind)' : d.kind} ${d.name}', style: monoStyle(context, size: 12))),
              Text('line ${d.line}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ),
        ),
    ]);
  }

  Widget _statusBar(BuildContext context, bool readOnly) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      child: Row(children: [
        Expanded(
          child: Text(
            readOnly
                ? '${shortcutLabel('F')} find · Esc close'
                : '${shortcutLabel('S')} validate, review & ${_creating ? 'create' : 'apply'} · ${shortcutLabel('↩')} ${_creating ? 'create' : 'apply'} · ${shortcutLabel('F')} find · Esc close',
            style: style,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (!_creating) Text('rv $_liveRv', style: monoStyle(context, size: 11, color: theme.hintColor)),
      ]),
    );
  }
}

extension on Widget {
  /// Frames a [MenuSelect] like the other title-bar chips.
  Widget wrapChip(BuildContext context) => Container(
        decoration: BoxDecoration(color: chipFill(context), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.only(left: 8), child: Icon(Icons.folder_outlined, size: 14, color: Theme.of(context).hintColor)),
          this,
        ]),
      );
}

/// The kube context the editor writes to. Amber for non-local clusters,
/// with a lock when the context is read-only.
class _ContextChip extends StatelessWidget {
  final String context;
  final bool readOnly;
  const _ContextChip({required this.context, required this.readOnly});

  @override
  Widget build(BuildContext ctx) {
    final local = isLocalContext(context);
    final warn = severityColor(ctx, Severity.warn);
    return _Chip(
      icon: readOnly ? Icons.lock_outline : (local ? Icons.computer : Icons.cloud_outlined),
      label: context,
      color: local || readOnly ? null : warn,
      tooltip: readOnly ? 'Read-only context' : (local ? 'Local cluster' : 'Changes go to $context, not a local cluster'),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final String? tooltip;
  const _Chip({required this.icon, required this.label, this.color, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = color ?? theme.colorScheme.onSurface;
    final chip = Container(
      height: 26,
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: color?.withValues(alpha: 0.12) ?? chipFill(context),
        borderRadius: BorderRadius.circular(6),
        border: color == null ? null : Border.all(color: color!.withValues(alpha: 0.5)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color ?? theme.hintColor),
        const SizedBox(width: 6),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12, color: fg).copyWith(fontWeight: FontWeight.w600))),
      ]),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  const _CountBadge(this.count);

  @override
  Widget build(BuildContext context) {
    final c = severityColor(context, Severity.error);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
      child: Text('$count', style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
    );
  }
}

/// The heading of a plugin's templates: its icon.png (or kind icon) and
/// name; with no plugin, of the built-in ones.
class _PluginHeader extends StatelessWidget {
  final TemplatePlugin? plugin;
  const _PluginHeader({required this.plugin});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = plugin;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Row(children: [
        if (p == null)
          Icon(Icons.inventory_2_outlined, size: 14, color: theme.hintColor)
        else
          ListenableBuilder(
            listenable: pluginHost,
            builder: (context, _) {
              final png = p.hasIcon ? pluginHost.iconBytes(p.id) : null;
              return png != null
                  ? Image.memory(png, width: 14, height: 14)
                  : Icon(pluginIcons[p.icon] ?? Icons.extension_outlined, size: 14, color: theme.hintColor);
            },
          ),
        const SizedBox(width: 6),
        Expanded(child: Text(p?.name ?? 'Built in', style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor))),
      ]),
    );
  }
}

class _TemplateRow extends StatelessWidget {
  final ResourceTemplate template;
  final bool selected;

  /// False when the cluster doesn't serve the kind.
  final bool available;
  final VoidCallback onTap;
  const _TemplateRow({required this.template, required this.selected, required this.available, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (h) => Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(color: selected ? colors.selection : (h ? colors.hover : null), borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Icon(template.icon, size: 18, color: selected ? theme.colorScheme.primary : theme.hintColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(template.label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(available ? template.description : '${template.description} · not served by this cluster',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ProblemRow extends StatelessWidget {
  final _Problem problem;
  final ValueChanged<int> onJump;
  const _ProblemRow({required this.problem, required this.onJump});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = problem.line;
    return Hoverable(
      onTap: line == null ? null : () => onJump(line),
      builder: (h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(color: h && line != null ? AppColors.of(context).hover : null, borderRadius: BorderRadius.circular(4)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.error_outline, size: 14, color: severityColor(context, Severity.error))),
          const SizedBox(width: 6),
          Expanded(child: Text(problem.message, style: monoStyle(context, size: 11))),
          if (line != null) ...[const SizedBox(width: 8), Text('line $line', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary))],
        ]),
      ),
    );
  }
}

/// One object's outcome: would be created / created / its error, with the
/// causes linked to lines.
class _ResultRow extends StatelessWidget {
  final ManifestItem item;
  final bool dryRun;
  final bool serverSide;
  final String textFor;
  final ValueChanged<int> onJump;
  final VoidCallback? onOpen;
  const _ResultRow({required this.item, required this.dryRun, required this.serverSide, required this.textFor, required this.onJump, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = item.ok;
    final color = severityColor(context, ok ? Severity.ok : Severity.error);
    final what = item.kind.isEmpty ? 'Document ${item.index + 1}' : '${item.kind} ${item.namespace != null ? '${item.namespace}/' : ''}${item.name}';
    final status = !ok
        ? (item.reason == 'AlreadyExists' ? 'already exists' : (item.reason ?? 'failed'))
        : serverSide
            ? (item.created ? (dryRun ? 'would be created' : 'created') : (dryRun ? 'would be updated' : 'updated'))
            : (dryRun ? 'would be created' : 'created');
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ok ? theme.colorScheme.outlineVariant.withValues(alpha: 0.5) : color.withValues(alpha: 0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(what, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600))),
          Text(status, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => onJump(item.line),
            child: Text('line ${item.line}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
          ),
        ]),
        if (!ok && item.causes.isEmpty) Padding(padding: const EdgeInsets.only(top: 4, left: 23), child: SelectableText(item.error!, style: theme.textTheme.bodySmall)),
        for (final c in item.causes)
          _ProblemRow(
            problem: (
              line: lineForFieldPath(textFor, '${c['field'] ?? ''}', docStart: item.line),
              message: [if ('${c['field'] ?? ''}'.isNotEmpty) '${c['field']}', '${c['message'] ?? ''}'].join(': '),
            ),
            onJump: onJump,
          ),
        if (onOpen != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 6, left: 15),
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new, size: 14),
                label: Text('Open ${item.name}'),
              ),
            ),
          ),
      ]),
    );
  }
}

/// The top-level `status:` block of [yaml] (empty when there is none).
String _statusPart(String yaml) => _splitStatus(yaml).inStatus.join('\n');

/// [yaml] without its top-level `status:` block.
String _withoutStatus(String yaml) => _splitStatus(yaml).rest.join('\n');

({List<String> inStatus, List<String> rest}) _splitStatus(String yaml) {
  final inStatus = <String>[], rest = <String>[];
  var inside = false;
  for (final line in yaml.split('\n')) {
    if (line.startsWith('status:')) {
      inside = true;
    } else if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('-') && !line.startsWith('#')) {
      inside = false;
    }
    (inside ? inStatus : rest).add(line);
  }
  return (inStatus: inStatus, rest: rest);
}
