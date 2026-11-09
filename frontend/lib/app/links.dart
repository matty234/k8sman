import 'package:flutter/foundation.dart';

/// A shareable link to a place in k8sman: a context, optionally a page, a
/// kind's table (optionally in one namespace) or one object.
///
/// Two spellings:
///
///     https://k8sman.dev/o/?kind=<Kind>&group=<group>&ns=<ns>&name=<name>#c=<fp>&ctx=<context>
///     k8sman://open?kind=…&group=…&ns=…&name=…&c=<fp>&ctx=<context>
///
/// `group` is omitted for core kinds and `ns` for cluster-scoped ones.
/// `view=<page>` names a page instead of a kind. `c` is the cluster
/// fingerprint (`ContextInfo.fingerprint`: a hash of the API server URL)
/// and `ctx` the sender's context name. On the web form they ride in the
/// fragment, which browsers never send to k8sman.dev; the `k8sman://` form
/// accepts them in the query or the fragment. Older links with `ctx` in the
/// query of either form still parse. A link only ever carries these names
/// and the hash: no server URLs, no credentials.
///
/// Every parameter is untrusted: [AppLink.parse] rejects anything outside
/// the rules below rather than trying to clean it up.
@immutable
class AppLink {
  final String context;
  final String? namespace;
  final String? kind;

  /// API group ('' = core).
  final String group;
  final String? name;

  /// A page id (`MainView.name`, e.g. `overview`, `nodes`, `helm`).
  final String? view;

  /// The cluster fingerprint (`c`); null on older links.
  final String? cluster;

  const AppLink({required this.context, this.cluster, this.namespace, this.kind, this.group = '', this.name, this.view});

  static const scheme = 'k8sman';
  static const webBase = 'https://k8sman.dev/o/';

  /// Kube context names come from kubeconfig files and can hold almost
  /// anything (EKS ARNs, `user@cluster`, spaces): any printable text up to
  /// 253 characters, no control characters.
  static final _context = RegExp(r'^[^\x00-\x1f\x7f]{1,253}$');

  /// DNS-1123 label (namespaces).
  static final _namespace = RegExp(r'^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$');

