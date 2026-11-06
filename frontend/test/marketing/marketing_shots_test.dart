/// Marketing screenshots for the README (docs/images/*.png).
///
/// Renders the full app shell headlessly against synthetic demo data at
/// 1440×900 logical px (2× device pixel ratio), inside a macOS-style window
/// frame on a gradient. Skipped unless K8SMAN_MARKETING is set:
///
///   tools/marketing-shots.sh            # renders + compresses into docs/images
///   K8SMAN_MARKETING=1 flutter test --tags marketing   # raw PNGs in build/marketing
@Tags(['marketing'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/main.dart';
import 'package:k8sman/modules/helm_module.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/panels/argocd/app_diff.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/column_editor.dart';
import 'package:k8sman/ui/detail/detail_sidebar.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/terminal/exec_protocol.dart';
import 'package:k8sman/ui/terminal/terminal_tab.dart';
import 'package:provider/provider.dart';

import '../panels/argocd/fake_argo_diff.dart';
import '../support/harness.dart' show matchesLabelSelector;
import '../support/screenshot.dart';
import '../terminal/fake_exec.dart' show FakeExecTransport;

final _enabled = Platform.environment['K8SMAN_MARKETING'] != null;

const _appSize = Size(1440, 900);
const _pixelRatio = 2.0;
const _padH = 96.0;
const _padV = 80.0;
const _canvas = Size(1440 + 2 * _padH, 900 + 2 * _padV);

/// Paths requested from the REST mock that it had no answer for.
final Set<String> unhandled = {};

// ---------------------------------------------------------------------------
// Demo data
// ---------------------------------------------------------------------------

const ctxName = 'prod-eu-west';

dynamic _readJson(String path) => jsonDecode(File(path).readAsStringSync());

/// Renames the dev-cluster identifiers in captured fixtures so every shot
/// reads like one cluster (prod-eu-west, namespace storefront).
dynamic scrub(dynamic j) {
  if (j is Map) return {for (final e in j.entries) '${scrub(e.key)}': scrub(e.value)};
  if (j is List) return [for (final x in j) scrub(x)];
  if (j is String) {
    if (j == 'demo') return 'storefront';
    return j
        .replaceAll('kind-k8sman-dev', ctxName)
        .replaceAll('security-demo', 'legacy-tools')
        .replaceAll('demo-team', 'web-team')
        .replaceAll('helm-demo', 'web')
        .replaceAll('helm-tools', 'tools')
        .replaceAll('k8sman-demo', 'storefront')
        .replaceAll('k8sman-dev-control-plane', 'ip-10-24-3-117')
        .replaceAll('_demo(', '_storefront(')
        .replaceAll('/demo/', '/storefront/');
  }
  return j;
}

final _iso = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$');

/// Moves every timestamp in [j] by [delta] so ages read naturally.
dynamic shiftTimes(dynamic j, Duration delta) {
  if (j is Map) return <String, dynamic>{for (final e in j.entries) '${e.key}': shiftTimes(e.value, delta)};
  if (j is List) return [for (final x in j) shiftTimes(x, delta)];
  if (j is String && _iso.hasMatch(j)) return DateTime.parse(j).add(delta).toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
  return j;
}

/// The fixtures were captured on 2026-11-03 around 11:20–12:45 UTC; treat
/// 12:50 that day as "now".
final _fixtureNow = DateTime.utc(2026, 11, 3, 12, 50);
Duration get _delta => DateTime.now().toUtc().difference(_fixtureNow);

/// A fixture, scrubbed and time-shifted.
dynamic demo(String path) => shiftTimes(scrub(_readJson(path)), _delta);

String ago(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

// ---------------------------------------------------------------------------
// Fake backend
// ---------------------------------------------------------------------------

class MarketingApi extends ApiClient {
  MarketingApi({super.httpClient}) : super(base: Uri.parse('http://fake'));

  static const appType = ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'applications', kind: 'Application', custom: true);

  static final List<ResourceType> types = [
    for (final r in _readJson('../dev/fixtures/api-resources.json')) ResourceType.fromJson(r),
    appType,
    const ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'applicationsets', kind: 'ApplicationSet', custom: true),
    const ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'appprojects', kind: 'AppProject', custom: true),
  ];

  @override
  Future<ColumnsConfig> getColumns(ResourceRef r) async =>
      ColumnsConfig(columns: Demo.customPodColumns, defaults: Demo._podColumns, isDefault: false);

  @override
  Future<List<PortForward>> portForwards() async => const [];

  @override
  Future<TableData> previewColumns(ResourceRef r, List<ColumnDef> cols, {String? namespace, int limit = 25}) async => Demo.preview(cols, namespace);

  @override
  Future<Map<String, dynamic>> health() async => {'readOnly': false};

  @override
  Future<({String current, List<ContextInfo> contexts, Map<String, String> readOnly})> contexts() async => (
        current: ctxName,
        readOnly: const <String, String>{},
        contexts: const [
          ContextInfo(name: ctxName, cluster: ctxName, user: 'sre'),
          ContextInfo(name: 'staging-eu-west', cluster: 'staging-eu-west', user: 'sre'),
          ContextInfo(name: 'kind-k8sman-dev', cluster: 'kind-k8sman-dev', user: 'kind-k8sman-dev'),
        ],
      );

  @override
  Future<List<ResourceType>> resources({bool refresh = false}) async => types;

  @override
  Future<({List<String> namespaces, String? defaultNamespace})> namespaces() async => (
        namespaces: const ['argocd', 'checkout', 'default', 'kube-system', 'monitoring', 'payments', 'platform', 'storefront'],
        defaultNamespace: 'storefront',
      );

  ResourceType _type(ResourceRef r) => types.firstWhere((t) => t.group == r.group && t.resource == r.resource);

  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) {
    final t = _type(r);
    if (fieldSelector != null) {
      final name = fieldSelector.split('=').last;
      final o = Demo.object(r.key, name);
      return Stream.value(WatchMessage(
        type: 'SNAPSHOT',
        table: TableData(
          resource: t,
          columns: const [],
          isDefaultColumns: true,
          resourceVersion: '1',
          rows: [if (o != null) TableRowData(uid: 'x', name: name, namespace: namespace, resourceVersion: '1', cells: const [], object: o)],
        ),
      ));
    }
    final table = Demo.table(t, namespace);
    return Stream.value(WatchMessage(type: 'SNAPSHOT', table: table));
  }

  @override
  Future<Json> object(ResourceRef r, {String? namespace, required String name}) async {
    final o = Demo.object(r.key, name);
    if (o == null) throw ApiException(404, 'not found');
    return o;
  }

  @override
  Future<List<Json>> items(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector}) async => switch (r.key) {
        'nodes' => Demo.nodes(),
        _ when namespace == 'helm-guestbook' => Demo.helmGuestbookLive(r.key),
        'pods' when namespace == 'guestbook' || namespace == 'guestbook-degraded' => Demo.argoLive('pods', namespace, labelSelector),
        'pods' => [for (final p in Demo.podObjects()) if (namespace == null || p['metadata']['namespace'] == namespace) p],
        'applications.argoproj.io' => Demo.argoApps(),
        'deployments.apps' || 'replicasets.apps' || 'services' => Demo.argoLive(r.key, namespace, labelSelector),
        _ => [],
      };

  @override
  Future<List<Json>> events({String? namespace, String? uid, String? kind, String? name}) async => [];

  @override
  Future<String> objectYaml(ResourceRef r, {String? namespace, required String name, bool managedFields = false}) async => 'kind: Pod';

  @override
  Stream<LogMessage> logs({
    required String namespace,
    required String pod,
    String? container,
    int tailLines = 500,
    bool previous = false,
    bool follow = true,
    bool timestamps = false,
    int? sinceSeconds,
  }) {
    final c = StreamController<LogMessage>();
    for (final l in Demo.logLines(pod, container ?? '', previous: previous)) {
      c.add(LogMessage(line: l));
    }
    if (previous || !follow) c.add(const LogMessage(eof: true));
    return c.stream;
  }
}

