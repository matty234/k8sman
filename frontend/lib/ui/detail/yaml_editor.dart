import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../state/app_state.dart';
import '../../util/diff.dart';
import '../../util/k8s.dart';
import '../editor/resource_editor_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../keys.dart';

/// YAML tab: syntax-highlighted view, and (unless read-only) an inline editor
/// with server-side dry-run validation, diff review and conflict-safe apply.
class YamlEditorTab extends StatefulWidget {
  final DetailTarget target;

  /// Live resourceVersion from the sidebar's watch — used to refresh the
  /// view and to detect concurrent changes while editing.
  final String resourceVersion;
  /// Bumped to ask for edit mode (and focus in the editor) if allowed.
  final int editRequest;
  const YamlEditorTab({super.key, required this.target, required this.resourceVersion, this.editRequest = 0});

  @override
  State<YamlEditorTab> createState() => _YamlEditorTabState();
}

class _YamlEditorTabState extends State<YamlEditorTab> {
  final _controller = CodeLineEditingController();
  final _scroll = CodeScrollController();

  String _original = '';
  String _baseRv = '';
  bool _loading = true;
  String? _loadError;

  bool _editing = false;
  bool _managedFields = false;
  bool _busy = false;
  bool _showDiff = false;
  bool _serverChanged = false;

  /// Result of the last validate/apply attempt.
  ({bool ok, String message, List<Map<String, dynamic>> causes})? _result;

  ApiClient get _api => context.read<ApiClient>();
  DetailTarget get _t => widget.target;

  final _editorFocus = FocusNode();

  bool get _canEdit => !context.read<AppState>().readOnly && _t.type.can('update');

  @override
  void initState() {
    super.initState();
    if (widget.editRequest > 0 && _canEdit) _editing = true;
    _load().then((_) => _editing && widget.editRequest > 0 && mounted ? _editorFocus.requestFocus() : null);
    _controller.addListener(_onEdit);
  }

  @override
  void dispose() {
    _controller.removeListener(_onEdit);
    _controller.dispose();
    _scroll.dispose();
    _editorFocus.dispose();
    // re_editor's CodeScrollController.dispose() leaves the two
    // ScrollControllers it created undisposed.
    _scroll.verticalScroller.dispose();
    _scroll.horizontalScroller.dispose();
    super.dispose();
  }

  bool get _dirty => _editing && _controller.text != _original;

  bool _wasDirty = false;

  /// Rebuild only when the dirty state flips (enables Apply) or a stale
  /// validation result should be cleared — not on every keystroke.
  void _onEdit() {
    if (!_editing) return;
    final dirty = _dirty;
    if (dirty != _wasDirty || _result != null) {
      _wasDirty = dirty;
      setState(() => _result = null);
    }
  }

  Future<void> _load() async {
    setState(() => (_loading = true, _loadError = null));
    try {
      final y = await _api.objectYaml(_t.type.ref, namespace: _t.namespace, name: _t.name, managedFields: _managedFields && !_editing);
      if (!mounted) return;
      setState(() {
        _original = y;
        _baseRv = RegExp(r'^\s*resourceVersion:\s*"?(\d+)"?', multiLine: true).firstMatch(y)?.group(1) ?? widget.resourceVersion;
        _controller.text = y;
        _loading = false;
        _serverChanged = false;
      });
    } catch (e) {
      if (mounted) setState(() => (_loading = false, _loadError = '$e'));
    }
  }

  @override
  void didUpdateWidget(covariant YamlEditorTab old) {
    super.didUpdateWidget(old);
    if (widget.editRequest != old.editRequest && !_editing && _canEdit) {
      _startEditing().then((_) => mounted ? _editorFocus.requestFocus() : null);
      return;
    }
    if (old.resourceVersion == widget.resourceVersion || widget.resourceVersion.isEmpty) return;
    if (_editing) {
      if (widget.resourceVersion != _baseRv) setState(() => _serverChanged = true);
    } else {
      _load(); // keep the read-only view live
    }
  }

  Future<void> _startEditing() async {
    setState(() {
      _editing = true;
      _managedFields = false;
      _result = null;
      _showDiff = false;
    });
    await _load(); // fresh base without managedFields
  }

