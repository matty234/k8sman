import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../app/links.dart';
import '../modules/modules.dart';
import '../state/app_state.dart';

/// What [followLink] did.
enum LinkOutcome {
  opened,

  /// The user declined the context switch.
  cancelled,

  /// The link's context isn't in the kubeconfig: nothing changed.
  missingContext,

  /// Switching to the link's context failed (the error screen says why).
  failed,

  /// The cluster doesn't serve the kind, or the page doesn't exist here.
  notFound,
}

// ---- building links ----

/// A link to [t] on the current context.
AppLink objectLink(AppState app, DetailTarget t) => AppLink(
      context: app.currentContext,
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
    kind: type.kind,
    group: type.group,
    namespace: type.namespaced && scope.namespaces.length == 1 ? scope.namespaces.single : null,
  );
}

/// A link to page [v] on the current context.
AppLink pageLink(AppState app, MainView v) => AppLink(context: app.currentContext, view: v.name);

/// Copies [link]: the https form, or the `k8sman://` form when the user
/// chose it in Settings or holds ⌥ (Alt) while choosing Copy Link.
void copyLink(BuildContext context, AppState app, AppLink link) {
  final appForm = app.appLinks || HardwareKeyboard.instance.isAltPressed;
  Clipboard.setData(ClipboardData(text: appForm ? link.appUrl : link.webUrl));
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(appForm ? 'App link copied' : 'Link copied'), duration: const Duration(seconds: 1)));
}

// ---- following links ----

/// Opens [link]: never runs anything, only navigates. A link to another
/// context asks first ([confirm] gets the title and message); a context the
/// kubeconfig doesn't have, or a kind or page this cluster lacks, is
/// reported through [notice] with nothing switched.
Future<LinkOutcome> followLink(
  AppState app,
  AppLink link, {
  required Future<bool> Function(String title, String message) confirm,
  required void Function(String message) notice,
}) async {
  final ctx = link.context;
  if (!app.contexts.any((c) => c.name == ctx)) {
    notice('This link is for context $ctx, which isn\'t in your kubeconfig.');
    return LinkOutcome.missingContext;
  }
  if (ctx != app.currentContext) {
    final what = link.kind == null && link.view == null ? ctx : '${link.what} in $ctx';
    final from = app.currentContext.isEmpty ? '' : ' This switches from ${app.currentContext}.';
    if (!await confirm('Open link?', 'Open $what?$from')) return LinkOutcome.cancelled;
    await app.switchContext(ctx);
    if (app.currentContext != ctx || app.error != null) return LinkOutcome.failed;
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
  );
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