/// REST endpoints the typed per-area clients call (overview, security,
/// helm, metrics, prom, …), served from fixtures.
Future<http.Response> restHandler(http.Request req) async {
  final p = req.url.path.replaceFirst('/api/', '');
  final q = req.url.queryParameters;
  final body = Demo.rest(req.method, p, q);
  if (body == null) {
    unhandled.add('${req.method} ${req.url}');
    return http.Response(jsonEncode({'error': 'not found'}), 404, headers: {'content-type': 'application/json'});
  }
  return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
}

class Demo {
  static final _podColumns = [for (final c in _readJson('../dev/fixtures/api-table-pods.json')['columns']) ColumnDef.fromJson(c)];

  static const _crashPod = 'checkout-api-7c9f5d8b6-m4p7z';

  /// Pods across the cluster: (name, ns, ready, status, restarts, node, ip, age).
  static final _pods = <(String, String, String, String, int, String, String, Duration)>[
    ('checkout-api-7c9f5d8b6-2xkq1', 'checkout', '1/1', 'Running', 0, 'ip-10-24-3-117', '10.244.3.21', const Duration(hours: 3, minutes: 12)),
    (_crashPod, 'checkout', '0/1', 'CrashLoopBackOff', 7, 'ip-10-24-5-42', '10.244.5.17', const Duration(minutes: 14)),
    ('checkout-worker-5d8c9b7f4-hx2lp', 'checkout', '1/1', 'Running', 0, 'ip-10-24-1-9', '10.244.1.33', const Duration(days: 2, hours: 4)),
    ('db-migrate-29371845-qk7tz', 'checkout', '0/1', 'Completed', 0, 'ip-10-24-1-9', '10.244.1.40', const Duration(hours: 3, minutes: 14)),
    ('payments-gateway-6b7d9c5f8-8wz4m', 'payments', '2/2', 'Running', 0, 'ip-10-24-5-42', '10.244.5.9', const Duration(days: 5, hours: 2)),
    ('payments-gateway-6b7d9c5f8-vt9rn', 'payments', '2/2', 'Running', 1, 'ip-10-24-3-117', '10.244.3.8', const Duration(days: 5, hours: 2)),
    ('ledger-0', 'payments', '1/1', 'Running', 0, 'ip-10-24-1-9', '10.244.1.12', const Duration(days: 12)),
    ('ledger-1', 'payments', '1/1', 'Running', 0, 'ip-10-24-5-42', '10.244.5.13', const Duration(days: 12)),
    ('fraud-scorer-84f6d7c9b-r2x5k', 'payments', '0/1', 'ImagePullBackOff', 0, 'ip-10-24-3-117', '10.244.3.30', const Duration(minutes: 6)),
    ('redis-0', 'storefront', '1/1', 'Running', 0, 'ip-10-24-3-117', '10.244.3.12', const Duration(days: 9)),
    ('web-6fd47b8fcb-4v4m9', 'storefront', '2/2', 'Running', 0, 'ip-10-24-1-9', '10.244.1.5', const Duration(days: 1, hours: 6)),
    ('web-6fd47b8fcb-z7wpf', 'storefront', '2/2', 'Running', 0, 'ip-10-24-5-42', '10.244.5.6', const Duration(days: 1, hours: 6)),
    ('web-6fd47b8fcb-q8n2d', 'storefront', '2/2', 'Running', 0, 'ip-10-24-3-117', '10.244.3.6', const Duration(days: 1, hours: 6)),
    ('search-indexer-28371900-7lm2c', 'storefront', '0/1', 'Completed', 0, 'ip-10-24-1-9', '10.244.1.44', const Duration(minutes: 38)),
    ('image-resizer-9c7b6d5f4-jw8kt', 'storefront', '1/1', 'Running', 3, 'ip-10-24-5-42', '10.244.5.25', const Duration(days: 3, hours: 1)),
    ('coredns-7db6d8ff4d-5xk2p', 'kube-system', '1/1', 'Running', 0, 'ip-10-24-1-9', '10.244.1.2', const Duration(days: 41)),
    ('coredns-7db6d8ff4d-h9t4w', 'kube-system', '1/1', 'Running', 0, 'ip-10-24-3-117', '10.244.3.2', const Duration(days: 41)),
    ('prometheus-k8s-0', 'monitoring', '2/2', 'Running', 0, 'ip-10-24-5-42', '10.244.5.3', const Duration(days: 18)),
    ('grafana-6c8f9b7d5-p4z8x', 'monitoring', '1/1', 'Running', 0, 'ip-10-24-1-9', '10.244.1.7', const Duration(days: 18)),
    ('argocd-server-7f8d9c6b5-xk2m9', 'argocd', '1/1', 'Running', 0, 'ip-10-24-3-117', '10.244.3.4', const Duration(days: 27)),
  ];

  static TableData table(ResourceType t, String? namespace) {
    if (t.resource == 'applications') return appsTable(t);
    if (t.resource == 'pods') {
      return TableData(
        resource: t,
        columns: _podColumns,
        isDefaultColumns: true,
        resourceVersion: '1',
        rows: [
          for (final p in _pods)
            if (namespace == null || p.$2 == namespace)
              TableRowData(
                uid: 'uid-${p.$1}',
                name: p.$1,
                namespace: p.$2,
                resourceVersion: '1',
                cells: [p.$1, p.$2, p.$3, p.$4, p.$5, p.$6, p.$7, ago(p.$8)],
                controlled: true,
              ),
        ],
      );
    }
    return TableData(resource: t, columns: const [], isDefaultColumns: true, resourceVersion: '1', rows: const []);
  }

