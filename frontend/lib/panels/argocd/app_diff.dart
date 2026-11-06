/// Per-resource Argo CD diffs, from the Argo CD API server
/// (`/api/argocd/*` on the backend, which reaches argocd-server through the
/// Kubernetes API service proxy). See docs/ARGOCD.md.
///
/// - [ArgoDiffApi]: the backend endpoints.
/// - [ArgoDiffCache]: diffs per app, refetched only when the app's sync
///   revision or `reconciledAt` changes (not on every watch tick).
/// - [ArgoConnectStrip]: "Connect…" (opens the sign-in form,
///   argocd_settings.dart) / connected state.
/// - [ResourceDiffBlock]: one resource's diff (shared [DiffView]).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../api/backend_http.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/detail/yaml_editor.dart' show DiffView;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/diff.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'argo_common.dart';
import 'argocd_settings.dart';

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// GET /api/argocd/status.
class ArgoApiStatus {
  /// The Application CRD is served (Argo CD is on this cluster).
  final bool crd;
  final bool found;
  final bool reachable;

  /// none, configured, session or cli.
  final String auth;

  /// Whether Argo accepted the token (null = unknown / no token).
  final bool? authValid;
  final String? username;
  final bool initialAdminAvailable;
  final String? error;
  final String? serverNamespace;
  final String? serverName;
  final String? version;

  /// Host from argocd-cm `url` (used for the CLI login command).
  final String? argoUrl;

  /// argocd CLI context with a login for [argoUrl], if any.
  final String? cliLogin;

  const ArgoApiStatus({
    this.crd = true,
    this.found = false,
    this.reachable = false,
    this.auth = 'none',
    this.authValid,
    this.username,
    this.initialAdminAvailable = false,
    this.error,
    this.serverNamespace,
    this.serverName,
    this.version,
    this.argoUrl,
    this.cliLogin,
  });

  factory ArgoApiStatus.fromJson(Json j) => ArgoApiStatus(
        crd: j['crd'] != false,
        found: j['found'] == true,
        reachable: j['reachable'] == true,
        auth: '${j['auth'] ?? 'none'}',
        authValid: j['authValid'] as bool?,
        username: j['username'] as String?,
        initialAdminAvailable: j['initialAdminAvailable'] == true,
        error: j['error'] as String?,
        serverNamespace: dig<String>(j, ['server', 'namespace']),
        serverName: dig<String>(j, ['server', 'service']),
        version: dig<String>(j, ['server', 'version']),
        argoUrl: (j['argoUrl'] as String?)?.isNotEmpty == true ? j['argoUrl'] as String : null,
        cliLogin: (j['cliLogin'] as String?)?.isNotEmpty == true ? j['cliLogin'] as String : null,
      );

  /// The command that logs the argocd CLI in via SSO for this Argo CD.
  String? get cliLoginCommand => argoUrl == null ? null : 'argocd login $argoUrl --sso --grpc-web';

  String get secretRef => '${serverNamespace ?? 'argocd'}/argocd-initial-admin-secret';
}

/// One resource from GET /api/argocd/diff.
class ArgoResourceDiff {
  final String group, kind, name;
  final String? namespace;

  /// Synced or OutOfSync.
  final String status;
  final bool hook;
  final bool requiresPruning;

  /// Cleaned YAML; null target = to be pruned, null live = to be created.
  final String? target;
  final String? live;

  ArgoResourceDiff({
    required this.group,
    required this.kind,
    required this.name,
    this.namespace,
    this.status = 'Synced',
    this.hook = false,
    this.requiresPruning = false,
    this.target,
    this.live,
  });

  factory ArgoResourceDiff.fromJson(Json j) {
    final ns = j['namespace'] as String?;
    return ArgoResourceDiff(
      group: '${j['group'] ?? ''}',
      kind: '${j['kind'] ?? ''}',
      name: '${j['name'] ?? ''}',
      namespace: ns == null || ns.isEmpty ? null : ns,
      status: '${j['status'] ?? 'Synced'}',
      hook: j['hook'] == true,
      requiresPruning: j['requiresPruning'] == true,
      target: j['target'] as String?,
      live: j['live'] as String?,
    );
  }

