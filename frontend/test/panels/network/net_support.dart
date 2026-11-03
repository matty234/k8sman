import 'dart:convert';
import 'dart:io';

import 'package:k8sman/api/models.dart';

/// Shared fixture from `dev/fixtures/`.
Json devFixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;

/// Area-local fixture from `test/panels/network/fixtures/`.
dynamic netFixture(String name) => jsonDecode(File('test/panels/network/fixtures/$name.json').readAsStringSync());

List<Json> demoPods() => [for (final p in netFixture('pods-demo') as List) Map<String, dynamic>.from(p)];

/// Equality-only label selector matcher (`a=b,c=d`) for FakeApiClient.itemsFilter.
bool selectorFilter(ResourceRef r, Json item, String? labelSelector, String? fieldSelector) {
  if (labelSelector == null || labelSelector.isEmpty) return true;
  final labels = (item['metadata']?['labels'] as Map?) ?? const {};
  for (final term in labelSelector.split(',')) {
    final kv = term.split('=');
    if (kv.length != 2 || labels[kv[0]]?.toString() != kv[1]) return false;
  }
  return true;
}
