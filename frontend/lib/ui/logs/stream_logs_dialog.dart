import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/log_dock.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/namespace_picker.dart';

/// Most pods the backend streams at once (see `aggMaxPods`).
const int kStreamMaxPods = 50;

/// One "Stream logs…" query: which pods and containers, where, and how much
/// history.
class StreamQuery {
  final String podRegex;
  final String containerRegex;
  final String selector;
  final NamespaceScope scope;
  final bool allContainers;
  final LogRange range;
  const StreamQuery({
    this.podRegex = '',
    this.containerRegex = '',
    this.selector = '',
    this.scope = NamespaceScope.all,
    this.allContainers = false,
    this.range = (tail: 200, since: null),
  });

  /// The tab title: `~web-.*` for a name regex, else the selector.
  String get title => podRegex.isNotEmpty ? '~$podRegex' : selector;

  bool get isEmpty => podRegex.isEmpty && selector.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is StreamQuery &&
      other.podRegex == podRegex &&
      other.containerRegex == containerRegex &&
      other.selector == selector &&
      other.allContainers == allContainers &&
      other.range == range &&
      other.scope.namespaces.join(',') == scope.namespaces.join(',');

  @override
  int get hashCode => Object.hash(podRegex, containerRegex, selector, allContainers, range, scope.namespaces.join(','));
}

/// The last queries opened this session, newest first.
final List<StreamQuery> recentStreamQueries = [];
const _kRecent = 5;

/// A Go (RE2) pattern as a Dart [RegExp] for the preview: a leading `(?i)`
/// becomes case-insensitive. Null (with [error]) when it doesn't compile.
RegExp? compileStreamRegex(String pattern, {void Function(String)? error}) {
  if (pattern.isEmpty) return null;
  var p = pattern;
  var ci = false;
  if (p.startsWith('(?i)')) {
    p = p.substring(4);
    ci = true;
  }
  try {
    return RegExp(p, caseSensitive: !ci);
  } on FormatException catch (e) {
    error?.call(e.message);
    return null;
  }
}

/// A pod of the preview: where it lives and which containers match.
typedef PreviewPod = ({String ns, String name, List<String> containers});

/// The pods of [items] whose name matches [podRe] (and that have a container
/// matching [containerRe], when given). Pure, so it can run on every keystroke.
List<PreviewPod> previewMatches(List<Json> items, RegExp? podRe, RegExp? containerRe) {
  final out = <PreviewPod>[];
  for (final p in items) {
    final name = dig<String>(p, ['metadata', 'name']) ?? '';
    if (podRe != null && !podRe.hasMatch(name)) continue;
    final cs = [
      for (final c in asMapList(dig(p, ['spec', 'containers']))) '${c['name']}',
    ];
    final matched = containerRe == null ? cs : cs.where(containerRe.hasMatch).toList();
    if (containerRe != null && matched.isEmpty) continue;
    out.add((ns: dig<String>(p, ['metadata', 'namespace']) ?? '', name: name, containers: matched));
  }
  out.sort((a, b) => '${a.ns}/${a.name}'.compareTo('${b.ns}/${b.name}'));
  return out;
}

/// Opens the "Stream logs…" dialog (stern-style: pods by name regex and/or
/// label selector across namespaces, merged into one tab).
Future<void> showStreamLogsDialog(BuildContext context, {StreamQuery? initial}) => showDialog<void>(
  context: context,
  builder: (_) => StreamLogsDialog(api: context.read<ApiClient>(), app: context.read<AppState>(), dock: context.read<LogDock>(), initial: initial),
);

class StreamLogsDialog extends StatefulWidget {
  final ApiClient api;
  final AppState app;
  final LogDock dock;
  final StreamQuery? initial;
  const StreamLogsDialog({super.key, required this.api, required this.app, required this.dock, this.initial});

  @override
  State<StreamLogsDialog> createState() => _StreamLogsDialogState();
}

const _kTails = [100, 200, 500, 1000, -1];
const _kSince = [('5 minutes', 300), ('1 hour', 3600), ('6 hours', 21600), ('24 hours', 86400)];

class _StreamLogsDialogState extends State<StreamLogsDialog> {
  late final _pod = TextEditingController(text: widget.initial?.podRegex ?? '');
  late final _container = TextEditingController(text: widget.initial?.containerRegex ?? '');
  late final _selector = TextEditingController(text: widget.initial?.selector ?? '');
  late NamespaceScope _scope = widget.initial?.scope ?? widget.app.namespaceScope;
  late bool _allContainers = widget.initial?.allContainers ?? false;
  late LogRange _range = widget.initial?.range ?? (tail: 200, since: null);

