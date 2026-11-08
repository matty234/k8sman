import '../panel.dart';
import 'clusterexternalsecret_panel.dart';
import 'externalsecret_panel.dart';
import 'store_panel.dart';

/// Panels of the External Secrets Operator (external-secrets.io).
/// Registered by their module in lib/modules. PushSecret uses the generic
/// panel.
final List<ResourcePanel> externalSecretsPanels = [
  const ExternalSecretPanel(),
  const ClusterExternalSecretPanel(),
  const SecretStorePanel(),
];