  static Json crashPod() {
    final o = Map<String, dynamic>.from(demo('../dev/fixtures/pod-crashy.json') as Map);
    final meta = Map<String, dynamic>.from(o['metadata'] as Map)
      ..remove('annotations')
      ..['name'] = _crashPod
      ..['namespace'] = 'checkout'
      ..['generateName'] = 'checkout-api-7c9f5d8b6-'
      ..['labels'] = {'app': 'checkout-api', 'pod-template-hash': '7c9f5d8b6', 'tier': 'backend'}
      ..['creationTimestamp'] = ago(const Duration(minutes: 14))
      ..['ownerReferences'] = [
        {'apiVersion': 'apps/v1', 'kind': 'ReplicaSet', 'name': 'checkout-api-7c9f5d8b6', 'uid': 'rs-1', 'controller': true, 'blockOwnerDeletion': true},
      ];
    o['metadata'] = meta;
    final spec = Map<String, dynamic>.from(o['spec'] as Map);
    spec['nodeName'] = 'ip-10-24-5-42';
    spec['serviceAccountName'] = 'checkout-api';
    spec['containers'] = [
      {
        'name': 'api',
        'image': 'ghcr.io/example/checkout-api:2.14.1',
        'ports': [
          {'containerPort': 8080, 'name': 'http', 'protocol': 'TCP'},
        ],
        'env': [
          {'name': 'LOG_LEVEL', 'value': 'info'},
          {
            'name': 'DATABASE_URL',
            'valueFrom': {
              'secretKeyRef': {'name': 'checkout-db', 'key': 'url'},
            },
          },
          {
            'name': 'PAYMENT_GATEWAY_URL',
            'valueFrom': {
              'configMapKeyRef': {'name': 'checkout-config', 'key': 'gateway_url'},
            },
          },
        ],
        'readinessProbe': {
          'httpGet': {'path': '/healthz', 'port': 'http'},
          'periodSeconds': 5,
        },
        'resources': {
          'requests': {'cpu': '100m', 'memory': '128Mi'},
          'limits': {'cpu': '500m', 'memory': '256Mi'},
        },
      },
    ];
    o['spec'] = spec;
    final status = Map<String, dynamic>.from(o['status'] as Map);
    status['podIP'] = '10.244.5.17';
    status['podIPs'] = [
      {'ip': '10.244.5.17'},
    ];
    status['hostIP'] = '10.24.5.42';
    status['startTime'] = ago(const Duration(minutes: 14));
    status['qosClass'] = 'Burstable';
    status['conditions'] = [
      for (final c in status['conditions'] as List) {...(c as Map), 'lastTransitionTime': ago(const Duration(minutes: 14)), if (c['message'] != null) 'message': 'containers with unready status: [api]'},
    ];
    status['containerStatuses'] = [
      {
        'name': 'api',
        'image': 'ghcr.io/example/checkout-api:2.14.1',
        'imageID': 'ghcr.io/example/checkout-api@sha256:4be1c5d0e2f3a7b9c8d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4',
        'ready': false,
        'started': false,
        'restartCount': 7,
        'lastState': {
          'terminated': {
            'exitCode': 1,
            'reason': 'Error',
            'message': 'fatal: required config PAYMENT_GATEWAY_URL is empty',
            'startedAt': ago(const Duration(minutes: 2, seconds: 8)),
            'finishedAt': ago(const Duration(minutes: 2, seconds: 6)),
          },
        },
        'state': {
          'waiting': {'reason': 'CrashLoopBackOff', 'message': 'back-off 5m0s restarting failed container=api pod=${_crashPod}_checkout(327d9fb7-7696-4c09-a53a-779f7986e5fc)'},
        },
      },
    ];
    o['status'] = status;
    return o;
  }

  static Json webPod(String name) {
    final o = Map<String, dynamic>.from(demo('../dev/fixtures/pod-web.json') as Map);
    final row = _pods.firstWhere((p) => p.$1 == name);
    o['metadata'] = {...(o['metadata'] as Map), 'name': name};
    o['spec'] = {...(o['spec'] as Map), 'nodeName': row.$6};
    o['status'] = {
      ...(o['status'] as Map),
      'podIP': row.$7,
      'podIPs': [
        {'ip': row.$7},
      ],
      'hostIP': row.$6.replaceFirst('ip-', '').replaceAll('-', '.'),
    };
    // The fixture pod started ~1h27m before "now"; make it as old as its row.
    return Map<String, dynamic>.from(shiftTimes(o, const Duration(hours: 1, minutes: 27) - row.$8) as Map);
  }

  static Json? object(String key, String name) {
    if (key == 'pods' && name == _crashPod) return crashPod();
    if (key == 'pods' && name.startsWith('web-')) return webPod(name);
    if (key == 'applications.argoproj.io') return argoApps().where((a) => a['metadata']['name'] == name).firstOrNull;
    return null;
  }

  static const _nodeNames = ['ip-10-24-1-9', 'ip-10-24-3-117', 'ip-10-24-5-42', 'ip-10-24-7-201', 'ip-10-24-2-58', 'ip-10-24-6-13'];

  /// Usage per pod (cpu millis, memory MiB), stable per name.
  static (int, int) _usage(String name) {
    final h = name.codeUnits.fold(7, (a, b) => (a * 31 + b) & 0xffff);
    if (name.startsWith('web-')) return (14 + h % 20, 22 + h % 8);
    return (4 + h % 180, 24 + h % 400);
  }

  static Json podMetrics(String? namespace) => {
        'items': [
          for (final p in _pods)
            if ((namespace == null || p.$2 == namespace) && p.$4 != 'Completed' && p.$4 != 'ImagePullBackOff')
              () {
                final (cpu, mem) = _usage(p.$1);
                return {
                  'name': p.$1,
                  'namespace': p.$2,
                  'timestamp': ago(const Duration(seconds: 20)),
                  'window': '20s',
                  'cpu': '${cpu}m',
                  'memory': '${mem * 1048576}',
                  'cpuMillis': cpu,
                  'memoryBytes': mem * 1048576,
                  'containers': [
                    {'name': 'main', 'cpu': '${cpu}m', 'memory': '${mem * 1048576}', 'cpuMillis': cpu, 'memoryBytes': mem * 1048576},
                  ],
                };
              }(),
        ],
      };