  String get key => '$group/$kind/${namespace ?? ''}/$name';
  bool get toCreate => live == null && target != null;
  bool get toPrune => target == null && live != null;
  bool get outOfSync => status == 'OutOfSync';

  /// Live → desired, so "+" is what a sync applies.
  late final List<DiffLine> lines = diffLines(live ?? '', target ?? '');
  bool get changed => lines.any((l) => l.op != DiffOp.same);

  /// Worth a "Diff" button.
  bool get hasDiff => changed || outOfSync;
}

/// GET /api/argocd/diff, or why it isn't available.
class ArgoDiffResult {
  final Map<String, ArgoResourceDiff> byKey;

  /// configured or session (when loaded).
  final String? auth;
  final String? serverNamespace;
  final ApiException? error;

  /// Filled when [error] means "connect first", for the connect options.
  final ArgoApiStatus? status;
  const ArgoDiffResult({this.byKey = const {}, this.auth, this.serverNamespace, this.error, this.status});

  bool get ok => error == null;

  /// The user can fix this by connecting (no token, or a rejected one).
  bool get needsAuth => error?.reason == 'NoToken' || error?.reason == 'Unauthorized';
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

/// `/api/argocd/*`. Tests set [debugOverride] (or subclass) to serve canned
/// JSON.
class ArgoDiffApi {
  final ApiClient api;
  final BackendHttp _http;
  ArgoDiffApi(this.api, {http.Client? httpClient}) : _http = BackendHttp(api, '/api/argocd/', httpClient: httpClient);

  static ArgoDiffApi Function(ApiClient api)? debugOverride;
  static final Expando<ArgoDiffApi> _byClient = Expando('ArgoDiffApi');
  static ArgoDiffApi of(ApiClient api) => debugOverride?.call(api) ?? (_byClient[api] ??= ArgoDiffApi(api));

  Future<dynamic> send(String method, String path, {Map<String, String?> query = const {}, Object? body}) async =>
      jsonBody(await _http.send(method, path, query: query, body: body));

  Future<ArgoApiStatus> status({String? namespace}) async =>
      ArgoApiStatus.fromJson(Map<String, dynamic>.from(await send('GET', 'status', query: {'namespace': namespace})));

  Future<ArgoApiStatus> setToken(String token, {String? context, String? namespace}) async => ArgoApiStatus.fromJson(
      Map<String, dynamic>.from(await send('POST', 'auth', body: {'token': token, 'context': ?context, 'namespace': ?namespace})));

  Future<ArgoApiStatus> clearToken({String? namespace}) async =>
      ArgoApiStatus.fromJson(Map<String, dynamic>.from(await send('DELETE', 'auth', query: {'namespace': namespace})));

  /// Use the argocd CLI's own login for this context (token stays in the
  /// CLI config; only the choice is saved).
  Future<ArgoApiStatus> useCli({String? namespace}) async =>
      ArgoApiStatus.fromJson(Map<String, dynamic>.from(await send('POST', 'auth/cli', body: {'namespace': ?namespace})));

  Future<ArgoApiStatus> useInitialAdmin({String? namespace}) async =>
      ArgoApiStatus.fromJson(Map<String, dynamic>.from(await send('POST', 'auth/initial-admin', body: {'namespace': ?namespace})));

  Future<Json> diff({String? namespace, required String name}) async =>
      Map<String, dynamic>.from(await send('GET', 'diff', query: {'namespace': namespace, 'name': name}));

  /// Loads an app's diffs; on a "connect first" error also loads the status.
  Future<ArgoDiffResult> load({String? namespace, required String name}) async {
    try {
      final j = await diff(namespace: namespace, name: name);
      final list = [for (final r in asMapList(j['resources'])) ArgoResourceDiff.fromJson(r)];
      return ArgoDiffResult(
        byKey: {for (final r in list) r.key: r},
        auth: j['auth'] as String?,
        serverNamespace: dig<String>(j, ['server', 'namespace']),
      );
    } on ApiException catch (e) {
      ArgoApiStatus? st;
      if (e.reason == 'NoToken' || e.reason == 'Unauthorized') {
        try {
          st = await status(namespace: namespace);
        } catch (_) {}
      }
      return ArgoDiffResult(error: e, status: st);
    } catch (e) {
      return ArgoDiffResult(error: ApiException(0, '$e'));
    }
  }
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

/// Diffs per app. An entry is reused while the app's [version] (sync
/// revision + reconciledAt) and the auth epoch are unchanged, so live watch
/// ticks don't refetch.
class ArgoDiffCache {
  static final Map<String, ({String version, Future<ArgoDiffResult> result})> _entries = {};

