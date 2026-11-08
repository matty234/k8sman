import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';

import '../../support/harness.dart';

const _claimType = ResourceType(group: 'resource.k8s.io', version: 'v1', resource: 'resourceclaims', kind: 'ResourceClaim');

Json _claim(Json devices, {Json? status}) => {
      'apiVersion': 'resource.k8s.io/v1',
      'kind': 'ResourceClaim',
      'metadata': {'name': 'gpu-claim', 'namespace': 'default', 'uid': 'u1'},
      'spec': {'devices': devices},
      'status': ?status,
    };

void main() {
  testWidgets('ResourceClaim panel: v1 allocation and consumers, v1beta1 request shape', (tester) async {
    await pumpPanel(
      tester,
      _claim({
        'requests': [
          {
            'name': 'gpu',
            'exactly': {
              'deviceClassName': 'gpu.example.com',
              'count': 2,
              'selectors': [
                {'cel': {'expression': 'device.attributes["gpu.example.com"].model == "a100"'}},
              ],
            },
          },
        ],
      }, status: {
        'allocation': {
          'devices': {
            'results': [
              {'request': 'gpu', 'driver': 'gpu.example.com', 'pool': 'node-a', 'device': 'gpu-0'},
              {'request': 'gpu', 'driver': 'gpu.example.com', 'pool': 'node-a', 'device': 'gpu-1'},
            ],
          },
          'nodeSelector': {
            'nodeSelectorTerms': [
              {'matchFields': [{'key': 'metadata.name', 'operator': 'In', 'values': ['node-a']}]},
            ],
          },
        },
        'reservedFor': [{'resource': 'pods', 'name': 'trainer-0', 'uid': 'p1'}],
      }),
      type: _claimType,
    );
    expect(find.text('Reserved: 1'), findsOneWidget);
    expect(find.text('gpu.example.com'), findsWidgets);
    expect(find.text('× 2'), findsOneWidget);
    expect(find.textContaining('model == "a100"'), findsOneWidget);
    expect(find.text('gpu-1'), findsOneWidget);
    expect(find.text('Pod/trainer-0'), findsOneWidget);
    expect(find.text('node-a'), findsNWidgets(3)); // node link and each device's pool

    // v1beta1 keeps the request fields flat.
    await pumpPanel(
      tester,
      _claim({
        'requests': [
          {'name': 'old', 'deviceClassName': 'legacy.example.com', 'allocationMode': 'All'},
        ],
      }),
      type: _claimType,
    );
    expect(find.text('legacy.example.com'), findsOneWidget);
    expect(find.text('all matching devices'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
  });
}
