import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../app/links.dart';
import '../modules/modules.dart';
import 'settings/integrations_settings.dart' show IntegrationsPage;
import '../plugins/plugins_settings.dart' show pluginInstallRequest;
import '../state/app_state.dart';
import 'context_badge.dart';
import 'settings/settings_page.dart' show showSettings;
import 'widgets/common.dart' show copyToClipboard;

/// What [followLink] did.
enum LinkOutcome {
  opened,

  /// The user declined the context switch.
  cancelled,

  /// No context here matches the link's cluster, and none was chosen:
  /// nothing changed.
  missingContext,

  /// Switching to the link's context failed (the error screen says why).
  failed,

  /// The cluster doesn't serve the kind, or the page doesn't exist here.
  notFound,
}

// ---- building links ----

/// The current context's cluster fingerprint, when the backend gave one.
String? _cluster(AppState app) {
  for (final c in app.contexts) {
    if (c.name == app.currentContext) return c.fingerprint;
  }
  return null;
}

/// A link to [t] on the current context.
AppLink objectLink(AppState app, DetailTarget t) => AppLink(
      context: app.currentContext,
      cluster: _cluster(app),
      kind: t.type.kind,
      group: t.type.group,
      name: t.name,
      namespace: t.type.namespaced ? t.namespace : null,
    );

/// A link to [type]'s table on the current context, in the current
/// namespace when exactly one is chosen (a set of namespaces can't be
/// linked: the table opens in all of them).
AppLink tableLink(AppState app, ResourceType type) {
  final scope = app.namespaceScope;
  return AppLink(
    context: app.currentContext,
    cluster: _cluster(app),
    kind: type.kind,
    group: type.group,
    namespace: type.namespaced && scope.namespaces.length == 1 ? scope.namespaces.single : null,
  );
}

/// A link to page [v] on the current context.
AppLink pageLink(AppState app, MainView v) => AppLink(context: app.currentContext, cluster: _cluster(app), view: v.name);

/// Copies [link]: the https form, or the `k8sman://` form when the user
/// chose it in Settings or holds ⌥ (Alt) while choosing Copy Link.
void copyLink(BuildContext context, AppState app, AppLink link) {
  final appForm = app.appLinks || HardwareKeyboard.instance.isAltPressed;
  copyToClipboard(context, appForm ? link.appUrl : link.webUrl, message: appForm ? 'App link copied' : 'Link copied');
}

// ---- following links ----

/// A context picked in the link chooser, and whether to remember it for
/// the link's cluster.
typedef LinkChoice = ({String context, bool remember});

/// Asks which context to open a link in. [missing]: no context matched,
/// so [message] says so and the list waits behind "Choose a context…".
/// [canRemember] offers "Always open links for this cluster here".
typedef LinkChooser = Future<LinkChoice?> Function(String message, List<String> contexts, {required bool missing, required bool canRemember});

/// Opens [link]: never runs anything, only navigates.
///
/// The local context is found by the link's cluster fingerprint (`c`):
/// first a remembered mapping, then the contexts with that fingerprint
/// (several: the current one, else the one named like the link's `ctx`,
/// else [choose]). Without a fingerprint match, a context named `ctx`;
/// failing that, [choose] over every context. A switch the user didn't
/// pick in the chooser asks first ([confirm] gets the title and message).
/// A kind or page this cluster lacks is reported through [notice].
Future<LinkOutcome> followLink(
  AppState app,
  AppLink link, {
  required Future<bool> Function(String title, String message) confirm,
  required void Function(String message) notice,
  required LinkChooser choose,
}) async {
  final names = [for (final c in app.contexts) c.name];
  final fp = link.cluster;
  String? ctx;
  var byName = false, chosen = false;

  Future<bool> pick(String message, List<String> options, {required bool missing}) async {
    final choice = await choose(message, options, missing: missing, canRemember: fp != null);
    if (choice == null) return false;
    ctx = choice.context;
    chosen = true;
    if (choice.remember && fp != null) app.setLinkCluster(fp, choice.context);
    return true;
  }

  if (fp != null) {
    final mapped = app.linkClusterMap[fp];
    final same = [for (final c in app.contexts) if (c.fingerprint == fp) c.name];
    if (mapped != null && names.contains(mapped)) {
      ctx = mapped;
    } else if (same.length == 1) {
      ctx = same.single;
    } else if (same.contains(app.currentContext)) {
      ctx = app.currentContext;
    } else if (same.contains(link.context)) {
      ctx = link.context;
    } else if (same.isNotEmpty) {
      if (!await pick('Several of your contexts reach this cluster. Open ${link.what} in:', same, missing: false)) {
        return LinkOutcome.cancelled;
      }
    }
  }
  if (ctx == null && names.contains(link.context)) {
    ctx = link.context;
    byName = true;
  }
  if (ctx == null &&
      !await pick('This link is for a cluster that isn\'t in your kubeconfig (context ${link.context}).', names, missing: true)) {
    return LinkOutcome.missingContext;
  }
  final target = ctx!;

  if (target != app.currentContext) {
    if (!chosen) {
      final what = link.kind == null && link.view == null ? target : '${link.what} in $target';
      final from = app.currentContext.isEmpty ? '' : ' This switches from ${app.currentContext}.';
      final note = byName ? ' Matched by context name.' : '';
      if (!await confirm('Open link?', 'Open $what?$from$note')) return LinkOutcome.cancelled;
    }
    await app.switchContext(target);
    if (app.currentContext != target || app.error != null) return LinkOutcome.failed;
  }

  final view = link.view;
  if (view != null) {
    final v = MainView(view);
    if (!pageEnabled(app, v)) {
      notice('This link is for a page k8sman doesn\'t have here ($view).');
      return LinkOutcome.notFound;
    }
    app.showView(v);
    return LinkOutcome.opened;
  }

  final kind = link.kind;
  if (kind == null) return LinkOutcome.opened;
  // No group: the core kind, else the only kind of that name.
  var type = app.typeFor(link.group, kind);
  if (type == null && link.group.isEmpty) {
    final named = app.types.where((t) => t.kind == kind).toList();
    if (named.length == 1) type = named.single;
  }
  if (type == null) {
    notice('${app.currentContext} doesn\'t serve ${link.group.isEmpty ? kind : '$kind (${link.group})'}.');
    return LinkOutcome.notFound;
  }
  final ns = type.namespaced ? link.namespace : null;
  final name = link.name;
  if (name != null && type.namespaced && ns == null) {
    notice('This link names a ${type.kind} without its namespace.');
    return LinkOutcome.notFound;
  }
  final scope = ns == null || app.namespaceScope.contains(ns) ? null : NamespaceScope.single(ns);
  app.openTable(type.group, type.kind, scope: scope);
  // A missing object gets the inspector's normal not-found state.
  if (name != null) app.openDetail(DetailTarget(type: type, name: name, namespace: ns));
  return LinkOutcome.opened;
}

