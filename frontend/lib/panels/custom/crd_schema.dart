/// CRD lookup (cached per type) and OpenAPI schema navigation helpers.
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../util/k8s.dart';

const crdResource = ResourceRef(group: 'apiextensions.k8s.io', resource: 'customresourcedefinitions');

/// Fetches each CRD at most once per app run. Failures are not cached, so a
/// later panel open retries.
class CrdCache {
  static final Map<String, Future<Json?>> _cache = {};

  static Future<Json?> get(ApiClient api, String crdName) {
    return _cache[crdName] ??= api.object(crdResource, name: crdName).then<Json?>((v) => v).catchError((Object _) {
      _cache.remove(crdName);
      return null;
    });
  }

  @visibleForTesting
  static void clear() => _cache.clear();
}

/// The `spec.versions[]` entry for [version] (or the storage / first version).
Json? crdVersionEntry(Json? crd, String? version) {
  final versions = asMapList(dig(crd, ['spec', 'versions']));
  if (versions.isEmpty) return null;
  return versions.firstWhere((v) => v['name'] == version,
      orElse: () => versions.firstWhere((v) => v['storage'] == true, orElse: () => versions.first));
}

/// `openAPIV3Schema` of [version] (or the storage version / first version).
Json? crdVersionSchema(Json? crd, String? version) {
  final s = dig<Map>(crdVersionEntry(crd, version), ['schema', 'openAPIV3Schema']);
  return s == null ? null : asMap(s);
}

/// Schema for map key [key] under [schema] (properties, else additionalProperties).
Json? schemaChild(Json? schema, String key) {
  if (schema == null) return null;
  final props = schema['properties'];
  if (props is Map && props[key] is Map) return asMap(props[key]);
  final addl = schema['additionalProperties'];
  if (addl is Map) return asMap(addl);
  return null;
}

/// Schema for the elements of an array schema.
Json? schemaItems(Json? schema) {
  final items = schema?['items'];
  return items is Map ? asMap(items) : null;
}

String? schemaDescription(Json? schema) {
  final d = schema?['description'];
  return d is String && d.trim().isNotEmpty ? d.trim() : null;
}

/// Resolves the CRD for a custom [type] and hands its version schema (or null
/// while loading / on failure) to [builder], along with the CRD's
/// `spec.versions[]` entry for that version. Shares one fetch per type.
class CrdSchemaScope extends StatefulWidget {
  final ApiClient api;
  final ResourceType type;
  final String? version;
  final Widget Function(BuildContext context, Json? schema, Json? versionEntry) builder;
  const CrdSchemaScope({super.key, required this.api, required this.type, this.version, required this.builder});

  @override
  State<CrdSchemaScope> createState() => _CrdSchemaScopeState();
}

class _CrdSchemaScopeState extends State<CrdSchemaScope> {
  Future<Json?>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.type.custom ? CrdCache.get(widget.api, '${widget.type.resource}.${widget.type.group}') : null;
  }

  @override
  void didUpdateWidget(CrdSchemaScope old) {
    super.didUpdateWidget(old);
    if (old.type != widget.type) _future = widget.type.custom ? CrdCache.get(widget.api, '${widget.type.resource}.${widget.type.group}') : null;
  }

  @override
  Widget build(BuildContext context) {
    if (_future == null) return widget.builder(context, null, null);
    return FutureBuilder<Json?>(
      future: _future,
      builder: (context, snap) => widget.builder(context, crdVersionSchema(snap.data, widget.version), crdVersionEntry(snap.data, widget.version)),
    );
  }
}
