import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';

import '../../support/harness.dart';

const _vapType = ResourceType(group: 'admissionregistration.k8s.io', version: 'v1', resource: 'validatingadmissionpolicies', kind: 'ValidatingAdmissionPolicy', namespaced: false);

void main() {
  testWidgets('ValidatingAdmissionPolicy panel: rules, CEL, and the bindings using it', (tester) async {
    await pumpPanel(
      tester,
      {
        'apiVersion': 'admissionregistration.k8s.io/v1',
        'kind': 'ValidatingAdmissionPolicy',
        'metadata': {'name': 'replica-limit', 'uid': 'u1'},
        'spec': {
          'failurePolicy': 'Fail',
          'matchConstraints': {
            'resourceRules': [
              {'operations': ['CREATE', 'UPDATE'], 'apiGroups': ['apps'], 'apiVersions': ['v1'], 'resources': ['deployments']},
            ],
          },
          'matchConditions': [
            {'name': 'not-system', 'expression': '!object.metadata.namespace.startsWith("kube-")'},
          ],
          'validations': [
            {'expression': 'object.spec.replicas <= 5', 'message': 'too many replicas', 'reason': 'Invalid'},
          ],
        },
        'status': {
          'typeChecking': {
            'expressionWarnings': [
              {'fieldRef': 'spec.validations[0].expression', 'warning': 'unknown field'},
            ],
          },
        },
      },
      type: _vapType,
      api: FakeApiClient(itemsByResource: {
        'validatingadmissionpolicybindings.admissionregistration.k8s.io': [
          {'metadata': {'name': 'replica-limit-prod'}, 'spec': {'policyName': 'replica-limit', 'validationActions': ['Deny', 'Audit']}},
          {'metadata': {'name': 'other-binding'}, 'spec': {'policyName': 'other', 'validationActions': ['Warn']}},
        ],
      }),
    );
    expect(find.text('CREATE, UPDATE apps/v1 deployments'), findsOneWidget);
    expect(find.text('not-system'), findsOneWidget);
    expect(find.textContaining('startsWith("kube-")'), findsOneWidget);
    expect(find.text('object.spec.replicas <= 5'), findsOneWidget);
    expect(find.text('too many replicas'), findsOneWidget);
    expect(find.text('Invalid'), findsOneWidget);
    expect(find.text('replica-limit-prod'), findsOneWidget);
    expect(find.text('other-binding'), findsNothing);
    expect(find.text('Deny'), findsOneWidget);
    expect(find.textContaining('unknown field'), findsOneWidget);
  });
}