  static Json nodeMetrics() => {
        'items': [
          for (final (i, n) in _nodeNames.indexed)
            {
              'name': n,
              'timestamp': ago(const Duration(seconds: 20)),
              'window': '20s',
              'cpu': '${[2410, 5120, 6890, 1180, 9340, 3720][i]}m',
              'memory': '${[9, 17, 22, 6, 31, 14][i] * 1073741824}',
              'cpuMillis': [2410, 5120, 6890, 1180, 9340, 3720][i],
              'memoryBytes': [9, 17, 22, 6, 31, 14][i] * 1073741824,
            },
        ],
      };

  static List<Json> nodes() {
    final base = demo('../dev/fixtures/node-k8sman-dev-control-plane.json') as Map;
    return [
      for (final (i, n) in _nodeNames.indexed)
        () {
          final o = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
          final zone = ['eu-west-1a', 'eu-west-1b', 'eu-west-1c', 'eu-west-1a', 'eu-west-1b', 'eu-west-1c'][i];
          o['metadata']['name'] = n;
          o['metadata']['creationTimestamp'] = ago(Duration(days: [41, 41, 23, 2, 16, 9][i]));
          o['metadata']['labels'] = {
            'kubernetes.io/hostname': n,
            'kubernetes.io/arch': 'amd64',
            'kubernetes.io/os': 'linux',
            'node.kubernetes.io/instance-type': i == 3 ? 'm7i.2xlarge' : 'm7i.4xlarge',
            'topology.kubernetes.io/zone': zone,
            if (i == 0) 'node-role.kubernetes.io/control-plane': '',
          };
          final cap = {'cpu': i == 3 ? '8' : '16', 'memory': i == 3 ? '32505856Ki' : '65011712Ki', 'pods': '110', 'ephemeral-storage': '209702892Ki'};
          o['status']['capacity'] = cap;
          o['status']['allocatable'] = {...cap, 'cpu': i == 3 ? '7910m' : '15890m', 'memory': i == 3 ? '31408128Ki' : '63913984Ki'};
          o['status']['addresses'] = [
            {'type': 'InternalIP', 'address': n.replaceFirst('ip-', '').replaceAll('-', '.')},
            {'type': 'Hostname', 'address': n},
          ];
          o['status']['nodeInfo'] = {...(o['status']['nodeInfo'] as Map), 'architecture': 'amd64', 'kubeletVersion': 'v1.31.4', 'osImage': 'Bottlerocket OS 1.29.0 (aws-k8s-1.31)'};
          if (i == 3) {
            o['spec'] = {'unschedulable': true};
          }
          if (i == 2) {
            for (final c in o['status']['conditions'] as List) {
              if (c['type'] == 'MemoryPressure') {
                c['status'] = 'True';
                c['reason'] = 'KubeletHasInsufficientMemory';
                c['message'] = 'kubelet has insufficient memory available';
              }
            }
          }
          return o;
        }(),
    ];
  }

  /// Pod objects with requests, spread over the nodes (for the Nodes page).
  static List<Json> podObjects() => [
        for (final (i, p) in _pods.indexed)
          {
            'apiVersion': 'v1',
            'kind': 'Pod',
            'metadata': {'name': p.$1, 'namespace': p.$2, 'uid': 'uid-${p.$1}', 'creationTimestamp': ago(p.$8)},
            'spec': {
              'nodeName': const ['ip-10-24-1-9', 'ip-10-24-3-117', 'ip-10-24-5-42', 'ip-10-24-2-58', 'ip-10-24-6-13'][i % 5],
              'containers': [
                {
                  'name': 'main',
                  'image': 'example/${p.$1.split('-').first}:1.0',
                  'resources': {
                    'requests': {'cpu': '${[250, 500, 1000, 200, 750][i % 5] * 2}m', 'memory': '${[512, 1024, 2048, 256, 1536][i % 5] * 2}Mi'},
                    'limits': {'cpu': '${[500, 1000, 2000, 400, 1500][i % 5] * 2}m', 'memory': '${[1024, 2048, 4096, 512, 3072][i % 5] * 2}Mi'},
                  },
                },
              ],
            },
            'status': {'phase': p.$4 == 'Completed' ? 'Succeeded' : 'Running'},
          },
      ];

  // ---- Argo CD ----

  static const _argoDir = 'test/panels/argocd/fixtures';
  static const _apps = ['helm-guestbook-drift', 'guestbook', 'guestbook-degraded', 'guestbook-dev', 'guestbook-staging', 'multi-source', 'kustomize-guestbook', 'bad-path'];

  static List<Json> argoApps() => [for (final a in _apps) Map<String, dynamic>.from(demo('$_argoDir/app-$a.json') as Map)];

  static List<Json> argoLive(String key, String? namespace, String? labelSelector) {
    final kind = switch (key) { 'deployments.apps' => 'deployments', 'replicasets.apps' => 'replicasets', 'services' => 'services', _ => 'pods' };
    return [
      for (final f in ['live-guestbook-$kind.json', 'live-guestbook-degraded-$kind.json'])
        for (final o in demo('$_argoDir/$f') as List)
          if ((namespace == null || o['metadata']['namespace'] == namespace) && matchesLabelSelector(o as Json, labelSelector)) o,
    ];
  }

  /// Live objects of the drifted helm-guestbook app (scaled to 3 by hand).
  static List<Json> helmGuestbookLive(String key) {
    Json meta(String name, String uid) => {'name': name, 'namespace': 'helm-guestbook', 'uid': uid, 'creationTimestamp': ago(const Duration(days: 12))};
    return switch (key) {
      'deployments.apps' => [
          {
            'apiVersion': 'apps/v1',
            'kind': 'Deployment',
            'metadata': {...meta('helm-guestbook', 'hg-dep'), 'generation': 4},
            'spec': {
              'replicas': 3,
              'selector': {
                'matchLabels': {'app': 'helm-guestbook'},
              },
            },
            'status': {
              'observedGeneration': 4,
              'replicas': 3,
              'readyReplicas': 3,
              'updatedReplicas': 3,
              'availableReplicas': 3,
              'conditions': [
                {'type': 'Available', 'status': 'True', 'reason': 'MinimumReplicasAvailable'},
                {'type': 'Progressing', 'status': 'True', 'reason': 'NewReplicaSetAvailable'},
              ],
            },
          },
        ],
      'services' => [
          {
            'apiVersion': 'v1',
            'kind': 'Service',
            'metadata': meta('helm-guestbook', 'hg-svc'),
            'spec': {
              'type': 'ClusterIP',
              'clusterIP': '10.96.41.7',
              'ports': [
                {'port': 80, 'targetPort': 80, 'protocol': 'TCP'},
              ],
            },
          },
        ],
      'configmaps' => [
          {
            'apiVersion': 'v1',
            'kind': 'ConfigMap',
            'metadata': meta('legacy-settings', 'hg-cm'),
            'data': {'MODE': 'legacy'},
          },
        ],
      _ => [],
    };
  }

