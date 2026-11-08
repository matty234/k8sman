import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../widgets/common.dart';

/// "Owns": the objects whose ownerReferences name this object's uid, grouped
/// by kind, each expandable to its own children (loaded when opened). Hidden
/// while loading, on error, and when there are none.
class OwnedSection extends StatefulWidget {
  final String uid;
  final String? namespace;
  const OwnedSection({super.key, required this.uid, this.namespace});

  @override
  State<OwnedSection> createState() => _OwnedSectionState();
}

class _OwnedSectionState extends State<OwnedSection> {
  static const _manyThreshold = 8;
  ({List<Json> items, bool partial})? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<ApiClient>().owned(uid: widget.uid, namespace: widget.namespace);
      if (mounted) setState(() => _result = r);
    } catch (_) {
      // Best effort: the section just stays hidden.
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    if (r == null || r.items.isEmpty) return const SizedBox.shrink();
    return DetailSection(
      title: 'Owns',
      icon: Icons.account_tree_outlined,
      initiallyExpanded: r.items.length <= _manyThreshold,
      trailing: Text('${r.items.length}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _OwnedGroups(items: r.items, depth: 0),
        if (r.partial)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text("Some kinds weren't searched", style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
          ),
      ]),
    );
  }
}

class _OwnedGroups extends StatelessWidget {
  final List<Json> items;
  final int depth;
  const _OwnedGroups({required this.items, required this.depth});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byKind = <String, List<Json>>{};
    for (final i in items) {
      byKind.putIfAbsent('${i['kind']}', () => []).add(i);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final e in byKind.entries) ...[
        Padding(
          padding: EdgeInsets.fromLTRB(depth * 16.0, 4, 0, 2),
          child: Text('${e.key} (${e.value.length})', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        ),
        for (final i in e.value) _OwnedRow(item: i, depth: depth),
      ],
    ]);
  }
}

class _OwnedRow extends StatefulWidget {
  final Json item;
  final int depth;
  const _OwnedRow({required this.item, required this.depth});

  @override
  State<_OwnedRow> createState() => _OwnedRowState();
}

class _OwnedRowState extends State<_OwnedRow> {
  bool _open = false;
  Future<({List<Json> items, bool partial})>? _children;

  void _toggle() {
    setState(() {
      _open = !_open;
      final ns = widget.item['namespace'] as String?;
      _children ??= context.read<ApiClient>().owned(uid: '${widget.item['uid']}', namespace: ns == null || ns.isEmpty ? null : ns);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = widget.item;
    final status = '${i['status'] ?? ''}';
    final ns = i['namespace'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.only(left: widget.depth * 16.0),
        child: Row(children: [
          InkWell(
            onTap: _toggle,
            child: Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16, color: theme.hintColor),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: ResourceLink(
              ObjectRef(group: '${i['group'] ?? ''}', kind: '${i['kind']}', name: '${i['name']}', namespace: ns == null || ns.isEmpty ? null : ns),
              label: '${i['name']}',
              singleLine: true,
            ),
          ),
          if (status.isNotEmpty) ...[const SizedBox(width: 8), StatusBadge(status, dense: true)],
        ]),
      ),
      if (_open)
        FutureBuilder(
          future: _children,
          builder: (context, snap) {
            final muted = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
            final pad = EdgeInsets.only(left: (widget.depth + 1) * 16.0 + 20, top: 2, bottom: 2);
            if (snap.hasError) return Padding(padding: pad, child: Text('Could not load', style: muted));
            final r = snap.data;
            if (r == null) return Padding(padding: pad, child: Text('Loading…', style: muted));
            if (r.items.isEmpty) return Padding(padding: pad, child: Text('Owns nothing', style: muted));
            return _OwnedGroups(items: r.items, depth: widget.depth + 1);
          },
        ),
    ]);
  }
}
