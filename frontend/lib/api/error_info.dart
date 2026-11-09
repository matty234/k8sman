import '../state/cluster_error.dart';
import 'client.dart';

/// What kind of failure an error is, for [describeError].
enum ErrorKind {
  /// The API server didn't answer in time (504, i/o timeout, deadline).
  timeout,

  /// The API server couldn't be reached (502, connection refused, no route).
  unreachable,

  /// The API server's certificate wasn't trusted.
  tls,

  /// The API server's host name didn't resolve.
  dns,

  /// 401, expired or missing credentials.
  unauthorized,

  /// 403: RBAC doesn't allow it.
  forbidden,

  /// 404.
  notFound,

  /// The local k8sman backend isn't answering.
  backendDown,

  /// Anything else: the server's own message.
  other,
}

/// A raw error in plain language: a short [title], a one-line [detail] and
/// the untouched [raw] text for "Details".
class ErrorInfo {
  final String title;

  /// One line under the title; may be empty.
  final String detail;

  /// The original message, for Details and copying.
  final String raw;
  final ErrorKind kind;

  /// Whether trying again might help (not for 403, 404, certificates).
  final bool retryable;
  const ErrorInfo({required this.title, required this.detail, required this.raw, required this.kind, required this.retryable});

  /// Whether [raw] says more than [title] and [detail] do.
  bool get hasMore => raw.trim() != title.trim() && raw.trim() != detail.trim() && raw.trim() != '$title: $detail'.trim();
}

/// The server's own words for [e] (an [ApiException]'s message without its
/// status), for places that quote it verbatim, e.g. an apply rejection.
String errorText(Object e) => e is ApiException ? e.message : '$e';

/// The plain-language summary of [e]: an [ApiException], a transport
/// failure, a [ClusterError] or a message string (which may start with a
/// caller's own context, e.g. "Could not load roles: API 504: …").
ErrorInfo describeError(Object e) {
  final raw = e is ApiException ? e.message : '$e';
  // A caller's own lead-in ("Could not list RBAC: …") becomes the title.
  if (e is String) {
    final lead = _leadIn(e);
    if (lead != null) {
      final rest = describeError(e.substring(lead.length + 1).trim());
      final detail = rest.kind == ErrorKind.other ? rest.title : [rest.title, if (rest.detail.isNotEmpty) rest.detail].join('. ');
      return ErrorInfo(title: lead, detail: detail, raw: e, kind: rest.kind, retryable: rest.retryable);
    }
  }
  final ClusterError c;
  if (e is String) {
    final m = RegExp(r'^API (\d{3}): ').firstMatch(e);
    c = m != null ? ClusterError.classify(code: int.parse(m.group(1)!), message: e) : ClusterError.classify(message: e);
  } else {
    c = ClusterError.fromException(e);
  }
  final low = raw.toLowerCase();
  final status = e is ApiException ? e.status : int.tryParse(RegExp(r'^API (\d{3}): ').firstMatch(raw)?.group(1) ?? '');
  final clean = cleanErrorMessage(raw);
  ErrorInfo info(ErrorKind kind, String title, String detail, {bool retryable = true}) =>
      ErrorInfo(title: title, detail: detail, raw: raw, kind: kind, retryable: retryable);

  if (e is ApiException && e.reason == 'NoKubeconfig') {
    return info(ErrorKind.other, 'No usable kubeconfig', clean);
  }
  switch (c.kind) {
    case ClusterErrorKind.backendDown:
      return info(ErrorKind.backendDown, "The k8sman backend isn't running", "The local helper that talks to the cluster didn't answer.");
    case ClusterErrorKind.timeout:
      return info(ErrorKind.timeout, "Couldn't reach the cluster", "The API server didn't answer in time.");
    case ClusterErrorKind.unauthorized:
      return info(ErrorKind.unauthorized, 'Not signed in, or credentials expired', "The cluster didn't accept your kubeconfig's credentials. Sign in again, then retry.");
    case ClusterErrorKind.forbidden:
      return info(ErrorKind.forbidden, 'Not allowed', _forbiddenDetail(raw) ?? clean, retryable: false);
    case ClusterErrorKind.notFound:
      final gone = low.contains('the server could not find the requested resource');
      return info(ErrorKind.notFound, 'Not found', gone ? "The cluster doesn't serve this kind of resource." : clean, retryable: false);
    case ClusterErrorKind.unreachable:
      if (low.contains('x509') || low.contains('tls:') || low.contains('certificate')) {
        return info(ErrorKind.tls, "The cluster's certificate isn't trusted", "The TLS handshake with the API server failed. Check the kubeconfig's certificate authority.", retryable: false);
      }
      if (low.contains('no such host') || low.contains('server misbehaving') || RegExp(r'lookup \S+ on ').hasMatch(low)) {
        return info(ErrorKind.dns, "Can't find the API server", "Its host name didn't resolve. Are you on the VPN or network the cluster needs?");
      }
      if (low.contains('connection refused') || low.contains('no route to host') || low.contains('network is unreachable')) {
        return info(ErrorKind.unreachable, "Can't connect to the API server", 'The connection was refused or there is no route to it.');
      }
      return info(ErrorKind.unreachable, "Couldn't reach the cluster", "The API server didn't answer.");
    case ClusterErrorKind.cancelled:
    case ClusterErrorKind.other:
      final transient = status != null && status >= 500;
      return info(ErrorKind.other, clean.isEmpty ? 'Something went wrong' : clean, '', retryable: transient || status == null || status == 429);
  }
}

