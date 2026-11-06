import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../state/frame_stream.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'flow_list.dart';
import 'hubble_api.dart';
import 'hubble_settings.dart';

/// The Hubble page: live flows for the cluster or a namespace, recent drops
/// grouped by source, destination and reason, and "Can A reach B?". The
/// streams run only while their tab is showing.
class HubbleView extends StatefulWidget {
  const HubbleView({super.key});

  @override
  State<HubbleView> createState() => _HubbleViewState();
}

enum _Tab { flows, drops, reach }

class _HubbleViewState extends State<HubbleView> {
  HubbleStatus? _status;
  String? _error;
  _Tab _tab = _Tab.flows;
  final _from = TextEditingController();
  final _to = TextEditingController();
  int _reachRequest = 0;

  HubbleApi get _api => HubbleApi.of(context.read<ApiClient>());

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    try {
      final s = await _api.status(refresh: refresh);
      if (mounted) {
        setState(() {
          _status = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  /// From the Drops view: check a group's endpoints.
  void _checkReach(FlowEndpoint from, FlowEndpoint to) {
    setState(() {
      _from.text = from.spec ?? '';
      _to.text = to.spec ?? '';
      _tab = _Tab.reach;
      _reachRequest++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: 'Hubble',
        subtitle: s == null ? null : Text(s.connected ? s.summary : _stateLabel(s.state)),
        actions: [
          IconButton(
            tooltip: 'Hubble settings',
            iconSize: 18,
            icon: const Icon(Icons.tune),
            onPressed: () async {
              if (await showHubbleSettings(context) && mounted) _load(refresh: true);
            },
          ),
          IconButton(tooltip: 'Refresh status', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: () => _load(refresh: true)),
        ],
      ),
      const Divider(),
      if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: InlineMessage(_error!, isError: true)),
      Expanded(
        child: s == null
            ? (_error == null ? const Center(child: CircularProgressIndicator()) : const SizedBox.shrink())
            : !s.connected
                ? _NotConnected(status: s, onRetry: () => _load(refresh: true))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _Tabs(value: _tab, onChanged: (t) => setState(() => _tab = t)),
                    Container(height: 1, color: AppColors.of(context).separator),
                    Expanded(
                      child: switch (_tab) {
                        _Tab.flows => _ClusterFlows(api: _api),
                        _Tab.drops => _DropsView(api: _api, onCheck: _checkReach),
                        _Tab.reach => _ReachView(api: _api, from: _from, to: _to, request: _reachRequest),
                      },
                    ),
                  ]),
      ),
    ]);
  }
}

String _stateLabel(String state) => switch (state) {
      'notInstalled' => 'not installed',
      'noRelay' => 'no relay found',
      'unreachable' => 'relay unreachable',
      _ => state,
    };

class _Tabs extends StatelessWidget {
  final _Tab value;
  final ValueChanged<_Tab> onChanged;
  const _Tabs({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget tab(_Tab t, String label, IconData icon) => Hoverable(
          onTap: () => onChanged(t),
          builder: (h) => Container(
            key: ValueKey('hubble-tab-${t.name}'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t == value ? theme.colorScheme.primary : Colors.transparent, width: 2)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 15, color: t == value ? theme.colorScheme.primary : theme.hintColor),
              const SizedBox(width: 6),
              Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: t == value ? theme.colorScheme.primary : (h ? null : theme.hintColor))),
            ]),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        tab(_Tab.flows, 'Flows', Icons.swap_horiz),
        tab(_Tab.drops, 'Drops', Icons.block),
        tab(_Tab.reach, 'Can A reach B?', Icons.alt_route),
      ]),
    );
  }
}

/// Not installed, no relay, or unreachable: what was found and what to try.
class _NotConnected extends StatelessWidget {
  final HubbleStatus status;
  final VoidCallback onRetry;
  const _NotConnected({required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final (title, hint) = switch (s.state) {
      'notInstalled' => ('Hubble isn\'t on this cluster', 'Hubble comes with Cilium. When Cilium is installed with Hubble and Hubble Relay enabled, flows show here.'),
      'noRelay' => ('No Hubble Relay found', 'Hubble is on, but k8sman found no hubble-relay Service. If it has another name, set it in Hubble settings.'),
      _ => ('Hubble Relay doesn\'t answer', 'k8sman reaches the relay through a port-forward to one of its pods (this needs pods/portforward in its namespace).'),
    };
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(20), children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          if (s.message != null && s.message!.isNotEmpty) ...[
            const SizedBox(height: 12),
            InlineMessage(s.message!, isError: s.state == 'unreachable'),
          ],
          if (s.relayService != null) ...[
            const SizedBox(height: 12),
            KeyValueTable([
              ('Relay', ResourceLink(ObjectRef(kind: 'Service', namespace: s.relayNamespace, name: s.relayService!), label: '${s.relayNamespace}/${s.relayService}')),
              ('TLS', s.tls ? 'on' : 'off'),
            ]),
          ],
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 15), label: const Text('Check again')),
            const SizedBox(width: 8),
            TextButton(onPressed: () => showHubbleSettings(context).then((saved) => saved ? onRetry() : null), child: const Text('Hubble settings…')),
          ]),
        ]),
      ),
    );
  }
}

