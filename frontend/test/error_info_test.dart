import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/error_info.dart';

void main() {
  test('describeError: a timeout, a 403 and an unknown error in plain language', () {
    final timeout = describeError(ApiException(504,
        'Get "https://10.0.0.1:6443/api/v1/pods?fieldSelector=status.phase%21%3DSucceeded%2Cstatus.phase%21%3DFailed": dial tcp 10.0.0.1:6443: i/o timeout'));
    expect((timeout.kind, timeout.title, timeout.detail, timeout.retryable),
        (ErrorKind.timeout, "Couldn't reach the cluster", "The API server didn't answer in time.", true));
    expect(timeout.raw, contains('i/o timeout'));

    final forbidden = describeError(ApiException(403, 'nodes is forbidden: User "alice@example.com" cannot list resource "nodes" in API group "" at the cluster scope'));
    expect((forbidden.kind, forbidden.title, forbidden.detail, forbidden.retryable),
        (ErrorKind.forbidden, 'Not allowed', "You can't list nodes at the cluster scope.", false));

    // Unknown: the server's message, without the status prefix and with the
    // request shortened to its path.
    final other = describeError('API 500: Get "https://example:6443/apis/example.com/v1/widgets?limit=500": widget webhook exploded');
    expect((other.kind, other.title), (ErrorKind.other, 'GET /apis/example.com/v1/widgets: widget webhook exploded'));
  });
}
