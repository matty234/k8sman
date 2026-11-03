import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';

const g = 'gateway.networking.k8s.io';

/// The shared test types plus the Gateway API kinds.
const gwTypes = <ResourceType>[
  ...testTypes,
  ResourceType(group: g, version: 'v1', resource: 'gatewayclasses', kind: 'GatewayClass', namespaced: false, custom: true),
  ResourceType(group: g, version: 'v1', resource: 'gateways', kind: 'Gateway', custom: true),
  ResourceType(group: g, version: 'v1', resource: 'httproutes', kind: 'HTTPRoute', custom: true),
  ResourceType(group: g, version: 'v1', resource: 'grpcroutes', kind: 'GRPCRoute', custom: true),
  ResourceType(group: g, version: 'v1alpha2', resource: 'tcproutes', kind: 'TCPRoute', custom: true),
  ResourceType(group: g, version: 'v1beta1', resource: 'referencegrants', kind: 'ReferenceGrant', custom: true),
  ResourceType(group: 'gateway.envoyproxy.io', version: 'v1alpha1', resource: 'envoyproxies', kind: 'EnvoyProxy', custom: true),
];

/// A fixture captured from the dev cluster (fresh copy each call).
dynamic gwFixtureRaw(String name) => jsonDecode(File('test/panels/gateway/fixtures/$name.json').readAsStringSync());
Json gwFixture(String name) => Map<String, dynamic>.from(gwFixtureRaw(name) as Map);

List<Json> routesNamed(List<String> names) => [for (final n in names) gwFixture(n)];

/// A FakeApiClient seeded with every captured Gateway API object, the demo
/// Services and the TLS Secret.
FakeApiClient gwApi({bool withGrant = true}) {
  final services = [for (final s in gwFixtureRaw('services-demo') as List) Map<String, dynamic>.from(s as Map)];
  final gateways = [gwFixture('gateway-demo-gw'), gwFixture('gateway-legacy-gw'), gwFixture('gateway-pending-gw')];
  final classes = [gwFixture('gatewayclass-eg'), gwFixture('gatewayclass-orphan')];
  final grants = withGrant ? [gwFixture('referencegrant-allow-gateway-demo-to-web')] : <Json>[];
  final objects = <String, Json>{
    for (final s in services) 'services/${s['metadata']['namespace']}/${s['metadata']['name']}': s,
    for (final gw in gateways) 'gateways.$g/${gw['metadata']['namespace']}/${gw['metadata']['name']}': gw,
    for (final c in classes) 'gatewayclasses.$g//${c['metadata']['name']}': c,
    'secrets/gateway-demo/demo-tls': gwFixture('secret-demo-tls'),
  };
  return FakeApiClient(
    itemsByResource: {
      'gateways.$g': gateways,
      'gatewayclasses.$g': classes,
      'httproutes.$g': routesNamed(['httproute-web-route', 'httproute-shop', 'httproute-cache-admin', 'httproute-admin-api', 'httproute-sneaky-admin', 'httproute-ghost']),
      'grpcroutes.$g': [gwFixture('grpcroute-greeter')],
      'tcproutes.$g': [gwFixture('tcproute-redis')],
      'referencegrants.$g': grants,
      'services': services,
      'namespaces': [
        {
          'metadata': {'name': 'demo', 'labels': {'kubernetes.io/metadata.name': 'demo'}},
        },
        {
          'metadata': {'name': 'gateway-demo', 'labels': {'kubernetes.io/metadata.name': 'gateway-demo', 'gateway-access': 'true'}},
        },
      ],
    },
    objects: objects,
  );
}

/// Like `pumpPanel`, but with the Gateway API types discovered so links
/// resolve and route kinds count as served.
Future<AppState> pumpGwPanel(WidgetTester tester, Json object, {ApiClient? api, Size size = const Size(560, 2400), List<ResourceType> types = gwTypes}) async {
  final apiVersion = '${object['apiVersion']}';
  final group = apiVersion.contains('/') ? apiVersion.split('/').first : '';
  final t = types.firstWhere((t) => t.group == group && t.kind == '${object['kind']}');
  final client = api ?? gwApi();
  final app = AppState(client)..types = types;
  final panel = panelFor(t);
  app.openDetail(DetailTarget(type: t, name: '${object['metadata']?['name']}', namespace: object['metadata']?['namespace']));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: AppColors.of(context).inspector,
          body: Builder(builder: (context) {
            final ctx = PanelContext(object: object, type: t, api: client, app: app);
            return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: panel.buildSections(context, ctx));
          }),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return app;
}