  static TableData appsTable(ResourceType t) {
    final cols = [
      const ColumnDef(name: 'Name', query: '.metadata.name'),
      const ColumnDef(name: 'Project', query: '.spec.project'),
      const ColumnDef(name: 'Sync', query: '.status.sync.status', type: 'status'),
      const ColumnDef(name: 'Health', query: '.status.health.status', type: 'status'),
      const ColumnDef(name: 'Destination', query: '.spec.destination.namespace'),
      const ColumnDef(name: 'Age', query: '.metadata.creationTimestamp', type: 'age'),
    ];
    final ages = [const Duration(days: 12), const Duration(days: 34), const Duration(days: 3), const Duration(days: 21), const Duration(days: 21), const Duration(hours: 5), const Duration(minutes: 40), const Duration(days: 8)];
    return TableData(
      resource: t,
      columns: cols,
      isDefaultColumns: true,
      resourceVersion: '1',
      rows: [
        for (final (i, a) in argoApps().indexed)
          TableRowData(
            uid: 'app-$i',
            name: a['metadata']['name'],
            namespace: 'argocd',
            resourceVersion: '1',
            cells: [
              a['metadata']['name'],
              a['spec']['project'],
              a['status']?['sync']?['status'] ?? 'Unknown',
              a['status']?['health']?['status'] ?? 'Unknown',
              a['spec']?['destination']?['namespace'] ?? '',
              ago(ages[i]),
            ],
          ),
      ],
    );
  }

  // ---- custom columns ----

  static final customPodColumns = [
    const ColumnDef(name: 'Name', query: '.metadata.name'),
    const ColumnDef(name: 'Namespace', query: '.metadata.namespace'),
    const ColumnDef(name: 'Status', query: '.status.phase', type: 'status'),
    const ColumnDef(name: 'Image', query: '.spec.containers[0].image | split("/") | last'),
    const ColumnDef(name: 'CPU req', query: '[.spec.containers[].resources.requests.cpu // "0"] | first', type: 'quantity'),
    const ColumnDef(name: 'Node', query: '.spec.nodeName'),
    const ColumnDef(name: 'Age', query: '.metadata.creationTimestamp', type: 'age'),
  ];

  static TableData preview(List<ColumnDef> cols, String? namespace) {
    const t = ResourceType(group: '', version: 'v1', resource: 'pods', kind: 'Pod');
    final objs = podObjects();
    String cell(ColumnDef c, Json o, (String, String, String, String, int, String, String, Duration) p) => switch (c.name) {
          'Name' => p.$1,
          'Namespace' => p.$2,
          'Status' => p.$4,
          'Image' => () {
              final base = p.$1.replaceFirst(RegExp(r'(-[a-z0-9]{8,10})?-[a-z0-9]{5}$|-\d+$'), '');
              return base == 'checkout-api' ? 'checkout-api:2.14.1' : '$base:${1 + base.length % 3}.${base.length % 9}.${base.codeUnitAt(0) % 5}';
            }(),
          'CPU req' => '${o['spec']['containers'][0]['resources']['requests']['cpu']}',
          'Node' => p.$6,
          'Age' => ago(p.$8),
          'Ready' => p.$3,
          'Restarts' => '${p.$5}',
          'IP' => p.$7,
          _ => '',
        };
    return TableData(
      resource: t,
      columns: cols,
      isDefaultColumns: false,
      resourceVersion: '1',
      rows: [
        for (final (i, p) in _pods.indexed)
          if (namespace == null || p.$2 == namespace)
            TableRowData(uid: 'p$i', name: p.$1, namespace: p.$2, resourceVersion: '1', cells: [for (final c in cols) cell(c, objs[i], p)]),
      ],
    );
  }

  // ---- overview ----

