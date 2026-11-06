import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'resource_table.dart' show TableCellView;
import 'theme.dart';
import 'widgets/common.dart';

/// Opens the column editor. Resolves true if columns were saved or reset.
///
/// By default it edits the kind's column configuration. An open saved view
/// passes its own [columns] and an [onSave] that receives the edited list
/// (null for Reset: the kind's columns) instead.
Future<bool?> showColumnEditor(BuildContext context,
        {required ResourceType type, String? namespace, List<ColumnDef>? columns, Future<void> Function(List<ColumnDef>? columns)? onSave}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => Provider.value(
        value: context.read<ApiClient>(),
        child: ColumnEditorDialog(type: type, namespace: namespace, initial: columns, onSave: onSave),
      ),
    );

const _types = ['string', 'number', 'quantity', 'percent', 'age', 'status', 'bool', 'labels'];

class _EditableColumn {
  final TextEditingController name;
  final TextEditingController query;
  String type;
  final Key key = UniqueKey();
  _EditableColumn(ColumnDef c)
      : name = TextEditingController(text: c.name),
        query = TextEditingController(text: c.query),
        type = c.type;
  ColumnDef toDef() => ColumnDef(name: name.text.trim(), query: query.text.trim(), type: type);
  void dispose() {
    name.dispose();
    query.dispose();
  }
}

class ColumnEditorDialog extends StatefulWidget {
  final ResourceType type;
  final String? namespace;

  /// Columns to start from instead of the kind's (a saved view's).
  final List<ColumnDef>? initial;

  /// Saves somewhere other than the kind's configuration (a saved view).
  final Future<void> Function(List<ColumnDef>? columns)? onSave;
  const ColumnEditorDialog({super.key, required this.type, this.namespace, this.initial, this.onSave});

  @override
  State<ColumnEditorDialog> createState() => _ColumnEditorDialogState();
}

class _ColumnEditorDialogState extends State<ColumnEditorDialog> {
  List<_EditableColumn> _cols = [];
  List<ColumnDef> _defaults = [];
  bool _loading = true;
  String? _error;
  TableData? _preview;
  String? _previewError;
  Timer? _debounce;
  Json? _sample;
  bool _saving = false;

  ApiClient get _api => context.read<ApiClient>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cfg = await _api.getColumns(widget.type.ref);
      final ns = widget.type.namespaced ? widget.namespace : null;
      final items = await _api.items(widget.type.ref, namespace: ns).catchError((_) => <Json>[]);
      setState(() {
        _defaults = cfg.defaults;
        _cols = [for (final c in widget.initial ?? cfg.columns) _EditableColumn(c)];
        _sample = items.isNotEmpty ? items.first : null;
        _loading = false;
      });
      _schedulePreview();
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in _cols) {
      c.dispose();
    }
    super.dispose();
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _runPreview);
  }

  Future<void> _runPreview() async {
    final defs = _cols.map((c) => c.toDef()).toList();
    try {
      final t = await _api.previewColumns(widget.type.ref, defs, namespace: widget.type.namespaced ? widget.namespace : null, limit: 15);
      if (mounted) setState(() => (_preview = t, _previewError = null));
    } catch (e) {
      if (mounted) setState(() => _previewError = '$e');
    }
  }

  void _add(ColumnDef c) {
    setState(() => _cols.add(_EditableColumn(c)));
    _schedulePreview();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final defs = [for (final c in _cols) c.toDef()];
      final onSave = widget.onSave;
      await (onSave != null ? onSave(defs) : _api.putColumns(widget.type.ref, defs));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _saving = false;
        _previewError = '$e';
      });
    }
  }

  Future<void> _reset() async {
    final onSave = widget.onSave;
    await (onSave != null ? onSave(null) : _api.resetColumns(widget.type.ref));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 1100,
        height: 720,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Padding(padding: const EdgeInsets.all(24), child: InlineMessage(_error!, isError: true))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
                      child: Row(children: [
                        Text('Columns · ${widget.type.kind}', style: theme.textTheme.titleMedium),
                        const SizedBox(width: 12),
                        Text('jq expressions evaluated against each object', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                        const Spacer(),
                        IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => Navigator.of(context).pop(false)),
                      ]),
                    ),
                    const Divider(),
                    Expanded(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(flex: 3, child: _columnList(context)),
                        const VerticalDivider(width: 1),
                        SizedBox(width: 340, child: _FieldPicker(sample: _sample, onPick: (path) => _add(ColumnDef(name: _nameFor(path), query: path)))),
                      ]),
                    ),
                    const Divider(),
                    SizedBox(height: 210, child: _previewTable(context)),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 16, 12),
                      child: Row(children: [
                        TextButton.icon(onPressed: _reset, icon: const Icon(Icons.restart_alt, size: 15), label: const Text('Reset to defaults')),
                        const SizedBox(width: 8),
                        MenuButton<ColumnDef>(
                          tooltip: 'Add a default column',
                          onSelected: _add,
                          items: () => [for (final d in _defaults) PopupMenuItem(value: d, height: 28, child: Text(d.name))],
                          builder: (h) => Container(
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(color: h ? AppColors.of(context).hover : null, borderRadius: BorderRadius.circular(6)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text('Add default column', style: theme.textTheme.labelLarge),
                              const SizedBox(width: 4),
                              Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
                            ]),
                          ),
                        ),
                        const Spacer(),
                        OutlinedButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
                      ]),
                    ),
                  ]),
      ),
    );
  }

  Widget _columnList(BuildContext context) {
    final theme = Theme.of(context);
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          const SizedBox(width: 24),
          SizedBox(width: 150, child: Text('Name', style: head)),
          const SizedBox(width: 8),
          Expanded(child: Text('jq query', style: head)),
          const SizedBox(width: 8),
          SizedBox(width: 120, child: Text('Type', style: head)),
          const SizedBox(width: 30),
        ]),
      ),
      Expanded(
        child: ReorderableListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          buildDefaultDragHandles: false,
          itemCount: _cols.length,
          onReorderItem: (a, b) {
            setState(() => _cols.insert(b, _cols.removeAt(a)));
            _schedulePreview();
          },
          itemBuilder: (context, i) {
            final c = _cols[i];
            final err = _preview?.columnErrors[i];
            return Padding(
              key: c.key,
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ReorderableDragStartListener(
                  index: i,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: SizedBox(width: 24, height: 28, child: Icon(Icons.drag_indicator, size: 16, color: AppColors.of(context).faint)),
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: c.name,
                    style: theme.textTheme.bodyMedium,
                    decoration: const InputDecoration(hintText: 'Name'),
                    onChanged: (_) => _schedulePreview(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: c.query,
                    minLines: 1,
                    maxLines: 4,
                    style: monoStyle(context, size: 12),
                    decoration: InputDecoration(hintText: '.path.to.field', errorText: err, errorMaxLines: 3),
                    onChanged: (_) => _schedulePreview(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: Container(
                    height: 30,
                    decoration: BoxDecoration(
                      color: theme.inputDecorationTheme.fillColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.centerLeft,
                    child: MenuSelect<String>(
                      value: _types.contains(c.type) ? c.type : 'string',
                      options: [for (final t in _types) (t, Text(t, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium))],
                      onChanged: (v) => setState(() => c.type = v),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.remove_circle_outline, size: 15),
                  onPressed: () {
                    setState(() => _cols.removeAt(i).dispose());
                    _schedulePreview();
                  },
                ),
              ]),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add column'),
            onPressed: () => _add(const ColumnDef(name: 'New', query: '.metadata.name')),
          ),
        ),
      ),
    ]);
  }

  Widget _previewTable(BuildContext context) {
    final theme = Theme.of(context);
    if (_previewError != null) return Padding(padding: const EdgeInsets.all(12), child: InlineMessage(_previewError!, isError: true));
    final p = _preview;
    if (p == null) return const Center(child: CircularProgressIndicator());
    if (p.rows.isEmpty) return Center(child: Text('No objects to preview', style: TextStyle(color: theme.hintColor)));
    final defs = [for (final c in _cols) c.toDef()];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 28,
          dataRowMinHeight: 24,
          dataRowMaxHeight: 28,
          columnSpacing: 18,
          columns: [for (final c in p.columns) DataColumn(label: Text(c.name, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor)))],
          rows: [
            for (final r in p.rows)
              DataRow(cells: [
                for (var i = 0; i < p.columns.length; i++)
                  DataCell(ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: _PreviewCell(value: i < r.cells.length ? r.cells[i] : null, def: i < defs.length ? defs[i] : p.columns[i]),
                  )),
              ]),
          ],
        ),
      ),
    );
  }

  static String _nameFor(String path) {
    final seg = RegExp(r'[A-Za-z0-9_\-]+').allMatches(path).map((m) => m.group(0)!).toList();
    if (seg.isEmpty) return 'Field';
    final s = seg.last;
    return s[0].toUpperCase() + s.substring(1);
  }
}

