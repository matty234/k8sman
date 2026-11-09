/// Shared pieces of the External Secrets Operator panels
/// (external-secrets.io). v1 and v1beta1 objects share the fields read here.
library;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../pod/pod_widgets.dart';
import '../../ui/inspector/inspector.dart' show Callout;

const esGroup = 'external-secrets.io';

const externalSecretsRef = ResourceRef(group: esGroup, resource: 'externalsecrets');

ObjectRef externalSecretRef(String name, String? ns) => ObjectRef(group: esGroup, kind: 'ExternalSecret', name: name, namespace: ns);
ObjectRef secretRef(String name, String? ns) => ObjectRef(kind: 'Secret', name: name, namespace: ns);

/// The store an ExternalSecret (or PushSecret store ref) names: a
/// SecretStore in [ns], or a cluster-scoped ClusterSecretStore.
ObjectRef storeRefFor(Json ref, String? ns) {
  final kind = '${ref['kind'] ?? 'SecretStore'}';
  return ObjectRef(group: esGroup, kind: kind, name: '${ref['name'] ?? ''}', namespace: kind == 'SecretStore' ? ns : null);
}

/// The Ready condition of an ESO object, or null.
Json? readyCondition(Json status) => asMapList(status['conditions']).where((c) => c['type'] == 'Ready').firstOrNull;

/// Ready reason ("SecretSynced", "SecretSyncedError", "Valid", …), or
/// "Unknown" before the controller has reported.
String readyReason(Json status) {
  final c = readyCondition(status);
  return c == null ? 'Unknown' : '${c['reason'] ?? c['status']}';
}

/// The Ready condition as a callout when it is not True, else a quiet
/// message line. Shows the condition's message prominently.
class ReadyCallout extends StatelessWidget {
  final Json status;
  const ReadyCallout(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = readyCondition(status);
    if (c == null) return const Hint('No Ready condition yet: the operator has not reconciled this object.');
    final message = '${c['message'] ?? ''}';
    if (c['status'] == 'True') return message.isEmpty ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(bottom: 8), child: Hint(message));
    return Callout(severity: severityOf(readyReason(status)) == Severity.warn ? Severity.warn : Severity.error, title: readyReason(status), body: message);
  }
}

/// Ready reason as a badge for a section trailer.
Widget readyBadge(Json status) => StatusBadge(readyReason(status), dense: true);

/// A SecretStore reference as a link, with its kind when it is cluster-wide.
Widget storeLink(Json ref, String? ns) {
  final r = storeRefFor(ref, ns);
  return InlineWrap([ResourceLink(r, label: '${r.kind}/${r.name}')]);
}

/// Provider settings of a store as `path → value` rows. Auth secret
/// references become Secret links; values are never read from Secrets.
List<(String, Object?)> providerRows(Json provider, String? ns, {int limit = 14}) {
  final rows = <(String, Object?)>[];
  void walk(String path, dynamic v) {
    if (rows.length >= limit) return;
    if (v is Map) {
      final key = path.split('.').last.toLowerCase();
      final name = v['name'];
      if (name is String && key.endsWith('secretref')) {
        final key2 = v['key'];
        rows.add((path, ResourceLink(secretRef(name, v['namespace'] as String? ?? ns), label: 'Secret/$name${key2 is String ? ' · $key2' : ''}')));
        return;
      }
      if (name is String && key.endsWith('serviceaccountref')) {
        rows.add((path, ResourceLink(ObjectRef(kind: 'ServiceAccount', name: name, namespace: v['namespace'] as String? ?? ns), label: 'ServiceAccount/$name')));
        return;
      }
      for (final e in v.entries) {
        walk(path.isEmpty ? '${e.key}' : '$path.${e.key}', e.value);
      }
    } else if (v is List) {
      rows.add((path, v.every((e) => e is! Map && e is! List) ? v.join(', ') : '${v.length} entries'));
    } else if (v != null) {
      final s = '$v';
      rows.add((path, s.length > 80 ? '(${s.length} characters)' : s));
    }
  }

  walk('', provider);
  return rows;
}
