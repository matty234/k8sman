import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';

String b64(String s) => base64.encode(utf8.encode(s));

void main() {
  // Bootstrap-token style secret: long keys like the one the user hit.
  final secret = {
    'apiVersion': 'v1',
    'kind': 'Secret',
    'type': 'bootstrap.kubernetes.io/token',
    'metadata': {'name': 'bootstrap-token-abcdef', 'namespace': 'kube-system'},
    'data': {
      'token-id': b64('abcdef'),
      'token-secret': b64('0123456789abcdef'),
      'usage-bootstrap-authentication': b64('true'),
      'usage-bootstrap-signing': b64('true'),
      'a-very-very-long-key-name-that-goes-on-and-on-and-on.properties': b64('x=1'),
    },
  };
  final cm = {
    'apiVersion': 'v1',
    'kind': 'ConfigMap',
    'metadata': {'name': 'long-keys', 'namespace': 'demo'},
    'data': {
      'a-very-very-long-key-name-that-goes-on-and-on-and-on.properties': 'x=1',
      'short': 'value',
    },
  };

  for (final obj in [secret, cm]) {
    testWidgets('${obj['kind']} with long keys has no overflow at narrow widths', (tester) async {
      await loadRealFonts();
      for (var w = 320.0; w <= 760; w += 40) {
        await pumpPanel(tester, obj, size: Size(w, 1600));
        expect(tester.takeException(), isNull, reason: 'overflow at width $w');
      }
      // Reveal everything (Secret) and re-check the narrowest width.
      final reveal = find.byTooltip('Reveal');
      if (reveal.evaluate().isNotEmpty) {
        await pumpPanel(tester, obj, size: const Size(320, 1600));
        for (final f in reveal.evaluate().toList().reversed) {
          await tester.tap(find.byWidget(f.widget));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