class _PreviewCell extends StatelessWidget {
  final dynamic value;
  final ColumnDef def;
  const _PreviewCell({required this.value, required this.def});

  @override
  Widget build(BuildContext context) {
    return TableCellView(value: value, column: def);
  }
}

/// Lists leaf paths of a sample object; clicking one adds it as a column.
class _FieldPicker extends StatefulWidget {
  final Json? sample;
  final void Function(String path) onPick;
  const _FieldPicker({required this.sample, required this.onPick});

  @override
  State<_FieldPicker> createState() => _FieldPickerState();
}

class _FieldPickerState extends State<_FieldPicker> {
  String _q = '';
  late final List<(String, String)> _paths = widget.sample == null ? const [] : _flatten(widget.sample!, '');

  static final _ident = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  static List<(String, String)> _flatten(dynamic v, String prefix) {
    final out = <(String, String)>[];
    if (v is Map) {
      for (final e in v.entries) {
        if (prefix.isEmpty && e.key == 'metadata' && e.value is Map) {
          // managedFields is noise for column building.
          final m = Map<String, dynamic>.from(e.value)..remove('managedFields');
          out.addAll(_flatten(m, '.metadata'));
          continue;
        }
        final k = '${e.key}';
        final seg = _ident.hasMatch(k) ? '.$k' : '["$k"]';
        out.addAll(_flatten(e.value, '$prefix$seg'));
      }
    } else if (v is List) {
      if (v.isEmpty) {
        out.add((prefix, '[]'));
      } else {
        // Offer both the "all items" form and leaves of the first item.
        out.addAll(_flatten(v.first, '$prefix[]'));
      }
    } else {
      out.add((prefix.isEmpty ? '.' : prefix, '$v'));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _q.toLowerCase();
    final visible = _paths.where((p) => q.isEmpty || p.$1.toLowerCase().contains(q)).take(400).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Text('Fields from a sample object', style: theme.textTheme.titleSmall),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 16), hintText: 'e.g. image, replicas'),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      Expanded(
        child: widget.sample == null
            ? Center(child: Text('No objects in scope', style: TextStyle(color: theme.hintColor)))
            : ListView.builder(
                itemCount: visible.length,
                itemBuilder: (context, i) {
                  final (path, val) = visible[i];
                  return InkWell(
                    onTap: () => widget.onPick(path.contains('[]') ? '[$path | tostring] | join(", ")' : path),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(path, style: monoStyle(context, size: 11, color: theme.colorScheme.primary)),
                        Text(val, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}
