import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';

/// Well-known API group domains → icons bundled in assets/icons/ (sources
/// and licences in assets/icons/ATTRIBUTION.md). A group matches a domain
/// when it equals it or is a subdomain of it. Keep in sync with
/// backend/internal/icons/curated.go.
const bundledGroupIcons = <String, String>{
  'argoproj.io': 'argo',
  'cert-manager.io': 'cert-manager',
  'monitoring.coreos.com': 'prometheus',
  'operators.coreos.com': 'operatorframework',
  'envoyproxy.io': 'envoy',
  'keda.sh': 'keda',
  'istio.io': 'istio',
  'linkerd.io': 'linkerd',
  'crossplane.io': 'crossplane',
  'fluxcd.io': 'flux',
  'cilium.io': 'cilium',
  'knative.dev': 'knative',
  'tekton.dev': 'tekton',
  'kyverno.io': 'kyverno',
  'gatekeeper.sh': 'opa',
  'openpolicyagent.org': 'opa',
  'velero.io': 'velero',
  'external-secrets.io': 'external-secrets',
  'kubevirt.io': 'kubevirt',
  'longhorn.io': 'longhorn',
  'rook.io': 'rook',
  'strimzi.io': 'strimzi',
  'metallb.io': 'metallb',
  'projectcontour.io': 'contour',
  'opentelemetry.io': 'opentelemetry',
  'jaegertracing.io': 'jaeger',
  'thanos.io': 'thanos',
  'goharbor.io': 'harbor',
  'cnpg.io': 'cloudnativepg',
  'kubeflow.org': 'kubeflow',
  'dapr.io': 'dapr',
  'karmada.io': 'karmada',
  'kruise.io': 'openkruise',
  'volcano.sh': 'volcano',
  'aquasecurity.github.io': 'trivy',
  'k8s.io': 'kubernetes',
  'x-k8s.io': 'kubernetes',
};

/// The bundled asset path for [group], or null.
String? bundledGroupIconAsset(String group) {
  for (final e in bundledGroupIcons.entries) {
    if (group == e.key || group.endsWith('.${e.key}')) return 'assets/icons/${e.value}.png';
  }
  return null;
}

/// Process-wide memo of `/api/icons/{group}` lookups. The backend caches
/// on disk too, so this only saves round trips within a session.
class GroupIconCache {
  static final Map<String, Future<Uint8List?>> _pending = {};
  static final Map<String, Uint8List?> _done = {};

  static String _key(ApiClient api, String group) => '${api.base}|$group';

  /// The result if the lookup already finished (null value = no icon).
  static ({Uint8List? bytes})? peek(ApiClient api, String group) {
    final k = _key(api, group);
    return _done.containsKey(k) ? (bytes: _done[k]) : null;
  }

  static Future<Uint8List?> load(ApiClient api, String group) {
    final k = _key(api, group);
    return _pending.putIfAbsent(k, () async {
      try {
        final b = await api.groupIcon(group);
        _done[k] = (b == null || b.isEmpty) ? null : b;
        return _done[k];
      } catch (_) {
        // Backend unreachable or erroring: show the monogram, retry later.
        _pending.remove(k);
        return null;
      }
    });
  }

  /// Forgets everything (e.g. after switching cluster).
  static void clear() {
    _pending.clear();
    _done.clear();
  }
}

/// An app icon for a CRD API group: a bundled icon for well-known projects,
/// else whatever the backend found (Helm chart icon or website favicon),
/// else a generated monogram. Drawn on a light rounded tile so dark logos
/// stay visible in the dark theme.
class GroupIcon extends StatefulWidget {
  final String group;
  final double size;
  const GroupIcon({super.key, required this.group, this.size = 16});

  @override
  State<GroupIcon> createState() => _GroupIconState();
}

class _GroupIconState extends State<GroupIcon> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(GroupIcon old) {
    super.didUpdateWidget(old);
    if (old.group != widget.group) {
      _bytes = null;
      _resolve();
    }
  }

  void _resolve() {
    final group = widget.group;
    if (bundledGroupIconAsset(group) != null) return;
    final api = Provider.of<ApiClient?>(context, listen: false);
    if (api == null) return;
    final known = GroupIconCache.peek(api, group);
    if (known != null) {
      _bytes = known.bytes;
      return;
    }
    GroupIconCache.load(api, group).then((b) {
      if (mounted && widget.group == group && b != null) setState(() => _bytes = b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final radius = BorderRadius.circular(s * 0.24);
    final monogram = GroupMonogram(group: widget.group, size: s);
    final asset = bundledGroupIconAsset(widget.group);
    final Widget image;
    if (asset != null) {
      image = Image.asset(asset, filterQuality: FilterQuality.medium, errorBuilder: (_, _, _) => monogram);
    } else if (_bytes != null) {
      image = Image.memory(_bytes!, filterQuality: FilterQuality.medium, gaplessPlayback: true, errorBuilder: (_, _, _) => monogram);
    } else {
      return monogram;
    }
    final key = ValueKey('group-icon-image/${widget.group}');
    // Light theme: the logo as is, softly rounded. Dark theme: on a light
    // tile, since many logos are dark or have dark wordmarks.
    if (Theme.of(context).brightness == Brightness.light) {
      return SizedBox(key: key, width: s, height: s, child: ClipRRect(borderRadius: radius, child: image));
    }
    return Container(
      key: key,
      width: s,
      height: s,
      padding: EdgeInsets.all(s * 0.08),
      decoration: BoxDecoration(color: const Color(0xFFE6E6EB), borderRadius: radius),
      child: Center(child: image),
    );
  }
}

/// The fallback: the group's first letter on a colour derived from a hash
/// of the group, so each group keeps the same colour everywhere.
class GroupMonogram extends StatelessWidget {
  final String group;
  final double size;
  const GroupMonogram({super.key, required this.group, required this.size});

  /// FNV-1a: stable across runs and platforms (unlike String.hashCode).
  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  static Color colorFor(String group) =>
      HSLColor.fromAHSL(1, (_hash(group) % 360).toDouble(), 0.48, 0.46).toColor();

  static String letterFor(String group) {
    final m = RegExp(r'[A-Za-z0-9]').firstMatch(group);
    return m == null ? '?' : m.group(0)!.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('group-icon-monogram/$group'),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colorFor(group), borderRadius: BorderRadius.circular(size * 0.24)),
      child: Text(
        letterFor(group),
        textScaler: TextScaler.noScaling,
        style: TextStyle(color: Colors.white, fontSize: size * 0.62, height: 1, fontWeight: FontWeight.w600),
      ),
    );
  }
}