/// The namespace choice shared by the Flows and Drops tabs: the app's
/// current namespace to start with.
class _NamespaceSelect extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  const _NamespaceSelect({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return MenuSelect<String>(
      key: const ValueKey('hubble-namespace'),
      tooltip: 'Namespace',
      value: value ?? '',
      options: [
        ('', Text('All namespaces', style: small)),
        for (final ns in app.namespaces) (ns, Text(ns, style: small)),
      ],
      onChanged: (v) => onChanged(v.isEmpty ? null : v),
    );
  }
}

class _ClusterFlows extends StatefulWidget {
  final HubbleApi api;
  const _ClusterFlows({required this.api});

  @override
  State<_ClusterFlows> createState() => _ClusterFlowsState();
}

class _ClusterFlowsState extends State<_ClusterFlows> {
  late String? _ns = context.read<AppState>().namespace;
  String? _protocol;
  String? _direction;
  final _port = TextEditingController();
  String? _portValue;

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final q = FlowQuery(namespaces: [?_ns], protocol: _protocol, port: _portValue, direction: _direction);
    return FlowStreamView(
      query: q,
      api: widget.api,
      emptyHint: _ns == null ? 'No flows yet' : 'No flows in $_ns yet',
      filters: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _NamespaceSelect(value: _ns, onChanged: (v) => setState(() => _ns = v)),
          MenuSelect<String>(
            tooltip: 'Protocol',
            value: _protocol ?? '',
            options: [
              ('', Text('Any protocol', style: small)),
              for (final p in const ['tcp', 'udp', 'icmp', 'sctp', 'http', 'dns', 'kafka']) (p, Text(p.toUpperCase(), style: small)),
            ],
            onChanged: (v) => setState(() => _protocol = v.isEmpty ? null : v),
          ),
          MenuSelect<String>(
            tooltip: 'Direction',
            value: _direction ?? '',
            options: [
              ('', Text('Both directions', style: small)),
              ('ingress', Text('Ingress', style: small)),
              ('egress', Text('Egress', style: small)),
            ],
            onChanged: (v) => setState(() => _direction = v.isEmpty ? null : v),
          ),
          SizedBox(
            width: 110,
            height: 28,
            child: TextField(
              controller: _port,
              style: small,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true, hintText: 'Port', prefixIcon: Icon(Icons.numbers, size: 14), prefixIconConstraints: BoxConstraints(minWidth: 26)),
              onSubmitted: (v) => setState(() => _portValue = int.tryParse(v.trim()) == null ? null : v.trim()),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Live drops, grouped by source, destination, reason and port, most
/// frequent first. Starts with what the relay still holds, then counts as
/// drops happen.
class _DropsView extends StatefulWidget {
  final HubbleApi api;
  final void Function(FlowEndpoint from, FlowEndpoint to) onCheck;
  const _DropsView({required this.api, required this.onCheck});

  @override
  State<_DropsView> createState() => _DropsViewState();
}

class _DropsViewState extends State<_DropsView> {
  late String? _ns = context.read<AppState>().namespace;
  FrameStream<HubbleFlow>? _stream;
  final Map<String, DropGroup> _groups = {};
  int _seen = 0;
  DateTime _since = DateTime.now();

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _stream?.dispose();
    _groups.clear();
    _seen = 0;
    _since = DateTime.now();
    final s = FrameStream<HubbleFlow>(
      capacity: 1,
      connect: () => widget.api.flowFrames(FlowQuery(namespaces: [?_ns], verdicts: const {'DROPPED'})),
      decode: (j) {
        final f = decodeFlowFrame(j);
        // Grouped as they arrive; the stream itself keeps nothing.
        DropGroup.group(_groups, f.items);
        _seen += f.items.length;
        for (final x in f.items) {
          if (x.time != null && x.time!.isBefore(_since)) _since = x.time!;
        }
        return f;
      },
    );
    _stream = s..start();
  }

  @override
  void dispose() {
    _stream?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _stream!;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final groups = _groups.values.toList()..sort((a, b) => b.count != a.count ? b.count.compareTo(a.count) : (b.last ?? _since).compareTo(a.last ?? _since));
        final small = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _NamespaceSelect(value: _ns, onChanged: (v) => setState(() {
                    _ns = v;
                    _start();
                  })),
              IconButton(tooltip: 'Start counting again', iconSize: 16, visualDensity: VisualDensity.compact, icon: const Icon(Icons.restart_alt), onPressed: () => setState(_start)),
              Text(
                [
                  '$_seen drop${_seen == 1 ? '' : 's'} in ${groups.length} group${groups.length == 1 ? '' : 's'} since ${_hms(_since)}',
                  if (s.lost > 0) '${s.lost} skipped',
                  switch (s.phase) { FramePhase.connecting => 'connecting', FramePhase.live => 'live', FramePhase.ended => 'ended', FramePhase.error => 'error' },
                ].join(' · '),
                style: small,
              ),
            ]),
          ),
          Container(height: 1, color: AppColors.of(context).separator),
          if (s.phase == FramePhase.error) Padding(padding: const EdgeInsets.all(10), child: InlineMessage(s.error ?? 'error', isError: true)),
          Expanded(
            child: groups.isEmpty
                ? Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: InlineMessage(s.phase == FramePhase.connecting ? 'Reading recent drops…' : 'No drops${_ns == null ? '' : ' in $_ns'} so far. New ones are counted as they happen.', icon: Icons.check_circle_outline),
                    ),
                  )
                : ListView.builder(
                    itemCount: groups.length + 1,
                    itemExtent: 30,
                    itemBuilder: (context, i) => i == 0 ? const _DropHeader() : _DropRow(group: groups[i - 1], onCheck: widget.onCheck),
                  ),
          ),
        ]);
      },
    );
  }
}

