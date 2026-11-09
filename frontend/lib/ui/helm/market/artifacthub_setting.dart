import 'package:flutter/material.dart';

import '../../../api/error_info.dart' show errorText;
import '../../settings/settings_widgets.dart';
import 'market_api.dart';

/// Settings ▸ Clusters ▸ Helm charts: the global Artifact Hub opt-in.
SettingItem artifactHubSetting() => SettingItem(
      key: const ValueKey('settings-artifacthub'),
      group: 'Helm charts',
      label: 'Search Artifact Hub',
      description: 'The Helm page can browse and search charts on artifacthub.io, which sends it your search terms and the charts you open.',
      keywords: const ['helm', 'artifact hub', 'artifacthub', 'charts', 'search', 'privacy', 'network', 'marketplace'],
      builder: (_) => const _ArtifactHubSetting(),
    );

class _ArtifactHubSetting extends StatefulWidget {
  const _ArtifactHubSetting();

  @override
  State<_ArtifactHubSetting> createState() => _ArtifactHubSettingState();
}

class _ArtifactHubSettingState extends State<_ArtifactHubSetting> {
  late final HelmMarketApi _api = HelmMarketApi.of(context);
  bool? _on;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(_api.artifactHubEnabled);
  }

  Future<void> _run(Future<bool> Function() f) async {
    try {
      final v = await f();
      if (mounted) setState(() => (_on = v, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingRow(
      label: 'Search Artifact Hub',
      description: 'The Helm page can browse and search charts on artifacthub.io, which sends it your search terms and the charts you open. '
          'Also used to spot newer versions of installed charts. Off until you turn it on.',
      trailing: _error != null
          ? Tooltip(message: _error!, child: Text('Unavailable', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)))
          : SettingSwitch(
              key: const ValueKey('artifacthub-switch'),
              value: _on ?? false,
              onChanged: _on == null ? null : (v) => _run(() => _api.setArtifactHub(v)),
            ),
    );
  }
}
