import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/network/netpol_explain.dart';

import 'net_support.dart';

Json np(Json spec, {String ns = 'demo'}) => {
      'apiVersion': 'networking.k8s.io/v1',
      'kind': 'NetworkPolicy',
      'metadata': {'name': 'p', 'namespace': ns},
      'spec': spec,
    };

void main() {
  test('fixture: matches the canonical example sentence', () {
    final ex = explainNetworkPolicy(devFixture('netpol-web-allow-frontend'), matchedPods: 2);
    expect(ex.appliesTo, 'Applies to pods matching app=web in demo (2 pods).');
    expect(ex.ingress.text,
        'Ingress: allowed only from (pods with tier=frontend in this namespace) OR (any pod in namespaces with team=platform), on TCP 8080.');
    expect(ex.egress.text, 'Egress: not restricted by this policy.');
  });

  test('policyTypes default to Ingress only when there are no egress rules', () {
    final ex = explainNetworkPolicy(np({'podSelector': {}}));
    expect(ex.policyTypes, ['Ingress']);
    expect(ex.policyTypesDefaulted, isTrue);
    expect(ex.ingress.mode, PolicyMode.denyAll);
    expect(ex.egress.mode, PolicyMode.unrestricted);
  });

  test('empty from means allow from everywhere (restricted by port)', () {
    final ex = explainNetworkPolicy(np({
      'podSelector': {},
      'ingress': [
        {
          'ports': [
            {'port': 443}
          ]
        }
      ],
    }));
    expect(ex.ingress.mode, PolicyMode.restricted);
    expect(ex.ingress.text, 'Ingress: allowed only from anywhere, on TCP 443.');
  });

  test('namespaceSelector + podSelector in one peer is an AND', () {
    final ex = explainNetworkPolicy(np({
      'podSelector': {'matchLabels': {'app': 'db'}},
      'ingress': [
        {
          'from': [
            {
              'namespaceSelector': {'matchLabels': {'team': 'platform'}},
              'podSelector': {'matchLabels': {'role': 'api'}},
            },
            {
              'namespaceSelector': {},
              'podSelector': {'matchLabels': {'role': 'monitor'}},
            },
          ]
        }
      ],
    }));
    expect(ex.ingress.text,
        'Ingress: allowed only from (pods with role=api in namespaces with team=platform) OR (pods with role=monitor in any namespace) on any port.');
  });

  test('ipBlock with except', () {
    expect(
      describePeer({
        'ipBlock': {
          'cidr': '10.0.0.0/8',
          'except': ['10.1.0.0/16', '10.2.0.0/16']
        }
      }),
      'IPs in 10.0.0.0/8 except 10.1.0.0/16, 10.2.0.0/16',
    );
    expect(describePeer({'ipBlock': {'cidr': '0.0.0.0/0'}}), 'IPs in 0.0.0.0/0');
  });

  test('port ranges, named ports, protocols and portless entries', () {
    expect(describePort({'port': 32000, 'endPort': 32768}), 'TCP 32000-32768');
    expect(describePort({'protocol': 'UDP', 'port': 53}), 'UDP 53');
    expect(describePort({'port': 'http'}), 'TCP port "http"');
    expect(describePort({'protocol': 'SCTP'}), 'all SCTP ports');
  });

}
