import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/util/k8s.dart';

void main() {
  test('selectorTerms spells selectors the way kubectl does', () {
    expect(selectorTerms({'app': 'web'}), ['app=web']);
    expect(
      selectorTerms({
        'matchLabels': {'app': 'web'},
        'matchExpressions': [
          {'key': 'tier', 'operator': 'In', 'values': ['a', 'b']},
          {'key': 'env', 'operator': 'NotIn', 'values': ['dev']},
          {'key': 'canary', 'operator': 'Exists'},
          {'key': 'legacy', 'operator': 'DoesNotExist'},
        ],
      }),
      ['app=web', 'tier in (a,b)', 'env notin (dev)', 'canary', '!legacy'],
    );
    expect(selectorTerms(null), isEmpty);
  });
}