/// [raw] made readable: no "API 504:" prefix, and `Get "https://host/path?query": `
/// shortened to `GET /path: `, any other URLs unescaped.
String cleanErrorMessage(String raw) {
  var s = raw.trim().replaceFirst(RegExp(r'^API \d{3}: '), '');
  s = s.replaceAllMapped(RegExp(r'\b(Get|Post|Put|Patch|Delete|Head|Options) "(https?://[^"]+)":\s*'), (m) {
    final uri = Uri.tryParse(m.group(2)!);
    final path = uri == null || uri.path.isEmpty ? '' : ' ${uri.path}';
    return '${m.group(1)!.toUpperCase()}$path: ';
  });
  s = s.replaceAllMapped(RegExp(r'https?://\S+'), (m) {
    try {
      return Uri.decodeFull(m.group(0)!);
    } catch (_) {
      return m.group(0)!;
    }
  });
  return s;
}

/// "You can't list nodes at the cluster scope." from a Kubernetes 403.
String? _forbiddenDetail(String raw) {
  final m = RegExp(r'cannot (\w+) resource "([^"]+)"(?: in API group "([^"]*)")?(?: in the namespace "([^"]+)"| (at the cluster scope))?').firstMatch(raw);
  if (m == null) return null;
  final where = m.group(4) != null ? ' in namespace ${m.group(4)}' : (m.group(5) != null ? ' at the cluster scope' : '');
  final group = (m.group(3) ?? '').isEmpty ? '' : '.${m.group(3)}';
  return "You can't ${m.group(1)} ${m.group(2)}$group$where.";
}

/// A caller's lead-in before the first ": ", e.g. "Could not load the
/// overview" or "Refresh failed": capitalised words, no quotes or URLs,
/// not an "API 504" status or a Kubernetes "x is forbidden".
String? _leadIn(String s) {
  final i = s.indexOf(': ');
  if (i <= 0 || i > 80) return null;
  final lead = s.substring(0, i);
  if (!RegExp(r'^[A-Z][A-Za-z]').hasMatch(lead)) return null;
  if (RegExp(r'^API \d{3}$').hasMatch(lead) || RegExp(r'["/\\]').hasMatch(lead)) return null;
  if (RegExp(r'^(Get|Post|Put|Patch|Delete|Head|Options)\b').hasMatch(lead)) return null;
  // Exception class names ("SocketException: …", "ClientException: …").
  if (RegExp(r'^\w+(Exception|Error)$').hasMatch(lead)) return null;
  return lead;
}
