import 'package:flutter_test/flutter_test.dart';

import '../../support/harness.dart';

void main() {
  testWidgets('ExternalSecret panel: error condition, store and target links, data mapping', (tester) async {
    final app = await pumpPanel(tester, {
      'apiVersion': 'external-secrets.io/v1beta1',
      'kind': 'ExternalSecret',
      'metadata': {'name': 'db', 'namespace': 'apps', 'uid': 'u1'},
      'spec': {
        'refreshInterval': '15m',
        'secretStoreRef': {'kind': 'ClusterSecretStore', 'name': 'vault'},
        'target': {'name': 'db-creds', 'creationPolicy': 'Owner'},
        'data': [
          {'secretKey': 'password', 'remoteRef': {'key': 'prod/db', 'property': 'pw'}},
        ],
      },
      'status': {
        'refreshTime': '2026-01-01T00:00:00Z',
        'conditions': [
          {'type': 'Ready', 'status': 'False', 'reason': 'SecretSyncedError', 'message': 'could not get secret data from provider'},
        ],
      },
    });
    expect(find.text('SecretSyncedError'), findsWidgets);
    expect(find.text('could not get secret data from provider'), findsOneWidget);
    expect(find.text('The target Secret does not exist yet.'), findsOneWidget);
    expect(find.text('prod/db'), findsOneWidget);
    await tester.tap(find.text('ClusterSecretStore/vault'));
    expect(app.detail?.name, 'vault');
    await tester.tap(find.text('Secret/db-creds'));
    expect(app.detail?.name, 'db-creds');
  });
}