  static Json overview() => {
        'generatedAt': ago(const Duration(seconds: 4)),
        'namespace': '',
        'counts': {
          'pods': {'total': 64, 'running': 58, 'ready': 56, 'pending': 1, 'crashLoop': 1, 'imagePull': 1, 'oomKilled': 1, 'highRestarts': 2, 'completed': 4, 'notReady': 1},
          'deployments': {'total': 18, 'healthy': 16, 'unavailable': 1, 'progressDeadlineExceeded': 1},
          'statefulSets': {'total': 4, 'healthy': 4},
          'daemonSets': {'total': 5, 'healthy': 5},
          'jobs': {'total': 9, 'succeeded': 8, 'failed': 1},
          'cronJobs': {'total': 4, 'failing': 1},
          'nodes': {'total': 4, 'ready': 4, 'pressure': 1, 'cordoned': 1},
          'pvcs': {'total': 7, 'bound': 7},
        },
        'categories': [
          {'id': 'crashLoop', 'label': 'CrashLoopBackOff', 'section': 'pods', 'severity': 'critical', 'count': 1},
          {'id': 'imagePull', 'label': 'Image pull errors', 'section': 'pods', 'severity': 'critical', 'count': 1},
          {'id': 'oomKilled', 'label': 'OOMKilled (1h)', 'section': 'pods', 'severity': 'critical', 'count': 1},
          {'id': 'progressDeadlineExceeded', 'label': 'Rollouts stalled', 'section': 'workloads', 'severity': 'critical', 'count': 1},
          {'id': 'cronJobFailing', 'label': 'CronJobs failing', 'section': 'jobs', 'severity': 'critical', 'count': 1},
          {'id': 'nodePressure', 'label': 'Node pressure', 'section': 'nodes', 'severity': 'warning', 'count': 1},
          {'id': 'nodeCordoned', 'label': 'Nodes cordoned', 'section': 'nodes', 'severity': 'info', 'count': 1},
        ],
        'issues': [
          {
            'severity': 'critical', 'category': 'progressDeadlineExceeded', 'kind': 'Deployment', 'group': 'apps', 'namespace': 'checkout', 'name': 'checkout-api',
            'reason': 'ProgressDeadlineExceeded', 'message': 'ReplicaSet "checkout-api-7c9f5d8b6" has timed out progressing; 1/2 updated, 1 available', 'since': ago(const Duration(minutes: 9)),
          },
          {
            'severity': 'critical', 'category': 'crashLoop', 'kind': 'Pod', 'group': '', 'namespace': 'checkout', 'name': _crashPod, 'reason': 'CrashLoopBackOff',
            'message': 'container api last terminated: exit 1, Error; 7 restarts', 'since': ago(const Duration(minutes: 14)), 'count': 7,
            'owner': {'group': 'apps', 'kind': 'Deployment', 'name': 'checkout-api'},
          },
          {
            'severity': 'critical', 'category': 'imagePull', 'kind': 'Pod', 'group': '', 'namespace': 'payments', 'name': 'fraud-scorer-84f6d7c9b-r2x5k', 'reason': 'ImagePullBackOff',
            'message': 'container scorer, image ghcr.io/example/fraud-scorer:3.2.0-rc1: manifest unknown', 'since': ago(const Duration(minutes: 6)),
            'owner': {'group': 'apps', 'kind': 'Deployment', 'name': 'fraud-scorer'},
          },
          {
            'severity': 'critical', 'category': 'oomKilled', 'kind': 'Pod', 'group': '', 'namespace': 'storefront', 'name': 'image-resizer-9c7b6d5f4-jw8kt', 'reason': 'OOMKilled',
            'message': 'container resizer was OOMKilled 22m ago; memory limit 512Mi', 'since': ago(const Duration(minutes: 22)), 'count': 3,
            'owner': {'group': 'apps', 'kind': 'Deployment', 'name': 'image-resizer'},
          },
          {
            'severity': 'critical', 'category': 'cronJobFailing', 'kind': 'CronJob', 'group': 'batch', 'namespace': 'storefront', 'name': 'sitemap-export', 'reason': 'BackoffLimitExceeded',
            'message': 'last 3 runs failed: Job has reached the specified backoff limit', 'since': ago(const Duration(hours: 2)),
          },
          {
            'severity': 'warning', 'category': 'nodePressure', 'kind': 'Node', 'group': '', 'name': 'ip-10-24-5-42', 'reason': 'MemoryPressure',
            'message': 'kubelet has insufficient memory available', 'since': ago(const Duration(minutes: 31)),
          },
        ],
        'nodes': [
          {'name': 'ip-10-24-1-9', 'ready': true, 'roles': ['control-plane'], 'version': 'v1.31.4', 'pods': 21},
          {'name': 'ip-10-24-3-117', 'ready': true, 'roles': ['worker'], 'version': 'v1.31.4', 'pods': 24},
          {'name': 'ip-10-24-5-42', 'ready': true, 'pressure': ['MemoryPressure'], 'roles': ['worker'], 'version': 'v1.31.4', 'pods': 19},
          {'name': 'ip-10-24-7-201', 'ready': true, 'cordoned': true, 'roles': ['worker'], 'version': 'v1.31.4', 'pods': 0},
        ],
        'topWarnings': [
          {
            'reason': 'BackOff', 'count': 42, 'objects': 1, 'latestMessage': 'Back-off restarting failed container api in pod $_crashPod', 'lastSeen': ago(const Duration(minutes: 1)),
            'example': {'kind': 'Pod', 'group': '', 'namespace': 'checkout', 'name': _crashPod},
          },
          {
            'reason': 'Unhealthy', 'count': 18, 'objects': 3, 'latestMessage': 'Readiness probe failed: HTTP probe failed with statuscode: 503', 'lastSeen': ago(const Duration(minutes: 3)),
            'example': {'kind': 'Pod', 'group': '', 'namespace': 'storefront', 'name': 'web-6fd47b8fcb-q8n2d'},
          },
          {
            'reason': 'Failed', 'count': 9, 'objects': 1, 'latestMessage': 'Failed to pull image "ghcr.io/example/fraud-scorer:3.2.0-rc1": not found', 'lastSeen': ago(const Duration(minutes: 5)),
            'example': {'kind': 'Pod', 'group': '', 'namespace': 'payments', 'name': 'fraud-scorer-84f6d7c9b-r2x5k'},
          },
          {
            'reason': 'EvictionThresholdMet', 'count': 4, 'objects': 1, 'latestMessage': 'Attempting to reclaim memory', 'lastSeen': ago(const Duration(minutes: 31)),
            'example': {'kind': 'Node', 'group': '', 'name': 'ip-10-24-5-42'},
          },
        ],
      };

  static String _fx(String rel) => 'test/$rel';

  /// Spreads Helm history over days instead of the minutes it was captured in.
  static dynamic _helmTimes(dynamic j) {
    if (j is Map) {
      final m = {for (final e in j.entries) e.key: _helmTimes(e.value)};
      if (m['revision'] is int && m['updated'] is String) {
        final rev = m['revision'] as int;
        m['updated'] = ago(Duration(days: (6 - rev) * 3, hours: 2 + rev));
      }
      return m;
    }
    if (j is List) return [for (final x in j) _helmTimes(x)];
    return j;
  }

  static dynamic helm(String file) => _helmTimes(scrub(_readJson(_fx('helm/fixtures/$file'))));

  static Object? rest(String method, String path, Map<String, String> q) {
    switch (path) {
      case 'metrics/status':
        return demo(_fx('metrics/fixtures/status.json'));
      case 'metrics/pods':
        return podMetrics(q['namespace']);
      case 'metrics/nodes':
        return nodeMetrics();
      case 'prom/status':
        return {'prometheus': [], 'alertmanager': []};
      case 'overview':
        return overview();
      case 'security':
        return demo(_fx('security/fixtures/security.json'));
      case 'security/scanner':
        return demo(_fx('security/fixtures/scanner.json'));
      case 'helm/releases':
        return helm('releases.json');
      case 'helm/release':
        final f = {'web': 'release-web.json', 'api': 'release-api.json', 'worker': 'release-worker.json'}[q['name']];
        return f == null ? null : helm(f);
      case 'helm/history':
        final f = {'web': 'history-web.json', 'api': 'history-api.json', 'worker': 'history-worker.json'}[q['name']];
        return f == null ? null : helm(f);
      case 'helm/diff':
        return helm('diff-web-3-5.json');
      case 'rbac/subjects':
        return demo(_fx('access/fixtures/subjects.json'));
      case 'rbac/matrix':
        return demo(_fx('access/fixtures/matrix-app.json'));
      case 'rbac/who-can':
        return demo(_fx('access/fixtures/whocan-secrets.json'));
      case 'rbac/self':
        return demo(_fx('access/fixtures/self.json'));
      case 'rbac/resources':
        return {'resources': [], 'virtual': []};
    }
    return null;
  }

