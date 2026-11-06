import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../modules/modules.dart';
import '../state/app_state.dart';
import '../ui/widgets/common.dart';

const _id = 'hubble';

/// Opens Hubble's settings for the current kube context. True when saved.
Future<bool> showHubbleSettings(BuildContext context) async {
  final api = context.read<ApiClient>();
  final app = context.read<AppState>();
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: const Dialog(insetPadding: EdgeInsets.all(32), child: SizedBox(width: 440, child: HubbleSettingsForm())),
    ),
  );
  return saved == true;
}

/// Overrides for clusters where discovery guesses wrong: the relay Service,
/// TLS, and the name its certificate is checked against. Saved per kube
/// context (settings.json moduleSettings.hubble).
class HubbleSettingsForm extends StatefulWidget {
  const HubbleSettingsForm({super.key});

  @override
  State<HubbleSettingsForm> createState() => _HubbleSettingsFormState();
}

class _HubbleSettingsFormState extends State<HubbleSettingsForm> {
  final _relay = TextEditingController();
  final _serverName = TextEditingController();
  String _tls = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _relay.dispose();
    _serverName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final j = await context.read<ApiClient>().getModuleSettings(_id);
      if (!mounted) return;
      setState(() {
        _relay.text = '${j['relay'] ?? ''}';
        _serverName.text = '${j['tlsServerName'] ?? ''}';
        _tls = '${j['tls'] ?? ''}';
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
      if (_relay.text.trim().isNotEmpty) 'relay': _relay.text.trim(),
      if (_tls.isNotEmpty) 'tls': _tls,
      if (_serverName.text.trim().isNotEmpty) 'tlsServerName': _serverName.text.trim(),
    };
    try {
      await api.putModuleSettings(_id, body);
      final m = builtInModules.firstWhere((m) => m.id == _id);
      moduleStatuses.refresh(m, api, app.currentContext);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.read<AppState>();
    final small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Hubble settings', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('For ${app.currentContext}. Leave empty to find Hubble Relay automatically.', style: small?.copyWith(color: theme.hintColor)),
        const SizedBox(height: 14),
        if (_loading)
          const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
        else ...[
          TextField(
            key: const ValueKey('hubble-relay'),
            controller: _relay,
            style: small,
            decoration: const InputDecoration(isDense: true, labelText: 'Relay Service', hintText: 'namespace/name[:port], e.g. kube-system/hubble-relay:80'),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Text('TLS', style: small),
            const SizedBox(width: 12),
            MenuSelect<String>(
              value: _tls,
              options: [
                ('', Text('As the relay is configured', style: small)),
                ('on', Text('On', style: small)),
                ('off', Text('Off', style: small)),
              ],
              onChanged: (v) => setState(() => _tls = v),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _serverName,
            style: small,
            decoration: const InputDecoration(isDense: true, labelText: 'TLS server name', hintText: 'ui.hubble-relay.cilium.io'),
          ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: InlineMessage(_error!, isError: true)),
        const SizedBox(height: 16),
        Row(children: [
          const Spacer(),
          OutlinedButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(onPressed: _loading ? null : _save, child: const Text('Save')),
        ]),
      ]),
    );
  }
}