/// Opens [url] from outside the app (see [LinkInbox]) once the launch has
/// settled, asking and reporting with dialogs.
Future<void> openIncomingLink(BuildContext context, AppState app, String url) async {
  await app.launched.future;
  while (app.loading) {
    // A connect in flight: wait for it to land.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (!context.mounted) return;
  // k8sman://plugins/install?id=<id> (the plugin directory's Install
  // buttons): Settings ▸ Integrations ▸ Marketplace, which asks for consent.
  final u = Uri.tryParse(url);
  if (u != null && u.scheme == 'k8sman' && u.host == 'plugins' && u.path == '/install') {
    final id = u.queryParameters['id'] ?? '';
    if (!RegExp(r'^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$').hasMatch(id)) {
      await _notice(context, 'This plugin link doesn\'t name a plugin.');
      return;
    }
    pluginInstallRequest.value = id;
    showSettings(app, integrations: IntegrationsPage.marketplace);
    return;
  }
  final link = AppLink.parse(url);
  if (link == null) {
    await _notice(context, 'This isn\'t a k8sman link k8sman can open.');
    return;
  }
  await followLink(
    app,
    link,
    confirm: (title, message) async =>
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: SizedBox(width: 420, child: Text(message)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(autofocus: true, onPressed: () => Navigator.pop(context, true), child: const Text('Switch')),
            ],
          ),
        ) ==
        true,
    notice: (m) => _notice(context, m),
    choose: (message, contexts, {required missing, required canRemember}) async {
      if (!context.mounted) return null;
      return showDialog<LinkChoice>(
        context: context,
        builder: (context) => _ContextChooser(message: message, contexts: contexts, missing: missing, canRemember: canRemember),
      );
    },
  );
}

/// Picks the context a link opens in. With [missing], the message comes
/// first and the list waits behind "Choose a context…".
class _ContextChooser extends StatefulWidget {
  final String message;
  final List<String> contexts;
  final bool missing;
  final bool canRemember;
  const _ContextChooser({required this.message, required this.contexts, required this.missing, required this.canRemember});

  @override
  State<_ContextChooser> createState() => _ContextChooserState();
}

class _ContextChooserState extends State<_ContextChooser> {
  late bool _listing = !widget.missing;
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = context.read<AppState>().currentContext;
    return AlertDialog(
      title: Text(widget.missing ? 'Cluster not found' : 'Open link in…'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.message),
          if (_listing) ...[
            const SizedBox(height: 12),
            if (widget.contexts.isEmpty) Text('No contexts in this kubeconfig.', style: TextStyle(color: theme.hintColor)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView(shrinkWrap: true, children: [
                for (final c in widget.contexts)
                  ListTile(
                    key: ValueKey('link-context-$c'),
                    dense: true,
                    leading: NamedContextBadge(c, size: 18),
                    title: Text(c, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: c == current ? Text('current', style: TextStyle(color: theme.hintColor)) : null,
                    onTap: () => Navigator.pop(context, (context: c, remember: _remember)),
                  ),
              ]),
            ),
            if (widget.canRemember)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? false),
                title: const Text('Always open links for this cluster here'),
              ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (!_listing) FilledButton(autofocus: true, onPressed: () => setState(() => _listing = true), child: const Text('Choose a context…')),
      ],
    );
  }
}

Future<void> _notice(BuildContext context, String message) {
  if (!context.mounted) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Can\'t open link'),
      content: SizedBox(width: 420, child: Text(message)),
      actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ),
  );
}
