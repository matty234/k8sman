import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../modules/modules.dart';
import '../state/app_state.dart';
import '../ui/widgets/common.dart';
import 'metric_history_chart.dart' show historyRanges;
import 'prom_api.dart';

const _id = 'prometheus';

/// A Prometheus or Alertmanager Service entered by hand (for setups discovery
/// doesn't recognise, e.g. Mimir under `/prometheus`) and the history
/// charts' default range. Saved per kube context (settings.json
/// moduleSettings.prometheus); shown in Settings ▸ Integrations under
/// Prometheus, whose status line says whether the address answers.
class PrometheusSettingsForm extends StatefulWidget {
  const PrometheusSettingsForm({super.key});

  @override
  State<PrometheusSettingsForm> createState() => _PrometheusSettingsFormState();
}

class _PrometheusSettingsFormState extends State<PrometheusSettingsForm> {
  static const _kinds = ['prometheus', 'alertmanager'];
  static const _fields = ['namespace', 'service', 'port', 'pathPrefix'];
  final _c = {
    for (final k in _kinds)
      for (final f in _fields) '$k.$f': TextEditingController(),
  };
  String _range = '';
  bool _loading = true;
  String? _error;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final j = await context.read<ApiClient>().getModuleSettings(_id);
      if (!mounted) return;
      setState(() {
        for (final k in _kinds) {
          final e = j[k] is Map ? j[k] as Map : const {};
          for (final f in _fields) {
            _c['$k.$f']!.text = '${e[f] ?? ''}';
          }
        }
        _range = '${j['defaultRange'] ?? ''}';
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final api = context.read<ApiClient>();
    final app = context.read<AppState>();
    final body = <String, dynamic>{
      for (final k in _kinds)
        if (_fields.any((f) => _c['$k.$f']!.text.trim().isNotEmpty))
          k: {
            for (final f in _fields)
              if (_c['$k.$f']!.text.trim().isNotEmpty) f: _c['$k.$f']!.text.trim(),
          },
      if (_range.isNotEmpty) 'defaultRange': _range,
    };
    try {
      await api.putModuleSettings(_id, body);
      PromApi.of(api).resetCaches();
      final m = builtInModules.firstWhere((m) => m.id == _id);
      moduleStatuses.refresh(m, api, app.currentContext);
      if (mounted) {
        setState(() {
          _error = null;
          _saved = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  void _edited() {
    if (_saved) setState(() => _saved = false);
  }

  Widget _field(String key, String label, String hint, {double? width}) {
    final tf = TextField(
      key: ValueKey('prom-$key'),
      controller: _c[key],
      style: Theme.of(context).textTheme.bodySmall,
      onChanged: (_) => _edited(),
      decoration: InputDecoration(isDense: true, labelText: label, hintText: hint),
    );
    return width == null ? Expanded(child: tf) : SizedBox(width: width, child: tf);
  }

  Widget _endpoint(String kind, String title, String svcHint, String port, String prefix) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: small?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Row(children: [
        _field('$kind.namespace', 'Namespace', 'monitoring'),
        const SizedBox(width: 8),
        _field('$kind.service', 'Service', svcHint),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        _field('$kind.port', 'Port', port, width: 120),
        const SizedBox(width: 8),
        _field('$kind.pathPrefix', 'Path prefix', prefix),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.read<AppState>();
    final small = theme.textTheme.bodySmall;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'For ${app.currentContext}. Leave the addresses empty to find Prometheus and Alertmanager automatically. '
          'A path prefix is for setups serving the API under a path, such as Mimir or Thanos at /prometheus.',
          style: small?.copyWith(color: theme.hintColor),
        ),
        const SizedBox(height: 14),
        if (_loading)
          const Center(
            child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
          )
        else ...[
          _endpoint('prometheus', 'Prometheus', 'mimir-query-frontend', '9090', '/prometheus'),
          const SizedBox(height: 14),
          _endpoint('alertmanager', 'Alertmanager (optional)', 'alertmanager', '9093', '/alertmanager'),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('Charts open with', style: small),
              const SizedBox(width: 12),
              MenuSelect<String>(
                key: const ValueKey('prom-default-range'),
                value: _range,
                options: [
                  ('', Text('1h', style: small)),
                  for (final (label, _) in historyRanges)
                    if (label != '1h') (label, Text(label, style: small)),
                ],
                onChanged: (v) => setState(() {
                  _range = v;
                  _saved = false;
                }),
              ),
            ],
          ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: InlineMessage(_error!, isError: true)),
        const SizedBox(height: 12),
        Row(
          children: [
            const Spacer(),
            if (_saved) Text('Saved', style: small?.copyWith(color: theme.hintColor)),
            const SizedBox(width: 10),
            FilledButton(key: const ValueKey('prom-save'), onPressed: _loading ? null : _save, child: const Text('Save')),
          ],
        ),
      ],
    );
  }
}
