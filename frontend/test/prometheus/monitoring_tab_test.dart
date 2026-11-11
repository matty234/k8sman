import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/panel.dart';
import 'package:k8sman/prometheus/monitoring_tab.dart';
import 'package:k8sman/prometheus/prom_api.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

/// Serves a synthetic /api/prom/scrape and /api/prom/applies.
class _Api extends PromApi {
  final Json scrapeJson;
  _Api(this.scrapeJson) : super(ApiClient(base: Uri.parse('http://fake')));

  @override
  Future<dynamic> getJson(String path, [Map<String, String?> query = const {}]) async => switch (path) {
        'scrape' => scrapeJson,
        'applies' => {
            'alerts': [
              {'alertname': 'ApiHighErrorRate', 'state': 'firing', 'severity': 'warning', 'labels': {'alertname': 'ApiHighErrorRate', 'namespace': 'shop', 'pod': 'api-1'}},
            ],
            'rules': [
              {
                'group': 'api.rules',
                'source': {'namespace': 'shop', 'name': 'api-alerts'},
                'rule': {'type': 'alerting', 'name': 'ApiHighErrorRate', 'query': 'rate(errors_total{job="api"}[5m]) > 1', 'state': 'firing', 'health': 'ok', 'duration': 300, 'labels': {'severity': 'warning'}, 'annotations': {'summary': 'Errors are high'}},
                'activeAlerts': 1,
                'reasons': ['has an alert for this pod', 'mentions job="api"'],
              },
            ],
            'rulesTotal': 1,
            'jobs': ['api'],
          },
        _ => throw ApiException(404, 'no fixture for $path'),
      };
}

const _scraped = {
  'kind': 'Pod', 'namespace': 'shop', 'name': 'api-1', 'pods': 1, 'services': ['api'],
  'up': 1, 'down': 1, 'unknown': 0, 'total': 2, 'jobs': ['api'],
  'targets': [
    {
      'scrapePool': 'serviceMonitor/shop/api/0', 'scrapeUrl': 'http://10.0.0.9:8080/metrics', 'health': 'down', 'lastError': 'connection refused',
      'scrapeInterval': '30s', 'job': 'api', 'labels': {'job': 'api', 'namespace': 'shop', 'pod': 'api-1'},
      'monitor': {'kind': 'ServiceMonitor', 'namespace': 'shop', 'name': 'api', 'endpoint': 0},
    },
    {'scrapePool': 'kubernetes-pods', 'scrapeUrl': 'http://10.0.0.9:9100/metrics', 'health': 'up', 'job': 'kubernetes-pods', 'labels': {}},
  ],
  'dropped': [],
  'monitors': [
    {'kind': 'ServiceMonitor', 'namespace': 'shop', 'name': 'api', 'matches': true, 'scraping': true, 'checks': []},
  ],
  'hints': [],
};

const _notScraped = {
  'kind': 'Pod', 'namespace': 'shop', 'name': 'api-1', 'pods': 1, 'services': ['api'],
  'up': 0, 'down': 0, 'unknown': 0, 'total': 0, 'jobs': [], 'targets': [], 'dropped': [],
  'monitors': [
    {
      'kind': 'PodMonitor', 'namespace': 'shop', 'name': 'web', 'matches': false, 'scraping': false,
      'checks': [
        {'name': 'namespace', 'ok': true, 'detail': 'its own namespace'},
        {'name': 'selector', 'ok': true, 'detail': 'selects the pod'},
        {'name': 'port', 'ok': false, 'detail': 'wants port "metrics"; the pod declares http'},
        {'name': 'prometheus', 'ok': true, 'detail': 'selected by Prometheus mon/k8s'},
      ],
    },
  ],
  'hints': ['No ServiceMonitor selects its Service.'],
};

Future<void> _pump(WidgetTester tester, Json scrape) async {
  PromApi.debugOverride = (_) => _Api(scrape);
  addTearDown(() => PromApi.debugOverride = null);
  final client = FakeApiClient();
  final app = AppState(client)..types = testTypes;
  final pod = {
    'apiVersion': 'v1',
    'kind': 'Pod',
    'metadata': {'name': 'api-1', 'namespace': 'shop', 'uid': 'u-${scrape['total']}'},
  };
  final ctx = PanelContext(object: pod, type: testType('', 'Pod'), api: client, app: app);
  tester.view.physicalSize = const Size(620, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: Builder(builder: (c) => monitoringTab(ctx).builder(c, ctx)))),
  ));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('Monitoring tab shows a scraped pod and explains a pod that is not', (tester) async {
    await _pump(tester, _scraped);
    expect(tester.takeException(), isNull);
    expect(find.text('Scraped · 1 down'), findsOneWidget);
    expect(find.text('ServiceMonitor shop/api'), findsWidgets);
    expect(find.text('connection refused'), findsOneWidget);
    expect(find.text('Scrape config'), findsOneWidget);
    expect(find.text('ApiHighErrorRate'), findsWidgets);
    expect(find.textContaining('mentions job="api"'), findsOneWidget);
    expect(find.text('PrometheusRule shop/api-alerts'), findsOneWidget);
    expect(find.text('rate(errors_total{job="api"}[5m]) > 1'), findsNothing);
    await tester.tap(find.text('ApiHighErrorRate').last);
    await tester.pump();
    expect(find.text('rate(errors_total{job="api"}[5m]) > 1'), findsOneWidget);
    expect(find.text('for 5m'), findsOneWidget);
    expect(find.text('summary: Errors are high'), findsOneWidget);

    await _pump(tester, _notScraped);
    expect(tester.takeException(), isNull);
    expect(find.text('Not scraped'), findsOneWidget);
    expect(find.text('Why it isn\'t scraped'), findsOneWidget);
    expect(find.text('PodMonitor shop/web'), findsOneWidget);
    expect(find.text('Doesn\'t match'), findsOneWidget);
    expect(find.text('wants port "metrics"; the pod declares http'), findsOneWidget);
    expect(find.text('No ServiceMonitor selects its Service.'), findsOneWidget);
  });
}
