import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'net_support.dart';

void main() {
  testWidgets('endpointslice: service link, ports, endpoints', (tester) async {
    await loadRealFonts();
    final slice = devFixture('endpointslice-web');
    // Add a terminating endpoint with zone + hints to exercise the badges.
    (slice['endpoints'] as List).add({
      'addresses': ['10.244.0.9'],
      'conditions': {'ready': false, 'serving': true, 'terminating': true},
      'nodeName': 'k8sman-dev-control-plane',
      'zone': 'us-east-1a',
      'hints': {
        'forZones': [
          {'name': 'us-east-1a'}
        ]
      },
      'targetRef': {'kind': 'Pod', 'name': 'web-old', 'namespace': 'demo'},
    });
    final app = await pumpPanel(tester, slice);
    expect(find.text('IPv4'), findsOneWidget);
    expect(find.text('http 8080/TCP'), findsOneWidget);
    expect(find.text('2 of 3 ready'), findsWidgets);
    expect(find.text('not ready · serving · terminating'), findsOneWidget);
    expect(find.text('us-east-1a'), findsOneWidget);
    await tester.tap(find.text('web'));
    expect(app.detail?.type.kind, 'Service');
  });

  testWidgets('legacy endpoints: ready vs not-ready addresses', (tester) async {
    await loadRealFonts();
    final ep = Map<String, dynamic>.from(netFixture('endpoints-web') as Map);
    final subset = (ep['subsets'] as List).first as Json;
    subset['notReadyAddresses'] = [
      {
        'ip': '10.244.0.7',
        'nodeName': 'k8sman-dev-control-plane',
        'targetRef': {'kind': 'Pod', 'name': 'web-starting', 'namespace': 'demo'}
      }
    ];
    final app = await pumpPanel(tester, ep);
    expect(find.text('2 of 3 ready'), findsWidgets);
    expect(find.text('not ready'), findsWidgets);
    await tester.tap(find.text('web-starting'));
    expect(app.detail?.name, 'web-starting');
  });

  testWidgets('legacy endpoints: headless redis with hostname', (tester) async {
    await pumpPanel(tester, Map<String, dynamic>.from(netFixture('endpoints-redis') as Map));
    expect(find.text('hostname: redis-0'), findsOneWidget);
    expect(find.text('redis 6379/TCP'), findsOneWidget);
  });
}
