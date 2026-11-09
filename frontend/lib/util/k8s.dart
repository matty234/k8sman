/// Small helpers for Kubernetes data shapes shared by panels.
library;

import '../api/models.dart';

export 'format.dart';

/// Safe nested lookup: `dig(obj, ['spec', 'template', 'spec'])`.
/// Integer path segments index into lists.
T? dig<T>(dynamic obj, List<Object> path) {
  dynamic cur = obj;
  for (final p in path) {
    if (cur is Map && p is String) {
      cur = cur[p];
    } else if (cur is List && p is int && p >= 0 && p < cur.length) {
      cur = cur[p];
    } else {
      return null;
    }
  }
  return cur is T ? cur : null;
}

Json asMap(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Json> asMapList(dynamic v) => v is List ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)] : <Json>[];

DateTime? parseTime(dynamic v) => v is String ? DateTime.tryParse(v) : null;

/// Parse a CPU quantity to millicores ("250m" → 250, "1.5" → 1500).
double? parseCpuMillis(dynamic q) {
  if (q == null) return null;
  final s = '$q'.trim();
  if (s.endsWith('m')) return double.tryParse(s.substring(0, s.length - 1));
  if (s.endsWith('n')) return (double.tryParse(s.substring(0, s.length - 1)) ?? 0) / 1e6;
  if (s.endsWith('u')) return (double.tryParse(s.substring(0, s.length - 1)) ?? 0) / 1e3;
  final v = double.tryParse(s);
  return v == null ? null : v * 1000;
}

const _binary = {'Ki': 1024.0, 'Mi': 1048576.0, 'Gi': 1073741824.0, 'Ti': 1099511627776.0, 'Pi': 1125899906842624.0, 'Ei': 1152921504606846976.0};
const _decimal = {'k': 1e3, 'M': 1e6, 'G': 1e9, 'T': 1e12, 'P': 1e15, 'E': 1e18};

/// Parse a memory/storage quantity to bytes ("128Mi", "1G", "1e3").
double? parseBytes(dynamic q) {
  if (q == null) return null;
  final s = '$q'.trim();
  for (final e in _binary.entries) {
    if (s.endsWith(e.key)) return (double.tryParse(s.substring(0, s.length - 2)) ?? 0) * e.value;
  }
  for (final e in _decimal.entries) {
    if (s.endsWith(e.key)) return (double.tryParse(s.substring(0, s.length - 1)) ?? 0) * e.value;
  }
  return double.tryParse(s);
}

String formatBytes(num? b) {
  if (b == null) return '';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var i = 0;
  var v = b.toDouble();
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 10 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[i]}';
}

/// Render a LabelSelector ({matchLabels, matchExpressions}) or a plain
/// map selector (Service.spec.selector) as a kubectl selector string.
/// Returns '' for "select everything".
String selectorToString(dynamic selector) {
  final sel = asMap(selector);
  if (sel.isEmpty) return '';
  final isLabelSelector = sel.containsKey('matchLabels') || sel.containsKey('matchExpressions');
  final labels = isLabelSelector ? asMap(sel['matchLabels']) : sel;
  final parts = <String>[for (final e in labels.entries) '${e.key}=${e.value}'];
  if (isLabelSelector) {
    for (final ex in asMapList(sel['matchExpressions'])) {
      final key = ex['key'], op = ex['operator'];
      final values = (ex['values'] as List?)?.join(',') ?? '';
      switch (op) {
        case 'In':
          parts.add('$key in ($values)');
        case 'NotIn':
          parts.add('$key notin ($values)');
        case 'Exists':
          parts.add('$key');
        case 'DoesNotExist':
          parts.add('!$key');
      }
    }
  }
  return parts.join(',');
}

/// Owner references of an object as navigable refs.
List<ObjectRef> ownerRefs(Json obj) {
  final ns = dig<String>(obj, ['metadata', 'namespace']);
  return [for (final o in asMapList(dig(obj, ['metadata', 'ownerReferences']))) ObjectRef.fromOwnerRef(o, namespace: ns)];
}

/// Heuristic status → severity, for badges.
enum Severity { ok, warn, error, neutral, info }

Severity severityOf(String? status) {
  final s = (status ?? '').toLowerCase();
  if (s.isEmpty || s == 'scaled down') return Severity.neutral;
  const ok = {'running', 'ready', 'true', 'bound', 'active', 'complete', 'completed', 'succeeded', 'available', 'healthy', 'normal', 'established', 'reconciled', 'allocated', 'reserved', 'secretsynced', 'valid', 'synced'};
  const warn = {'pending', 'containercreating', 'podinitializing', 'waiting', 'terminating', 'unknown', 'progressing', 'released', 'suspended', 'warning', 'degraded', 'paused'};
  const err = {'failed', 'error', 'crashloopbackoff', 'imagepullbackoff', 'errimagepull', 'notready', 'false', 'lost', 'oomkilled', 'evicted', 'createcontainerconfigerror', 'invalidimagename', 'backofflimitexceeded', 'deadlineexceeded', 'secretsyncederror', 'invalidproviderconfig', 'validationfailed', 'errored', 'unavailable', 'stalled'};
  final head = s.split(RegExp(r'[,:]')).where((p) => p.isNotEmpty).toList();
  if (head.any(err.contains)) return Severity.error;
  // Init containers still starting (Init:PodInitializing, Init:0/2) are in
  // progress; any other Init: reason means one failed.
  if (s.startsWith('init:') && !head.any(warn.contains) && !s.contains('/')) return Severity.error;
  if (head.any(warn.contains) || s.startsWith('init:') || s.contains('schedulingdisabled')) return Severity.warn;
  if (head.any(ok.contains)) return Severity.ok;
  return Severity.info;
}