String _hms(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

class _DropHeader extends StatelessWidget {
  const _DropHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        SizedBox(width: 60, child: Text('Count', style: s)),
        Expanded(flex: 4, child: Text('Source', style: s)),
        Expanded(flex: 4, child: Text('Destination', style: s)),
        SizedBox(width: 90, child: Text('Port', style: s)),
        Expanded(flex: 3, child: Text('Reason', style: s)),
        SizedBox(width: 70, child: Text('Last', style: s)),
        const SizedBox(width: 30),
      ]),
    );
  }
}

class _DropRow extends StatelessWidget {
  final DropGroup group;
  final void Function(FlowEndpoint from, FlowEndpoint to) onCheck;
  const _DropRow({required this.group, required this.onCheck});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = group;
    final err = severityColor(context, Severity.error);
    final small = theme.textTheme.bodySmall;
    final reason = [dropReasonLabel(g.reason), if (g.deniedBy.isNotEmpty) 'by ${g.deniedBy.join(', ')}'].join(' ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        SizedBox(width: 60, child: Text('${g.count}', style: monoStyle(context, size: 12))),
        Expanded(flex: 4, child: FlowEndpointText(g.source)),
        Expanded(flex: 4, child: FlowEndpointText(g.destination)),
        SizedBox(width: 90, child: Text([g.protocol ?? '', if (g.port != null && g.port! > 0) ':${g.port}'].join(), style: monoStyle(context, size: 11, color: theme.hintColor))),
        Expanded(flex: 3, child: Tooltip(message: reason, child: Text(reason, maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: err, fontWeight: FontWeight.w600)))),
        SizedBox(width: 70, child: Text(g.last == null ? '' : _hms(g.last!), style: small?.copyWith(color: theme.hintColor))),
        SizedBox(
          width: 30,
          child: g.source.spec == null || g.destination.spec == null
              ? null
              : IconButton(
                  tooltip: 'Can source reach destination?',
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.alt_route),
                  onPressed: () => onCheck(g.source, g.destination),
                ),
        ),
      ]),
    );
  }
}

/// "Can A reach B?": what Hubble saw from one endpoint to the other, as a
/// verdict with drop reasons and policies, then the flows live.
class _ReachView extends StatefulWidget {
  final HubbleApi api;
  final TextEditingController from;
  final TextEditingController to;

