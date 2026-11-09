import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/security/ai_summary.dart';
import 'package:k8sman/ui/security/security_api.dart';

SecurityData _load(String f) => SecurityData.fromJson(jsonDecode(File('test/security/fixtures/$f').readAsStringSync()));

void main() {
  test('AI summary is a prioritised, self-contained Markdown brief', () {
    final d = _load('security.json');
    final md = securityReportForAgent(d, kubeContext: 'kind-k8sman-dev');
    // ignore: avoid_print
    print(md.split('\n').take(45).join('\n'));
    expect(md, startsWith('# Kubernetes security findings'));
    expect(md, contains('Context for an AI assistant'));
    expect(md, contains('`kind-k8sman-dev`'));
    expect(md, contains('## Summary'));
    expect(md, contains('## Findings'));
    // Severity order: no lower severity before a higher one.
    final order = RegExp(r'^### \[(\w+)\]', multiLine: true).allMatches(md).map((m) => m.group(1)!).toList();
    const rank = {'Critical': 0, 'High': 1, 'Medium': 2, 'Low': 3, 'Info': 4};
    for (var i = 1; i < order.length; i++) {
      expect(rank[order[i]]! >= rank[order[i - 1]]!, isTrue, reason: '${order[i - 1]} before ${order[i]}');
    }
    expect(order.length, lessThanOrEqualTo(40));
    expect(md.length, lessThan(60000), reason: 'fits in a prompt');
  });

}