  /// Object names: DNS-1123 subdomains, plus the `:` and `@` and capitals
  /// some kinds allow (RBAC's `system:…` roles, CRDs). Must start with a
  /// letter or digit; 253 characters at most.
  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@-]{0,252}$');

  /// Kinds are CamelCase identifiers.
  static final _kind = RegExp(r'^[A-Za-z][A-Za-z0-9]{0,62}$');

  /// API groups are DNS-1123 subdomains.
  static final _group = RegExp(r'^(?=.{1,253}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$');

  /// Page ids.
  static final _view = RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$');

  /// Cluster fingerprints: 12 lowercase hex characters.
  static final _cluster = RegExp(r'^[0-9a-f]{12}$');

  /// Parses a `k8sman://open?…` or `https://k8sman.dev/o/?…` link. Null
  /// when it isn't one, or when any parameter breaks the rules above or the
  /// combination makes no sense (a name without a kind, a page and a kind).
  static AppLink? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    final isApp = uri.scheme == scheme && (uri.host == 'open' || uri.path == 'open' || uri.path == '/open');
    final isWeb = (uri.scheme == 'https' || uri.scheme == 'http') &&
        (uri.host == 'k8sman.dev' || uri.host == 'www.k8sman.dev') &&
        (uri.path == '/o' || uri.path == '/o/');
    if (!isApp && !isWeb) return null;
    final Map<String, String> q, frag;
    try {
      // Decodes %-escapes; a malformed escape throws.
      q = uri.queryParameters;
      frag = uri.hasFragment ? Uri.splitQueryString(uri.fragment) : const {};
    } catch (_) {
      return null;
    }
    String? opt(String k) {
      final v = q[k];
      return v == null || v.isEmpty ? null : v;
    }

    // The cluster's identity: from the fragment (new links), else the query
    // (the k8sman:// form, and older links).
    String? id(String k) {
      final v = frag[k];
      return v == null || v.isEmpty ? opt(k) : v;
    }

    final ctx = id('ctx'), c = id('c');
    final ns = opt('ns'), kind = opt('kind'), group = opt('group'), name = opt('name'), view = opt('view');
    if (ctx == null || !_context.hasMatch(ctx)) return null;
    if (c != null && !_cluster.hasMatch(c)) return null;
    if (ns != null && !_namespace.hasMatch(ns)) return null;
    if (kind != null && !_kind.hasMatch(kind)) return null;
    if (group != null && !_group.hasMatch(group)) return null;
    if (name != null && !_name.hasMatch(name)) return null;
    if (view != null && !_view.hasMatch(view)) return null;
    if (view != null && (kind != null || name != null || ns != null)) return null;
    if ((name != null || group != null) && kind == null) return null;
    if (ns != null && kind == null) return null;
    return AppLink(context: ctx, cluster: c, namespace: ns, kind: kind, group: group ?? '', name: name, view: view);
  }

  /// Parameters in a fixed order, %-encoded (spaces as %20, not +).
  static String _encode(List<(String, String?)> parts) =>
      [for (final (k, v) in parts) if (v != null) '$k=${Uri.encodeComponent(v)}'].join('&');

  /// What the link points at.
  String get _what => _encode([
        ('view', view),
        ('kind', kind),
        ('group', group.isEmpty ? null : group),
        ('ns', namespace),
        ('name', name),
      ]);

  /// Which cluster.
  String get _where => _encode([('c', cluster), ('ctx', context)]);

  /// `k8sman://open?…&c=…&ctx=…`: opens the app directly.
  String get appUrl => '$scheme://open?${[_what, _where].where((s) => s.isNotEmpty).join('&')}';

  /// `https://k8sman.dev/o/?…#c=…&ctx=…`: a page that opens the app, or
  /// offers to download it. The cluster stays in the fragment, so the
  /// k8sman.dev server never sees it.
  String get webUrl => '$webBase${_what.isEmpty ? '' : '?$_what'}#$_where';

  /// "Deployment shop/api", "Nodes table", "the Overview"-style label for
  /// prompts (without the context).
  String get what {
    if (kind != null && name != null) return '$kind ${namespace == null ? name : '$namespace/$name'}';
    if (kind != null) return namespace == null ? kind! : '$kind in $namespace';
    if (view != null) return 'page $view';
    return 'context';
  }

  @override
  bool operator ==(Object other) =>
      other is AppLink &&
      other.context == context &&
      other.cluster == cluster &&
      other.namespace == namespace &&
      other.kind == kind &&
      other.group == group &&
      other.name == name &&
      other.view == view;

  @override
  int get hashCode => Object.hash(context, cluster, namespace, kind, group, name, view);

  @override
  String toString() => appUrl;
}

/// Where incoming link URLs wait until the UI can open them: the macOS
/// app delegate (over the `k8sman/window` channel) and the Windows/Linux
/// command line hand them in with [receive]; the shell sets [handler] once
/// it is up and gets everything queued before that.
class LinkInbox {
  LinkInbox._();

  static final List<String> _pending = [];
  static void Function(String url)? _handler;

  static void Function(String url)? get handler => _handler;
  static set handler(void Function(String url)? h) {
    _handler = h;
    if (h == null) return;
    final queued = [..._pending];
    _pending.clear();
    queued.forEach(h);
  }

  /// A URL from outside the app (never trusted: the handler parses it).
  static void receive(String url) {
    final h = _handler;
    if (h == null) {
      _pending.add(url);
    } else {
      h(url);
    }
  }

  /// Arguments the app was launched with (Windows, Linux): the first that
  /// looks like a link.
  static void receiveArgs(List<String> args) {
    for (final a in args) {
      if (a.toLowerCase().startsWith('${AppLink.scheme}:')) {
        receive(a);
        return;
      }
    }
  }
}
