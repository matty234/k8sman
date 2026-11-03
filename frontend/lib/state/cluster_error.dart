import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/client.dart';
import '../api/models.dart';

/// Why the cluster (or the k8sman backend) couldn't be reached.
enum ClusterErrorKind {
  /// Connection refused, DNS, TLS: the cluster API server isn't reachable.
  unreachable,

  /// The API server didn't answer in time.
  timeout,

  /// 401, an exec credential plugin failure, or anonymous access.
  unauthorized,

  /// 403 for this resource / namespace.
  forbidden,

  /// 404: the resource type is no longer served (e.g. its CRD was deleted).
  notFound,

  /// The local k8sman backend itself isn't reachable.
  backendDown,

  /// Anything else.
  other,
}

/// A classified cluster-access error, from a watch ERROR frame, an
/// [ApiException] or a transport failure.
class ClusterError {
  final ClusterErrorKind kind;

  /// The underlying message, shown collapsed under the explanation.
  final String message;

  /// The cluster API server URL, when known.
  final String? host;
  const ClusterError(this.kind, this.message, {this.host});

  /// From a watch ERROR frame. Newer backends send `reason`; older ones
  /// only the message, which is classified heuristically.
  factory ClusterError.fromWatch(WatchMessage m) =>
      classify(reason: m.reason, code: m.code, message: m.error ?? 'Unknown error', host: m.host);

  /// From anything a call or stream threw. Transport failures (no HTTP
  /// response, failed WebSocket handshake) mean the backend is down: every
  /// cluster-side problem arrives as an HTTP error or an ERROR frame.
  factory ClusterError.fromException(Object e, {String? host}) {
    if (e is ClusterError) return e;
    if (e is ApiException) {
      // 503 NoKubeconfig: the backend has no usable kubeconfig.
      if (e.reason == 'NoKubeconfig') return ClusterError(ClusterErrorKind.other, e.message, host: host);
      return classify(reason: e.reason, code: e.status, message: e.message, host: host);
    }
    final text = '$e';
    if (e is http.ClientException ||
        e is WebSocketChannelException ||
        text.contains('SocketException') ||
        text.contains('Connection refused') ||
        text.contains('Connection closed before full header')) {
      return ClusterError(ClusterErrorKind.backendDown, text, host: host);
    }
    return classify(message: text, host: host);
  }

  static ClusterError classify({String? reason, int? code, required String message, String? host}) {
    host ??= _hostIn(message);
    final low = message.toLowerCase();
    // Anonymous access is a credentials problem, not an RBAC one.
    final anonymous = low.contains('system:anonymous') || low.contains('treated as anonymous');
    ClusterErrorKind kind;
    switch (reason) {
      case 'Unreachable':
        kind = ClusterErrorKind.unreachable;
      case 'Timeout':
        kind = ClusterErrorKind.timeout;
      case 'Unauthorized':
        kind = ClusterErrorKind.unauthorized;
      case 'Forbidden':
        kind = anonymous ? ClusterErrorKind.unauthorized : ClusterErrorKind.forbidden;
      case 'NotFound':
        kind = ClusterErrorKind.notFound;
      default:
        kind = switch (code) {
          401 => ClusterErrorKind.unauthorized,
          403 => anonymous ? ClusterErrorKind.unauthorized : ClusterErrorKind.forbidden,
          404 => ClusterErrorKind.notFound,
          502 => ClusterErrorKind.unreachable,
          504 => ClusterErrorKind.timeout,
          _ => _fromText(low, anonymous),
        };
    }
    return ClusterError(kind, message, host: host);
  }

  /// Older backends send only the message.
  static ClusterErrorKind _fromText(String low, bool anonymous) {
    if (anonymous || low.contains('unauthorized') || low.contains('getting credentials') || low.contains('must be logged in')) {
      return ClusterErrorKind.unauthorized;
    }
    if (low.contains('forbidden')) return ClusterErrorKind.forbidden;
    if (low.contains('timeout') || low.contains('timed out') || low.contains('deadline exceeded')) return ClusterErrorKind.timeout;
    if (low.contains('connection refused') ||
        low.contains('no such host') ||
        low.contains('no route to host') ||
        low.contains('network is unreachable') ||
        low.contains('x509:') ||
        low.contains('tls:')) {
      return ClusterErrorKind.unreachable;
    }
    if (low.contains('the server could not find the requested resource') || low.contains('not found')) return ClusterErrorKind.notFound;
    return ClusterErrorKind.other;
  }

  /// `https://host:port` from messages like `Get "https://10.0.0.1:6443/api…"`.
  static String? _hostIn(String message) {
    final m = RegExp(r'https?://[^/\s"]+').firstMatch(message);
    return m?.group(0);
  }

  /// The plugin's own output from exec credential failures, if any.
  String? get pluginError {
    final i = message.indexOf('getting credentials:');
    return i < 0 ? null : message.substring(i + 'getting credentials:'.length).trim();
  }

  @override
  String toString() => message;
}