  static List<String> logLines(String pod, String container, {bool previous = false}) {
    final now = DateTime.now().toUtc();
    String ts(int s) => now.subtract(Duration(seconds: s)).toIso8601String().substring(0, 19);
    if (pod == _crashPod) {
      return [
        '${ts(128)}Z INFO  checkout-api 2.14.1 starting (go1.24.2, linux/amd64)',
        '${ts(128)}Z INFO  loading config from /etc/checkout/config.yaml',
        '${ts(127)}Z INFO  connected to postgres checkout-db.checkout.svc:5432 (pool=20)',
        '${ts(127)}Z INFO  redis: connected to redis-0.redis.storefront.svc:6379',
        '${ts(127)}Z WARN  feature flag "express-checkout" not found, defaulting to off',
        '${ts(126)}Z ERROR config: PAYMENT_GATEWAY_URL is empty (configMapKeyRef checkout-config/gateway_url)',
        '${ts(126)}Z ERROR payments client init failed: missing gateway URL',
        'fatal: required config PAYMENT_GATEWAY_URL is empty',
      ];
    }
    return [
      for (var i = 0; i < 80; i++)
        switch (i % 11) {
          4 => '${ts(240 - i * 3)}Z [error] upstream timed out (110: Connection timed out) while reading response header from upstream, upstream: "http://10.96.14.2:8080/api/cart"',
          8 => '${ts(240 - i * 3)}Z [warn] an upstream response is buffered to a temporary file /var/cache/nginx/proxy_temp/4/0$i',
          _ => '10.244.${i % 5}.${i % 7 + 10} - - "GET /${i.isEven ? 'healthz' : 'api/products?page=${i % 9 + 1}'} HTTP/1.1" 200 ${612 + i * 7} "-" "${i.isEven ? 'kube-probe/1.31' : 'Mozilla/5.0'}"',
        },
    ];
  }
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

/// A macOS-style window (rounded corners, traffic lights, hairline border,
/// soft shadow) on a gradient backdrop.
class MarketingFrame extends StatelessWidget {
  final Widget child;
  final Brightness brightness;
  final List<Color> gradient;
  const MarketingFrame({super.key, required this.child, required this.brightness, required this.gradient});

  @override
  Widget build(BuildContext context) {
    final dark = brightness == Brightness.dark;
    const radius = 12.0;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        width: _canvas.width,
        height: _canvas.height,
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: gradient),
        ),
        alignment: Alignment.center,
        child: Container(
          width: _appSize.width,
          height: _appSize.height,
          decoration: _SoftShadow(radius: radius, strength: dark ? 0.5 : 0.22),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: dark ? Colors.white.withValues(alpha: 0.16) : Colors.black.withValues(alpha: 0.18), width: 1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Stack(children: [
              Positioned.fill(
                child: MediaQuery(
                  data: MediaQueryData(size: _appSize, platformBrightness: brightness),
                  child: child,
                ),
              ),
              const Positioned(left: 20, top: 20, child: _TrafficLights()),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A large soft drop shadow drawn as stacked translucent rounded rects
/// (the headless renderer draws blurred BoxShadows hard-edged).
class _SoftShadow extends Decoration {
  final double radius;
  final double strength;
  const _SoftShadow({required this.radius, required this.strength});

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _SoftShadowPainter(this);
}

class _SoftShadowPainter extends BoxPainter {
  final _SoftShadow d;
  _SoftShadowPainter(this.d);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    void layers({required double spread, required double dy, required double alpha, int steps = 40}) {
      for (var i = steps; i >= 1; i--) {
        final t = i / steps;
        final r = rect.translate(0, dy * t).inflate(spread * t);
        // Each ring adds a little; the stack fades out towards the edge.
        final paint = Paint()..color = Colors.black.withValues(alpha: alpha / steps * 2.2 * (1 - t * 0.85));
        canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(d.radius + spread * t)), paint);
      }
    }

    layers(spread: 64, dy: 30, alpha: d.strength);
    layers(spread: 10, dy: 4, alpha: d.strength * 0.5, steps: 10);
  }
}

class _TrafficLights extends StatelessWidget {
  const _TrafficLights();

  @override
  Widget build(BuildContext context) {
    Widget light(Color fill, Color edge) => Container(
          width: 12,
          height: 12,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: Border.all(color: edge, width: 0.5)),
        );
    return IgnorePointer(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        light(const Color(0xFFFF5F57), const Color(0xFFE0443E)),
        light(const Color(0xFFFEBC2E), const Color(0xFFDEA123)),
        light(const Color(0xFF28C840), const Color(0xFF1AAB29)),
      ]),
    );
  }
}

const brandDark = [Color(0xFF0B1630), Color(0xFF0E2A5C), Color(0xFF0A84FF)];
const brandLight = [Color(0xFFEFF3F9), Color(0xFFDDE6F3), Color(0xFFC9D8EE)];

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

final _boundary = GlobalKey();

class Shot {
  final AppState app;
  final LogDock dock;
  final MarketingApi api;
  Shot(this.app, this.dock, this.api);
}

Future<Shot> pumpApp(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
  List<Color> gradient = brandDark,
  void Function(AppState app)? configure,
}) async {
  tester.view.physicalSize = _canvas;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = MarketingApi();
  final app = AppState(api);
  await app.init();
  configure?.call(app);
  final dock = LogDock(api);
  await tester.pumpWidget(RepaintBoundary(
    key: _boundary,
    child: MarketingFrame(
      brightness: brightness,
      gradient: gradient,
      child: MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<LogDock>.value(value: dock),
        ],
        child: K8sManApp(themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light),
      ),
    ),
  ));
  await settle(tester);
  return Shot(app, dock, api);
}

Future<void> settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Writes `build/marketing/<name>.png` at 2×.
Future<void> capture(WidgetTester tester, String name) async {
  await settle(tester, 2);
  final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final path = '${Directory.current.path}/build/marketing/$name.png';
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('marketing: $path');
}

void shot(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    await loadRealFonts();
    await http.runWithClient(() => body(tester), () => MockClient(restHandler));
    if (unhandled.isNotEmpty) {
      // ignore: avoid_print
      print('unhandled in $name:\n  ${unhandled.join('\n  ')}');
      unhandled.clear();
    }
  }, skip: !_enabled);
}

// ---------------------------------------------------------------------------
// Shots
// ---------------------------------------------------------------------------

/// Drags the inspector's splitter so the inspector is [width] wide.
Future<void> inspectorWidth(WidgetTester tester, double width) async {
  final edge = _padH + _appSize.width - 559;
  await tester.dragFrom(Offset(edge, _padV + 450), Offset(560 - width, 0));
  await settle(tester, 2);
}

/// Lets real time pass so "updated …" labels don't read "0s ago".
/// Pages refetch every 10 s and their AgeText ticks every 15 s (fake time),
/// while ages are computed from the real clock.
Future<void> age(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await settle(tester, 2);
  await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
  await tester.pump(const Duration(seconds: 5));
  await settle(tester, 2);
}

Future<void> openPod(WidgetTester tester, Shot s, String name, String namespace) async {
  s.app.openDetail(DetailTarget(type: s.app.typeFor('', 'Pod')!, name: name, namespace: namespace));
  await settle(tester);
}

Future<void> withMeta(WidgetTester tester, Future<void> Function() body) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await body();
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
}