  Future<void> _discard() async {
    if (_dirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Discard changes?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      _editing = false;
      _result = null;
      _showDiff = false;
    });
    await _load();
  }

  Future<bool> _submit({required bool dryRun}) async {
    setState(() => _busy = true);
    try {
      final res = await _api.updateObject(_t.type.ref, namespace: _t.namespace, name: _t.name, yaml: _controller.text, dryRun: dryRun);
      if (!mounted) return false;
      setState(() {
        _busy = false;
        _result = (ok: true, message: dryRun ? 'Valid: the API server accepted a dry run of this change.' : 'Applied · resourceVersion ${res.resourceVersion}', causes: const []);
      });
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      setState(() {
        _busy = false;
        if (e.isConflict) _serverChanged = true;
        _result = (ok: false, message: e.isConflict ? 'Conflict: the object changed on the server since you started editing.' : e.message, causes: e.causes);
      });
    } catch (e) {
      if (mounted) setState(() => (_busy = false, _result = (ok: false, message: '$e', causes: const <Map<String, dynamic>>[])));
    }
    return false;
  }

  Future<void> _reviewAndApply() async {
    if (!_dirty || _busy) return;
    // Validate first so the user never confirms a change the server rejects.
    if (!await _submit(dryRun: true) || !mounted) return;
    final app = context.read<AppState>();
    final lines = diffLines(_original, _controller.text);
    final stats = diffStats(lines);
    final ok = await confirmAction(
      context,
      title: 'Apply changes to ${_t.type.kind} ${_t.name}?',
      message: '+${stats.added} −${stats.removed} lines. Validated by a server-side dry run.',
      kubeContext: app.currentContext,
      objectName: _t.name,
      destructive: true,
      confirmLabel: 'Apply',
      width: 720,
      extra: Padding(padding: const EdgeInsets.only(bottom: 12), child: SizedBox(height: 360, child: DiffView(lines: lines))),
    );
    if (ok != true || !mounted) return;
    if (await _submit(dryRun: false) && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Applied changes to ${_t.name}')));
      setState(() => _editing = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    if (_loading && _original.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) return Padding(padding: const EdgeInsets.all(12), child: InlineMessage(_loadError!, isError: true));

    final canEdit = !app.readOnly && _t.type.can('update');
    return CallbackShortcuts(
      bindings: {
        primaryShortcut(LogicalKeyboardKey.keyS): _reviewAndApply,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_editing && !_dirty) _discard();
        },
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _toolbar(context, canEdit),
        if (_serverChanged) _serverChangedBanner(context),
        if (_result != null) _resultBanner(context),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: _editing && _showDiff ? DiffView(lines: diffLines(_original, _controller.text)) : _editor(context),
          ),
        ),
        if (_editing)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text('${shortcutLabel('S')} review & apply · ${shortcutLabel('F')} find · Status changes are ignored for kinds with a status subresource.',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
          ),
      ]),
    );
  }

  Widget _toolbar(BuildContext context, bool canEdit) {
    final theme = Theme.of(context);
    final small = OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 2),
      child: Row(children: [
        if (!_editing) ...[
          Text('rv ${widget.resourceVersion}', style: monoStyle(context, size: 11, color: theme.hintColor)),
          const Spacer(),
          Text('managedFields', style: theme.textTheme.bodySmall),
          Switch(
            value: _managedFields,
            onChanged: (v) {
              setState(() => _managedFields = v);
              _load();
            },
          ),
          IconButton(tooltip: 'Copy YAML', icon: const Icon(Icons.copy, size: 16), onPressed: () => copyToClipboard(context, _original, label: 'YAML')),
          IconButton(tooltip: 'Open in Editor', icon: const Icon(Icons.open_in_full, size: 16), onPressed: () => openResourceEditor(context, _t)),
          if (canEdit) FilledButton.tonalIcon(style: FilledButton.styleFrom(visualDensity: VisualDensity.compact), onPressed: _startEditing, icon: const Icon(Icons.edit, size: 16), label: const Text('Edit')),
        ] else ...[
          SegmentedButton<bool>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: false, label: Text('Editor')),
              ButtonSegment(value: true, label: Text(_dirty ? 'Diff •' : 'Diff')),
            ],
            selected: {_showDiff},
            onSelectionChanged: (s) => setState(() => _showDiff = s.first),
          ),
          const Spacer(),
          TextButton(onPressed: _busy ? null : _discard, child: const Text('Cancel')),
          const SizedBox(width: 4),
          OutlinedButton(style: small, onPressed: _busy || !_dirty ? null : () => _submit(dryRun: true), child: const Text('Validate')),
          const SizedBox(width: 6),
          FilledButton(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _busy || !_dirty ? null : _reviewAndApply,
            child: Text(_busy ? 'Working…' : 'Review & apply'),
          ),
        ],
      ]),
    );
  }

  Widget _serverChangedBanner(BuildContext context) => _Banner(
        severityColor(context, Severity.warn),
        Icons.sync_problem,
        'This object changed on the server (now rv ${widget.resourceVersion}, you started from $_baseRv). Applying will be rejected.',
        action: TextButton(onPressed: _busy ? null : () => _discardAndReload(), child: const Text('Reload (lose edits)')),
      );

  Future<void> _discardAndReload() async {
    setState(() => (_result = null, _showDiff = false));
    await _load();
  }

  Widget _resultBanner(BuildContext context) {
    final r = _result!;
    final c = severityColor(context, r.ok ? Severity.ok : Severity.error);
    return _Banner(
      c,
      r.ok ? Icons.check_circle_outline : Icons.error_outline,
      r.message,
      details: [for (final cause in r.causes) '${cause['field'] ?? ''}: ${cause['message'] ?? ''}'],
      onClose: () => setState(() => _result = null),
    );
  }

  Widget _editor(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return CodeEditor(
      controller: _controller,
      scrollController: _scroll,
      focusNode: _editorFocus,
      readOnly: !_editing,
      wordWrap: false,
      style: CodeEditorStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: 12,
        fontHeight: 1.45,
        backgroundColor: theme.colorScheme.surfaceContainerLowest,
        selectionColor: theme.colorScheme.primary.withValues(alpha: 0.3),
        cursorColor: theme.colorScheme.primary,
        cursorLineColor: _editing ? theme.colorScheme.onSurface.withValues(alpha: 0.04) : Colors.transparent,
        codeTheme: CodeHighlightTheme(languages: {'yaml': CodeHighlightThemeMode(mode: langYaml)}, theme: dark ? atomOneDarkTheme : atomOneLightTheme),
      ),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: _editing ? theme.colorScheme.primary.withValues(alpha: 0.6) : theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      indicatorBuilder: (context, editingController, chunkController, notifier) => Row(children: [
        DefaultCodeLineNumber(controller: editingController, notifier: notifier, textStyle: monoStyle(context, size: 11, color: theme.hintColor)),
        DefaultCodeChunkIndicator(width: 16, controller: chunkController, notifier: notifier),
      ]),
      findBuilder: (context, controller, readOnly) => _FindBar(controller: controller),
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String message;
  final List<String> details;
  final Widget? action;
  final VoidCallback? onClose;
  const _Banner(this.color, this.icon, this.message, {this.details = const [], this.action, this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: color)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(message, style: theme.textTheme.bodySmall),
            for (final d in details) Padding(padding: const EdgeInsets.only(top: 2), child: SelectableText('• $d', style: monoStyle(context, size: 11))),
          ]),
        ),
        ?action,
        if (onClose != null) IconButton(visualDensity: VisualDensity.compact, iconSize: 14, icon: const Icon(Icons.close), onPressed: onClose),
      ]),
    );
  }
}