  /// Bumped on connect/disconnect so every app refetches.
  static int authEpoch = 0;

  static String appKey(PanelContext ctx) => '${ctx.api.base}|${ctx.app.currentContext}|${ctx.namespace ?? ''}/${ctx.name}';

  /// What a diff depends on: the synced revision(s) and the last comparison.
  static String versionOf(Json status) => [
        dig<String>(status, ['sync', 'revision']) ?? '',
        ...[for (final r in (dig<List>(status, ['sync', 'revisions']) ?? const [])) '$r'],
        '${status['reconciledAt'] ?? ''}',
        '$authEpoch',
      ].join('|');

  static Future<ArgoDiffResult> get(PanelContext ctx, {bool force = false}) {
    final key = appKey(ctx), version = versionOf(ctx.status);
    final hit = _entries[key];
    if (!force && hit != null && hit.version == version) return hit.result;
    final f = ArgoDiffApi.of(ctx.api).load(namespace: ctx.namespace, name: ctx.name);
    _entries[key] = (version: version, result: f);
    return f;
  }

  static void invalidateAll() {
    authEpoch++;
    _entries.clear();
  }

  @visibleForTesting
  static void reset() {
    _entries.clear();
    authEpoch = 0;
  }
}

// ---------------------------------------------------------------------------
// Connection strip
// ---------------------------------------------------------------------------

/// Shown above the managed resources: how to connect when diffs aren't
/// available, or (subtly) how they are obtained when they are.
class ArgoConnectStrip extends StatefulWidget {
  final PanelContext ctx;
  final ArgoDiffResult? result;
  final bool loading;

  /// Called after connecting or disconnecting.
  final VoidCallback onChanged;
  const ArgoConnectStrip({super.key, required this.ctx, required this.result, required this.onChanged, this.loading = false});

  @override
  State<ArgoConnectStrip> createState() => _ArgoConnectStripState();
}

class _ArgoConnectStripState extends State<ArgoConnectStrip> {
  bool _busy = false;
  String? _error;

  ArgoDiffApi get _api => ArgoDiffApi.of(widget.ctx.api);

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
      ArgoDiffCache.invalidateAll();
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the shared sign-in form (also in Integrations → Argo CD).
  Future<void> _connect() async {
    final changed = await showArgoCdSettings(context, namespace: widget.ctx.namespace);
    if (!changed || !mounted) return;
    ArgoDiffCache.invalidateAll();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.result;
    if (r == null) return const SizedBox.shrink();
    final small = theme.textTheme.bodySmall;
    final hint = theme.hintColor;

    if (r.ok) {
      // Connected: one quiet line.
      final via = switch (r.auth) { 'session' => 'session', 'cli' => 'argocd CLI login', _ => 'token' };
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Icon(Icons.link, size: 13, color: hint),
          const SizedBox(width: 4),
          Flexible(
            child: Text('Diffs via argocd-server · $via',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: hint)),
          ),
          if (widget.loading) ...[
            const SizedBox(width: 6),
            const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
          ],
          const SizedBox(width: 6),
          _LinkText(_busy ? 'Disconnecting…' : 'Disconnect',
              onTap: _busy ? null : () => _run(() => _api.clearToken(namespace: widget.ctx.namespace)),
              tooltip: switch (r.auth) {
                'session' => 'Forget the session',
                'cli' => 'Stop using the argocd CLI login for this context (the CLI stays logged in)',
                _ => 'Forget the saved token for this context',
              }),
        ]),
      );
    }

    final e = r.error!;
    if (!r.needsAuth) {
      // Not found / unreachable / forbidden: nothing to connect, just say why.
      final msg = switch (e.reason) {
        'NotFound' => 'Diffs need the Argo CD API server, which wasn\'t found in the cluster',
        'Unreachable' => 'Diffs unavailable: argocd-server is not reachable (${e.message})',
        _ => 'Diffs unavailable: ${e.message}',
      };
      return Padding(padding: const EdgeInsets.only(bottom: 4), child: InlineMessage(msg, icon: Icons.difference_outlined));
    }

    final rejected = e.reason == 'Unauthorized';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: chipFill(context),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.difference_outlined, size: 14, color: hint)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              rejected ? e.message : 'Connect to the Argo CD API to see diffs',
              style: small?.copyWith(fontWeight: FontWeight.w600, color: rejected ? severityColor(context, Severity.warn) : null),
            ),
          ),
          const SizedBox(width: 8),
          ArgoActionButton(label: 'Connect…', icon: Icons.link, onTap: _connect),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: InlineMessage(_error!, isError: true)),
      ]),
    );
  }
}