const _terminalScript = '/ # ls -la /usr/share/nginx/html\r\n'
    'total 20\r\n'
    'drwxr-xr-x    3 root     root          4096 Oct 28 10:12 \x1b[1;34m.\x1b[0m\r\n'
    'drwxr-xr-x    3 root     root          4096 Oct 28 10:12 \x1b[1;34m..\x1b[0m\r\n'
    '-rw-r--r--    1 root     root           497 Oct 28 10:12 50x.html\r\n'
    '-rw-r--r--    1 root     root          1862 Nov  2 09:41 index.html\r\n'
    'drwxr-xr-x    4 root     root          4096 Nov  2 09:41 \x1b[1;34mstatic\x1b[0m\r\n'
    '/ # env | grep -E "^(APP|LOG)_"\r\n'
    'APP_MODE=production\r\n'
    'LOG_LEVEL=info\r\n'
    '/ # curl -s localhost:8080/healthz\r\n'
    '{"status":"ok","version":"1.27.3","uptime":"30h12m4s"}\r\n'
    '/ # nginx -t\r\n'
    'nginx: the configuration file /etc/nginx/nginx.conf syntax is ok\r\n'
    'nginx: configuration file /etc/nginx/nginx.conf test is \x1b[32msuccessful\x1b[0m\r\n'
    '/ # ';

void main() {
  Future<void> hero(WidgetTester tester, String name, Brightness b, List<Color> g) async {
    final s = await pumpApp(tester, brightness: b, gradient: g, configure: (app) => app.namespace = null);
    await openPod(tester, s, Demo._crashPod, 'checkout');
    await inspectorWidth(tester, 455);
    s.dock.open(Demo.webPod('web-6fd47b8fcb-4v4m9'), container: 'nginx', focus: false);
    s.dock.open(Demo.crashPod(), container: 'api', previous: true);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Search'), 'PAYMENT_GATEWAY_URL');
    await settle(tester);
    await capture(tester, name);
    s.dock.closeAll();
  }

  shot('hero', (tester) => hero(tester, 'hero', Brightness.dark, brandDark));
  shot('light', (tester) => hero(tester, 'light', Brightness.light, brandLight));

  shot('overview', (tester) async {
    final s = await pumpApp(tester, configure: (app) => app.namespace = null);
    s.app.showView(MainView.overview);
    await settle(tester);
    await age(tester);
    await capture(tester, 'overview');
  });

  shot('security', (tester) async {
    final s = await pumpApp(tester, configure: (app) => app.namespace = null);
    s.app.showView(MainView.security);
    await settle(tester);
    await tester.tap(find.textContaining('Unused ServiceAccount holds').first);
    await settle(tester);
    await age(tester);
    await capture(tester, 'security');
  });

  shot('helm', (tester) async {
    final s = await pumpApp(tester, configure: (app) => app.namespace = null);
    s.app.showView(HelmModule.page);
    await settle(tester);
    await tester.tap(find.text('web').first);
    await settle(tester);
    await tester.tap(find.textContaining('History').first);
    await settle(tester);
    // Revision 3 → current.
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.difference_outlined).at(1)).onPressed!();
    await settle(tester);
    await capture(tester, 'helm');
  });

  shot('access', (tester) async {
    final s = await pumpApp(tester, configure: (app) => app.namespace = null);
    s.app.showView(MainView.access);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Find subject'), 'rbac-demo/');
    await settle(tester);
    await tester.tap(find.text('rbac-demo/app'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('cell-/secrets-get')));
    await settle(tester);
    await capture(tester, 'access');
  });

  shot('nodes', (tester) async {
    final s = await pumpApp(tester, configure: (app) => app.namespace = null);
    s.app.showView(MainView.nodes);
    await settle(tester);
    await age(tester);
    await capture(tester, 'nodes');
  });

  shot('argocd', (tester) async {
    ArgoDiffApi.debugOverride = (api) => FakeArgoDiffApi(api, auth: 'cli', argoUrl: 'argocd.example.com', cliLogin: 'argocd.example.com');
    ArgoDiffCache.reset();
    addTearDown(() => ArgoDiffApi.debugOverride = null);
    final s = await pumpApp(tester, configure: (app) {
      app.namespace = null;
      app.selectType(MarketingApi.appType);
    });
    s.app.openDetail(const DetailTarget(type: MarketingApi.appType, name: 'helm-guestbook', namespace: 'argocd'));
    await settle(tester);
    await inspectorWidth(tester, 660);
    final toggle = find.byKey(const ValueKey('diff-toggle-apps/Deployment/helm-guestbook/helm-guestbook'));
    final inspector = find.descendant(of: find.byType(DetailSidebar), matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)).first;
    await tester.scrollUntilVisible(toggle, 200, scrollable: inspector);
    await settle(tester, 2);
    await tester.tap(toggle);
    await settle(tester);
    await tester.drag(inspector, const Offset(0, -260));
    await settle(tester);
    await capture(tester, 'argocd');
  });

  shot('terminal', (tester) async {
    final transport = FakeExecTransport();
    final prev = execTransportFor;
    execTransportFor = (_) => transport;
    addTearDown(() => execTransportFor = prev);
    final s = await pumpApp(tester, configure: (app) => app.namespace = 'storefront');
    await openPod(tester, s, 'web-6fd47b8fcb-4v4m9', 'storefront');
    await inspectorWidth(tester, 470);
    await tester.tap(find.text('Terminal').first);
    await settle(tester);
    await tester.tap(find.text('nginx').last);
    await settle(tester);
    s.dock.setHeight(420);
    final c = transport.last;
    c.emit(const ExecStarted('nginx', ['/bin/sh']));
    c.output(_terminalScript);
    await settle(tester);
    await capture(tester, 'terminal');
    for (final t in [...s.dock.tabs]) {
      if (t is TerminalTab) t.dispose();
    }
  });

  shot('columns', (tester) async {
    final s = await pumpApp(tester, configure: (app) => app.namespace = null);
    unawaited(showColumnEditor(tester.element(find.byType(ResourceTableView)), type: s.app.typeFor('', 'Pod')!));
    await settle(tester, 10);
    await capture(tester, 'columns');
  });

  shot('multiselect', (tester) async {
    final s = await pumpApp(tester, configure: (app) => app.namespace = null);
    await tester.tap(find.text('payments-gateway-6b7d9c5f8-8wz4m'));
    await settle(tester, 2);
    s.app.closeDetail();
    await settle(tester, 2);
    await withMeta(tester, () async {
      await tester.tap(find.text('payments-gateway-6b7d9c5f8-vt9rn'));
      await tester.pump();
      await tester.tap(find.text('fraud-scorer-84f6d7c9b-r2x5k'));
      await tester.pump();
    });
    await settle(tester);
    await capture(tester, 'multiselect');
  });
}