  /// Bumped when another tab filled in [from] and [to]: check right away.
  final int request;
  const _ReachView({required this.api, required this.from, required this.to, required this.request});

  @override
  State<_ReachView> createState() => _ReachViewState();
}

class _ReachViewState extends State<_ReachView> {
  Connectivity? _result;
  String? _error;
  bool _busy = false;
  (String, String)? _checked;

  @override
  void initState() {
    super.initState();
    if (widget.request > 0 && widget.from.text.isNotEmpty && widget.to.text.isNotEmpty) _check();
  }

  Future<void> _check() async {
    final from = widget.from.text.trim(), to = widget.to.text.trim();
    if (from.isEmpty || to.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.connectivity(from, to);
      if (mounted) {
        setState(() {
          _result = r;
          _checked = (from, to);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is ApiException ? e.message : '$e';
          _result = null;
          _checked = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    InputDecoration deco(String label) => InputDecoration(
          isDense: true,
          labelText: label,
          hintText: 'namespace/pod, svc:namespace/name, ns:namespace, fqdn:name or an IP',
        );
    final checked = _checked;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Row(children: [
          Expanded(child: TextField(key: const ValueKey('reach-from'), controller: widget.from, style: small, decoration: deco('From'), onSubmitted: (_) => _check())),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, size: 16, color: theme.hintColor)),
          Expanded(child: TextField(key: const ValueKey('reach-to'), controller: widget.to, style: small, decoration: deco('To'), onSubmitted: (_) => _check())),
          const SizedBox(width: 8),
          FilledButton(onPressed: _busy ? null : _check, child: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Check')),
        ]),
      ),
      if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: InlineMessage(_error!, isError: true)),
      if (_result != null && checked != null) ...[
        _ReachSummary(result: _result!),
        Container(height: 1, color: AppColors.of(context).separator),
        Expanded(
          child: FlowStreamView(
            key: ValueKey(checked),
            api: widget.api,
            query: FlowQuery(from: checked.$1, to: checked.$2),
            emptyHint: 'No flows from ${checked.$1} to ${checked.$2} yet. Try connecting now: new flows show here as they happen.',
          ),
        ),
      ] else if (_error == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Text(
            'Looks at the flows Hubble saw from one endpoint to the other: whether they were forwarded or dropped, why, and which policy decided. '
            'Hubble only knows about traffic that happened, and the relay keeps a limited history: if nothing shows, make a request and watch the list.',
            style: small?.copyWith(color: theme.hintColor),
          ),
        ),
    ]);
  }
}

class _ReachSummary extends StatelessWidget {
  final Connectivity result;
  const _ReachSummary({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = result;
    final (sev, title) = switch (r.verdict) {
      'allowed' => (Severity.ok, 'Reachable: traffic was forwarded'),
      'dropped' => (Severity.error, 'Blocked: traffic was dropped'),
      'mixed' => (Severity.warn, 'Partly blocked: some traffic was dropped'),
      _ => (Severity.neutral, 'No traffic seen between them'),
    };
    final c = severityColor(context, sev);
    final small = theme.textTheme.bodySmall;
    String counts(Map<String, int> m) => m.isEmpty ? 'none' : (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => '${e.value} ${verdictLabel(e.key)}').join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(severityIcon(sev), color: c, size: 18),
          const SizedBox(width: 8),
          Text(title, key: const ValueKey('reach-verdict'), style: theme.textTheme.titleSmall?.copyWith(color: c)),
        ]),
        const SizedBox(height: 6),
        KeyValueTable(keyWidth: 120, [
          ('This way', counts(r.verdicts)),
          ('The other way', counts(r.reverse)),
          if (r.drops.isNotEmpty)
            (
              'Dropped because',
              Text(
                r.drops.map((d) => '${dropReasonLabel(d.reason)}${d.port != null && d.port! > 0 ? ' (${d.protocol ?? ''}:${d.port})' : ''} ×${d.count}${d.deniedBy.isNotEmpty ? ', denied by ${d.deniedBy.join(', ')}' : ''}').join('\n'),
                style: small?.copyWith(color: severityColor(context, Severity.error)),
              ),
            ),
          if (r.allowedBy.isNotEmpty) ('Allowed by', r.allowedBy.join(', ')),
          if (r.oldest != null) ('Looked back to', '${_hms(r.oldest!)} (the relay\'s history)'),
        ]),
      ]),
    );
  }
}