/// Minimal ⌘F find bar for the editor.
class _FindBar extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  const _FindBar({required this.controller});

  @override
  Size get preferredSize => Size.fromHeight(controller.value == null ? 0 : 40);

  @override
  Widget build(BuildContext context) {
    if (controller.value == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final result = controller.value?.result;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: controller.findInputController,
            focusNode: controller.findInputFocusNode,
            style: monoStyle(context),
            decoration: const InputDecoration(hintText: 'Find', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
          ),
        ),
        const SizedBox(width: 8),
        Text(result == null || result.matches.isEmpty ? 'No results' : '${result.index + 1}/${result.matches.length}', style: theme.textTheme.bodySmall),
        IconButton(visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.keyboard_arrow_up), onPressed: controller.previousMatch),
        IconButton(visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.keyboard_arrow_down), onPressed: controller.nextMatch),
        IconButton(visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.close), onPressed: controller.close),
      ]),
    );
  }
}

/// Unified diff with collapsed unchanged runs.
class DiffView extends StatelessWidget {
  final List<DiffLine> lines;

  /// Size to the content (up to [maxHeight], then scroll) instead of filling
  /// the parent, for diffs shown inline in a scrolling panel.
  final bool shrinkWrap;
  final double maxHeight;
  const DiffView({super.key, required this.lines, this.shrinkWrap = false, this.maxHeight = 480});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = withContext(lines);
    if (!lines.any((l) => l.op != DiffOp.same)) {
      return Center(child: Text('No changes', style: TextStyle(color: theme.hintColor)));
    }
    final add = severityColor(context, Severity.ok), del = severityColor(context, Severity.error);
    final box = Container(
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(6), border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
      child: ListView.builder(
        shrinkWrap: shrinkWrap,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final it = items[i];
          if (it.line == null) {
            return Container(
              color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Text('⋯ ${it.skipped} unchanged line${it.skipped == 1 ? '' : 's'}', style: monoStyle(context, size: 11, color: theme.hintColor)),
            );
          }
          final l = it.line!;
          final c = l.op == DiffOp.add ? add : l.op == DiffOp.remove ? del : null;
          return Container(
            color: c?.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 34, child: Text('${l.oldNo ?? ''}', textAlign: TextAlign.right, style: monoStyle(context, size: 11, color: theme.hintColor))),
              SizedBox(width: 34, child: Text('${l.newNo ?? ''}', textAlign: TextAlign.right, style: monoStyle(context, size: 11, color: theme.hintColor))),
              SizedBox(width: 18, child: Text(l.op == DiffOp.add ? '+' : l.op == DiffOp.remove ? '−' : '', textAlign: TextAlign.center, style: monoStyle(context, color: c))),
              Expanded(child: Text(l.text, style: monoStyle(context, color: c))),
            ]),
          );
        },
      ),
    );
    return shrinkWrap ? ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight), child: box) : box;
  }
}
