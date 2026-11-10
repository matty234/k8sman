import 'package:flutter/material.dart';

import '../api/client.dart';
import '../panels/externalsecrets/es_common.dart';
import '../panels/externalsecrets/index.dart';
import '../util/k8s.dart';
import 'module.dart';

/// External Secrets Operator (external-secrets.io): ExternalSecrets, stores
/// and PushSecrets with their panels. The sidebar section only lists the
/// kinds the cluster serves, so it is absent without ESO. The backend part
/// is the "Refresh now" action and the table columns.
///
/// Replaced by the bundled external-secrets plugin
/// (backend/internal/plugins/bundled): the backend reports this module as
/// superseded, so it is off and has no Integrations row, unless
/// settings.json's plugins.useModule names the plugin (to compare the two;
/// docs/PLUGINS.md, "Bundled plugins").
class ExternalSecretsModule extends AppModule {
  const ExternalSecretsModule();

  @override
  String get id => 'external_secrets';

  @override
  String get name => 'External Secrets';

  @override
  String get description => 'ExternalSecrets, secret stores and PushSecrets (External Secrets Operator), with sync status and a refresh action.';

  @override
  List<ResourcePanel> get panels => externalSecretsPanels;

  @override
  List<NavGroup> get navGroups => const [
        NavGroup(after: 'Config', 'External Secrets', [
          'external-secrets.io/ExternalSecret',
          'external-secrets.io/ClusterExternalSecret',
          'external-secrets.io/SecretStore',
          'external-secrets.io/ClusterSecretStore',
          'external-secrets.io/PushSecret',
        ]),
      ];

  @override
  Map<String, IconData> get kindIcons => const {
        'external-secrets.io/ExternalSecret': Icons.key_outlined,
        'external-secrets.io/ClusterExternalSecret': Icons.vpn_key_outlined,
        'external-secrets.io/SecretStore': Icons.storage_outlined,
        'external-secrets.io/ClusterSecretStore': Icons.dns_outlined,
        'external-secrets.io/PushSecret': Icons.upload_outlined,
      };

  /// The CRDs are served (from discovery), and how many ExternalSecrets
  /// are not synced (from the shared list).
  @override
  Future<ModuleStatus> Function(ApiClient api) get detect => (api) async {
        final types = await api.resources();
        if (!types.any((t) => t.group == esGroup && t.resource == 'externalsecrets')) {
          return const ModuleStatus(ModuleState.notInstalled, 'External Secrets CRDs not served');
        }
        final list = await api.items(externalSecretsRef);
        final bad = list.where((e) => readyCondition(asMap(e['status']))?['status'] != 'True').length;
        return ModuleStatus(bad > 0 ? ModuleState.error : ModuleState.connected, 'ExternalSecrets: ${list.length} · not synced: $bad');
      };
}