/// A compact outlined button with an icon (the sign-in options).
class ArgoActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;
  const ArgoActionButton({super.key, required this.label, required this.icon, this.onTap, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 26),
        textStyle: theme.textTheme.bodySmall,
      ),
      onPressed: onTap,
      icon: Icon(icon, size: 14),
      label: Text(label),
    );
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

class _LinkText extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  final String? tooltip;
  const _LinkText(this.text, {this.onTap, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = Hoverable(
      onTap: onTap,
      builder: (h) => Text(text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: onTap == null ? theme.hintColor : theme.colorScheme.primary,
            decoration: h ? TextDecoration.underline : null,
          )),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

// ---------------------------------------------------------------------------
// One resource's diff
// ---------------------------------------------------------------------------

/// The small "Diff" toggle on a resource row.
class DiffToggle extends StatelessWidget {
  final bool open;
  final bool compact;
  final VoidCallback onTap;
  const DiffToggle({super.key, required this.open, required this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = open ? theme.colorScheme.primary : theme.hintColor;
    return Tooltip(
      message: open ? 'Hide diff' : 'Show the Argo CD diff',
      child: Hoverable(
        onTap: onTap,
        builder: (h) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: open ? theme.colorScheme.primary.withValues(alpha: 0.15) : chipFill(context, hovered: h),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.difference_outlined, size: 12, color: c),
            if (!compact) ...[
              const SizedBox(width: 3),
              Text('Diff', style: theme.textTheme.labelSmall?.copyWith(color: c)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// The expanded diff of one resource: status, create/prune badges, +/-
/// counts and the unified diff (live → desired).
class ResourceDiffBlock extends StatelessWidget {
  final ArgoResourceDiff diff;
  const ResourceDiffBlock({super.key, required this.diff});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = diffStats(diff.lines);
    final small = theme.textTheme.labelSmall;
    Widget badge(String text, Severity s, String tip) => Tooltip(
          message: tip,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: severityColor(context, s).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
            child: Text(text, style: small?.copyWith(color: severityColor(context, s))),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8, left: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${diff.kind}/${diff.name}', style: monoStyle(context, size: 11, color: theme.hintColor)),
          ArgoBadge.sync(context, diff.status),
          if (diff.toCreate) badge('will be created', Severity.ok, 'Not in the cluster yet: a sync creates it'),
          if (diff.toPrune) badge('will be pruned', Severity.warn, 'Not in git any more: a sync with prune deletes it'),
          if (diff.hook) badge('hook', Severity.info, 'A sync hook: created during the sync'),
          if (diff.changed)
            Text.rich(TextSpan(children: [
              TextSpan(text: '+${stats.added}', style: TextStyle(color: severityColor(context, Severity.ok))),
              const TextSpan(text: ' '),
              TextSpan(text: '−${stats.removed}', style: TextStyle(color: severityColor(context, Severity.error))),
            ]), style: monoStyle(context, size: 11)),
          Tooltip(
            message: 'Copy the desired state',
            child: Hoverable(
              onTap: diff.target == null ? null : () => Clipboard.setData(ClipboardData(text: diff.target!)),
              builder: (h) => Icon(Icons.copy, size: 12, color: h ? theme.colorScheme.primary : theme.hintColor),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        if (!diff.changed)
          const Hint('No differences after Argo CD\'s normalisation')
        else
          DiffView(lines: diff.lines, shrinkWrap: true),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('− live   + desired', style: monoStyle(context, size: 10, color: theme.hintColor)),
        ),
      ]),
    );
  }
}
