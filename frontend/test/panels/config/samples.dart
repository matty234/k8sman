import 'dart:convert';

import 'package:k8sman/api/models.dart';

String b64(String s) => base64.encode(utf8.encode(s));

const fakeChain = '-----BEGIN CERTIFICATE-----\nMIIBdummyleaf\n-----END CERTIFICATE-----\n'
    '-----BEGIN CERTIFICATE-----\nMIIBdummyca\n-----END CERTIFICATE-----\n';
const fakeKey = '-----BEGIN PRIVATE KEY-----\nMIIEdummykey\n-----END PRIVATE KEY-----\n';

/// A pod that references `app-secret` in every way a pod can.
final Json richPod = {
  'apiVersion': 'v1',
  'kind': 'Pod',
  'metadata': {'name': 'api-7d9f-abcde', 'namespace': 'demo'},
  'spec': {
    'imagePullSecrets': [
      {'name': 'app-secret'}
    ],
    'volumes': [
      {
        'name': 'creds',
        'secret': {
          'secretName': 'app-secret',
          'items': [
            {'key': 'password', 'path': 'pw'},
            {'key': 'token', 'path': 'token'},
          ],
        },
      },
      {
        'name': 'bundle',
        'projected': {
          'sources': [
            {'secret': {'name': 'app-secret'}},
            {'configMap': {'name': 'app-config', 'items': [{'key': 'settings.json', 'path': 'settings.json'}]}},
          ],
        },
      },
      {'name': 'cfg', 'configMap': {'name': 'app-config', 'optional': true}},
    ],
    'initContainers': [
      {
        'name': 'migrate',
        'envFrom': [
          {'secretRef': {'name': 'app-secret'}, 'prefix': 'DB_'},
          {'configMapRef': {'name': 'app-config'}},
        ],
      }
    ],
    'containers': [
      {
        'name': 'api',
        'env': [
          {'name': 'USER', 'valueFrom': {'secretKeyRef': {'name': 'app-secret', 'key': 'username'}}},
          {'name': 'OPT', 'valueFrom': {'secretKeyRef': {'name': 'app-secret', 'key': 'nope', 'optional': true}}},
          {'name': 'LOG_FORMAT', 'valueFrom': {'configMapKeyRef': {'name': 'app-config', 'key': 'LOG_FORMAT'}}},
          {'name': 'FEATURE_X', 'valueFrom': {'configMapKeyRef': {'name': 'app-config', 'key': 'FEATURE_X', 'optional': true}}},
        ],
        'volumeMounts': [
          {'name': 'creds', 'mountPath': '/run/creds', 'readOnly': true},
          {'name': 'bundle', 'mountPath': '/etc/bundle'},
          {'name': 'cfg', 'mountPath': '/etc/app/settings.json', 'subPath': 'settings.json'},
        ],
      }
    ],
  },
  'status': {'phase': 'Pending'},
};

final Json richConfigMap = {
  'apiVersion': 'v1',
  'kind': 'ConfigMap',
  'metadata': {'name': 'app-config', 'namespace': 'demo', 'uid': 'cm-rich'},
  'immutable': true,
  'data': {
    'settings.json': '{"server":{"port":8080,"tls":false},"features":["a","b"],"timeouts":{"read":"5s","write":"10s"}}',
    'app.yaml': 'logging:\n  level: debug\n  format: json\nreplicas: 3\n',
    'app.properties': '# tuning\ndb.pool.size=10\ndb.timeout=30s\n',
    'entrypoint.sh': '#!/bin/sh\nset -eu\nexec /app/server --config /etc/app/settings.json\n',
    'LOG_FORMAT': 'json',
    'big.txt': [for (var i = 1; i <= 80; i++) 'line $i of a long generated file with some padding text'].join('\n'),
  },
  'binaryData': {'logo.png': base64.encode([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 73, 72, 68, 82])},
};

final Json tlsSecret = {
  'apiVersion': 'v1',
  'kind': 'Secret',
  'type': 'kubernetes.io/tls',
  'metadata': {'name': 'web-tls', 'namespace': 'demo', 'uid': 'tls-1'},
  'data': {'tls.crt': b64(fakeChain), 'tls.key': b64(fakeKey)},
};

final Json dockerSecret = {
  'apiVersion': 'v1',
  'kind': 'Secret',
  'type': 'kubernetes.io/dockerconfigjson',
  'metadata': {'name': 'regcred', 'namespace': 'demo', 'uid': 'docker-1'},
  'data': {
    '.dockerconfigjson': b64(jsonEncode({
      'auths': {
        'ghcr.io': {'username': 'octo', 'password': 'ghp_dummy'},
        'registry.example.com': {'auth': b64('robot:pw-from-auth')},
      }
    })),
  },
};

final Json saTokenSecret = {
  'apiVersion': 'v1',
  'kind': 'Secret',
  'type': 'kubernetes.io/service-account-token',
  'metadata': {
    'name': 'web-token',
    'namespace': 'demo',
    'uid': 'sat-1',
    'annotations': {'kubernetes.io/service-account.name': 'web', 'kubernetes.io/service-account.uid': '390397d3'},
  },
  'data': {'token': b64('eyJhbGciOi.dummy.token'), 'ca.crt': b64(fakeChain), 'namespace': b64('demo'), 'blob': base64.encode([0xff, 0xfe, 0x00, 0x01, 0x02])},
};
