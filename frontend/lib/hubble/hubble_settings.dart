import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../modules/modules.dart';
import '../state/app_state.dart';
import '../ui/widgets/common.dart';
import '../api/error_info.dart' show errorText;

const _id = 'hubble';

/// Overrides for clusters where discovery guesses wrong: the relay Service,
/// TLS, and the name its certificate is checked against. Saved per kube
/// context (settings.json moduleSettings.hubble). Shown in Settings ▸
/// Integrations under Cilium Hubble.
class HubbleSettingsForm extends StatefulWidget {
  const HubbleSettingsForm({super.key});

  @override
  State<HubbleSettingsForm> createState() => _HubbleSettingsFormState();
}

class _HubbleSettingsFormState extends State<HubbleSettingsForm> {
  final _relay = TextEditingController();
  final _serverName = TextEditingController();
  String _tls = '';
  bool _rdns = true;
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
        _rdns = j['reverseDNS'] != false;
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
      if (!_rdns) 'reverseDNS': false,
    };
    try {
      await api.putModuleSettings(_id, body);
      final m = builtInModules.firstWhere((m) => m.id == _id);
      moduleStatuses.refresh(m, api, app.currentContext);
      if (mounted) {
        setState(() {
          _error = null;
          _saved = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  void _edited() {
    if (_saved) setState(() => _saved = false);
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
        Text('For ${app.currentContext}. Leave empty to find Hubble Relay automatically.', style: small?.copyWith(color: theme.hintColor)),
        const SizedBox(height: 14),
        if (_loading)
          const Center(
            child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
          )
        else ...[
          TextField(
            key: const ValueKey('hubble-relay'),
            controller: _relay,
            style: small,
            onChanged: (_) => _edited(),
            decoration: const InputDecoration(isDense: true, labelText: 'Relay Service', hintText: 'namespace/name[:port], e.g. kube-system/hubble-relay:80'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('TLS', style: small),
              const SizedBox(width: 12),
              MenuSelect<String>(
                value: _tls,
                options: [
                  ('', Text('As the relay is configured', style: small)),
                  ('on', Text('On', style: small)),
                  ('off', Text('Off', style: small)),
                ],
                onChanged: (v) => setState(() {
                  _tls = v;
                  _saved = false;
                }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _serverName,
            style: small,
            onChanged: (_) => _edited(),
            decoration: const InputDecoration(isDense: true, labelText: 'TLS server name', hintText: 'ui.hubble-relay.cilium.io'),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const ValueKey('hubble-rdns'),
            value: _rdns,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('Look up reverse DNS for world addresses', style: small),
            subtitle: Text(
              'Public addresses on the map get their PTR name. Cluster objects (nodes, Services, Ingresses) always name their own addresses.',
              style: small?.copyWith(color: theme.hintColor),
            ),
            onChanged: (v) => setState(() {
              _rdns = v ?? true;
              _saved = false;
            }),
          ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: InlineMessage(_error!, isError: true)),
        const SizedBox(height: 12),
        Row(
          children: [
            const Spacer(),
            if (_saved) Text('Saved', style: small?.copyWith(color: theme.hintColor)),
            const SizedBox(width: 10),
            FilledButton(key: const ValueKey('hubble-save'), onPressed: _loading ? null : _save, child: const Text('Save')),
          ],
        ),
      ],
    );
  }
}