  Timer? _debounce;
  List<Json> _items = const [];
  bool _loading = false;
  String? _loadError;
  // What _items was listed for: only a change here needs the backend again.
  String? _fetched;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pod.dispose();
    _container.dispose();
    _selector.dispose();
    super.dispose();
  }

  String get _key => '${_scope.namespaces.join(',')}|${_selector.text.trim()}';

  void _changed() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _key != _fetched) _fetch();
    });
  }

  Future<void> _fetch() async {
    final gen = ++_gen;
    _fetched = _key;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final sel = _selector.text.trim();
      final items = await widget.api.items(
        const ResourceRef(resource: 'pods'),
        scope: _scope,
        labelSelector: sel.isEmpty ? null : sel,
      );
      if (!mounted || gen != _gen) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _items = const [];
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  StreamQuery get _query => StreamQuery(
    podRegex: _pod.text.trim(),
    containerRegex: _container.text.trim(),
    selector: _selector.text.trim(),
    scope: _scope,
    allContainers: _allContainers,
    range: _range,
  );

  void _open() {
    final q = _query;
    recentStreamQueries
      ..remove(q)
      ..insert(0, q);
    if (recentStreamQueries.length > _kRecent) recentStreamQueries.removeLast();
    widget.dock.openAggregate(
      '',
      scope: q.scope,
      selectors: [if (q.selector.isNotEmpty) q.selector],
      podRegex: q.podRegex.isEmpty ? null : q.podRegex,
      containerRegex: q.containerRegex.isEmpty ? null : q.containerRegex,
      title: q.title,
      allContainers: q.allContainers,
      tail: q.range.tail,
      since: q.range.since,
    );
    Navigator.of(context).pop();
  }

  void _load(StreamQuery q) {
    _pod.text = q.podRegex;
    _container.text = q.containerRegex;
    _selector.text = q.selector;
    _scope = q.scope;
    _allContainers = q.allContainers;
    _range = q.range;
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    String? podErr, containerErr;
    final podRe = compileStreamRegex(_pod.text.trim(), error: (e) => podErr = e);
    final containerRe = compileStreamRegex(_container.text.trim(), error: (e) => containerErr = e);
    final matches = podErr != null || containerErr != null ? const <PreviewPod>[] : previewMatches(_items, podRe, containerRe);
    final canOpen = podErr == null && containerErr == null && !_query.isEmpty;
    final multiNs = _scope.single == null;
    final sinceLabel = _range.since == null ? null : _kSince.where((e) => e.$2 == _range.since).map((e) => e.$1).firstOrNull;

    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(t, style: theme.textTheme.labelMedium),
    );
    return AlertDialog(
      title: const Text('Stream logs'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (recentStreamQueries.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Recent', style: hint),
                    for (final q in recentStreamQueries)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(q.title, style: monoStyle(context, size: 11.5)),
                        onPressed: () => _load(q),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              label('Pod name regex'),
              TextField(
                key: const ValueKey('stream-pod-regex'),
                controller: _pod,
                autofocus: true,
                style: monoStyle(context),
                decoration: InputDecoration(isDense: true, hintText: 'web-.*', errorText: podErr, errorMaxLines: 2),
                onChanged: (_) => _changed(),
                onSubmitted: (_) => canOpen ? _open() : null,
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        label('Container regex (optional)'),
                        TextField(
                          key: const ValueKey('stream-container-regex'),
                          controller: _container,
                          style: monoStyle(context),
                          decoration: InputDecoration(isDense: true, hintText: 'any', errorText: containerErr, errorMaxLines: 2),
                          onChanged: (_) => _changed(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        label('Label selector (optional)'),
                        TextField(
                          key: const ValueKey('stream-selector'),
                          controller: _selector,
                          style: monoStyle(context),
                          decoration: const InputDecoration(isDense: true, hintText: 'app=web'),
                          onChanged: (_) => _changed(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text('Namespaces', style: theme.textTheme.labelMedium),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 200,
                    child: NamespacePicker.scope(
                      key: const ValueKey('stream-scope'),
                      height: 28,
                      value: _scope,
                      onChanged: (s) {
                        _scope = s;
                        _changed();
                      },
                    ),
                  ),
                  const Spacer(),
                  MenuSelect<LogRange>(
                    value: _range,
                    tooltip: 'History to load, per container',
                    hint: Text(sinceLabel == null ? 'last ${_range.tail} each' : 'since $sinceLabel', style: theme.textTheme.bodySmall),
                    options: [
                      for (final n in _kTails) ((tail: n, since: null), Text(n < 0 ? 'all lines' : 'last $n each', style: theme.textTheme.bodySmall)),
                      for (final (l, secs) in _kSince) ((tail: -1, since: secs), Text('since $l', style: theme.textTheme.bodySmall)),
                    ],
                    onChanged: (v) => setState(() => _range = v),
                  ),
                ],
              ),
              CheckboxListTile(
                key: const ValueKey('stream-all-containers'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('All containers of each pod'),
                value: _allContainers,
                onChanged: (v) => setState(() => _allContainers = v ?? false),
              ),
              const Divider(height: 16),
              Row(
                children: [
                  Text(
                    _loadError != null
                        ? 'Could not list pods'
                        : _loading && _items.isEmpty
                        ? 'Listing pods…'
                        : '${matches.length} pod${matches.length == 1 ? '' : 's'} match',
                    key: const ValueKey('stream-count'),
                    style: theme.textTheme.labelMedium,
                  ),
                  if (matches.length > kStreamMaxPods)
                    Text('  ·  only the first $kStreamMaxPods will stream', style: hint?.copyWith(color: severityColor(context, Severity.warn))),
                  if (_loading && _items.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 170),
                child: _loadError != null
                    ? Text(_loadError!, style: hint)
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final p in matches.take(40))
                            Text(
                              '${multiNs && p.ns.isNotEmpty ? '${p.ns}/' : ''}${p.name}${_container.text.trim().isNotEmpty ? '  ·  ${p.containers.join(', ')}' : ''}',
                              style: monoStyle(context, size: 11.5),
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (matches.length > 40) Text('… and ${matches.length - 40} more', style: hint),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('stream-open'), onPressed: canOpen ? _open : null, child: const Text('Stream')),
      ],
    );
  }
}
