import 'dart:convert';
import 'dart:io';

import 'package:k8sman/api/models.dart';

/// Shared fixture from `dev/fixtures/`.
Json devFixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;

/// Area-local fixture from `test/panels/network/fixtures/`.
dynamic netFixture(String name) => jsonDecode(File('test/panels/network/fixtures/$name.json').readAsStringSync());

List<Json> demoPods() => [for (final p in netFixture('pods-demo') as List) Map<String, dynamic>.from(p)];
