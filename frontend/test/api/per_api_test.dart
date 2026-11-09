import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/backend_http.dart';
import 'package:k8sman/api/client.dart';

void main() {
  test('PerApi caches one instance per client and honours debugOverride', () {
    final of = PerApi((ApiClient api) => Object());
    final a = ApiClient(), b = ApiClient();
    expect(of(a), same(of(a)));
    expect(of(a), isNot(same(of(b))));
    final fake = Object();
    of.debugOverride = (_) => fake;
    expect(of(a), same(fake));
    of.debugOverride = null;
    expect(of(a), isNot(same(fake)));
  });
}
