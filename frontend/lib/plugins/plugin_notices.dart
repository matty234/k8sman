/// The plugin directory's quiet notices outside Settings: plugins that
/// match what the current cluster serves, and updates for installed
/// directory plugins (docs/PLUGINS.md §10). Checked on connecting to a
/// context, daily, and after a plugin change; the backend reuses its
/// cached index, so a context switch doesn't fetch it again. Nothing
/// installs from here: Review opens Settings ▸ Integrations, at
/// Marketplace for suggestions and at Installed (the Plugins group) for
/// updates.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart' show Json;
import '../state/app_state.dart';
import '../ui/settings/integrations_settings.dart' show IntegrationsPage;
import '../ui/settings/settings_page.dart' show showSettings;
import '../ui/theme.dart';
import '../util/k8s.dart' show asMapList;
import 'plugin_api.dart';
import 'plugin_host.dart';

class PluginNotices extends ChangeNotifier {
  AppState? _app;
  Timer? _daily;
  int _generation = 0;
  String _checkedContext = '';
  bool _checking = false;

  /// The directory's status (ok, not-configured, offline, …; '' before
  /// the first check), and the context the suggestions are for.
  String status = '';
  String context = '';
  List<DirectoryPlugin> updates = const [];
  List<DirectoryPlugin> suggested = const [];
  bool unseenSuggestions = false;
  bool unseenUpdates = false;

  /// Notices hidden this session (shown once, then left alone): the
  /// context and plugin ids they were for.
  final Set<String> _hidden = {};

  /// Follows [app]: checks on each connect, daily, and after plugin
  /// changes (an install, an automatic update).
  void attach(AppState app) {
    if (identical(_app, app)) return;
    _app?.removeListener(_onApp);
    _app = app;
    app.addListener(_onApp);
    pluginHost.addListener(_onPlugins);
    _daily?.cancel();
    _daily = Timer.periodic(const Duration(days: 1), (_) => check());
  }

  void _onApp() {
    final app = _app;
    if (app == null || app.loading || app.error != null || app.currentContext.isEmpty) return;
    if (app.currentContext != _checkedContext) check();
  }

  void _onPlugins() {
    final g = pluginHost.generation;
    if (g == _generation) return;
    final first = _generation == 0;
    _generation = g;
    if (!first) check();
  }

  /// Asks the backend for the notices of the current context.
  Future<void> check() async {
    final app = _app;
    if (app == null || _checking) return;
    _checking = true;
    _checkedContext = app.currentContext;
    try {
      take(await app.api.pluginNotices());
    } catch (_) {
      // No plugins on this backend, or it's away: no notices.
      take(const {'status': 'offline'});
    } finally {
      _checking = false;
    }
    // The context changed while asking.
    if (app.currentContext != _checkedContext) unawaited(check());
  }

  /// Takes `GET /api/plugins/directory/updates`.
  void take(Json j) {
    status = '${j['status'] ?? ''}';
    context = '${j['context'] ?? ''}';
    updates = [for (final p in asMapList(j['updates'])) DirectoryPlugin.fromJson(p)];
    suggested = [for (final p in asMapList(j['suggested'])) DirectoryPlugin.fromJson(p)];
    unseenSuggestions = j['unseenSuggestions'] == true;
    unseenUpdates = j['unseenUpdates'] == true;
    notifyListeners();
  }

  /// Takes the updates from Browse (the Plugins page's own check).
  void takeDirectory(DirectoryState d) {
    if (d.status != 'ok') return;
    updates = d.updates;
    unseenUpdates = unseenUpdates && updates.isNotEmpty;
    notifyListeners();
  }

  String get _suggestionKey => 's|$context|${[for (final p in suggested) p.id].join(',')}';
  String get _updateKey => 'u|${[for (final p in updates) '${p.id}@${p.version}'].join(',')}';

  /// "3 plugins match what's installed on this cluster", when there's
  /// something new for [currentContext].
  bool showSuggestions(String currentContext) =>
      status == 'ok' && unseenSuggestions && suggested.isNotEmpty && context == currentContext && !_hidden.contains(_suggestionKey);

  /// "Updates for 2 plugins", when there's an update not yet seen.
  bool get showUpdates => status == 'ok' && unseenUpdates && updates.isNotEmpty && !_hidden.contains(_updateKey);

  /// Hides the suggestions notice and remembers (per context, in
  /// settings) the plugins it was for.
  Future<void> dismissSuggestions() async {
    _hidden.add(_suggestionKey);
    unseenSuggestions = false;
    notifyListeners();
    try {
      await _app?.api.markPluginNoticesSeen(context: context, suggestions: [for (final p in suggested) p.id]);
    } catch (_) {}
  }

  /// Hides the updates notice and remembers the versions it was for.
  Future<void> dismissUpdates() async {
    _hidden.add(_updateKey);
    unseenUpdates = false;
    notifyListeners();
    try {
      await _app?.api.markPluginNoticesSeen(context: context, updates: [for (final p in updates) '${p.id}@${p.version}']);
    } catch (_) {}
  }

  @override
  void dispose() {
    _daily?.cancel();
    _app?.removeListener(_onApp);
    pluginHost.removeListener(_onPlugins);
    super.dispose();
  }
}

/// The app's plugin notices (attached in main).
final pluginNotices = PluginNotices();

/// The notices, one line each, for the bottom-right corner (above the
/// app's own update banner). Hidden on the Settings page.
class PluginNoticeBanners extends StatelessWidget {
  final PluginNotices notices;
  const PluginNoticeBanners({super.key, required this.notices});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState?>();
    return ListenableBuilder(
      listenable: notices,
      builder: (context, _) {
        if (app == null || app.view == MainView.settings) return const SizedBox.shrink();
        final n = notices.suggested.length, u = notices.updates.length;
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (notices.showSuggestions(app.currentContext))
            PluginNotice(
              key: const ValueKey('plugin-notice-suggestions'),
              icon: Icons.extension_outlined,
              text: n == 1 ? '1 plugin matches what’s installed on this cluster' : '$n plugins match what’s installed on this cluster',
              onReview: () {
                notices.dismissSuggestions();
                showSettings(app, integrations: IntegrationsPage.marketplace);
              },
              onDismiss: notices.dismissSuggestions,
            ),
          if (notices.showUpdates)
            PluginNotice(
              key: const ValueKey('plugin-notice-updates'),
              icon: Icons.upgrade,
              text: u == 1 ? 'Update for 1 plugin' : 'Updates for $u plugins',
              onReview: () {
                notices.dismissUpdates();
                showSettings(app, module: pluginsModuleId);
              },
              onDismiss: notices.dismissUpdates,
            ),
        ]);
      },
    );
  }
}

/// A calm one-line card, styled like the app's update banner.
class PluginNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onReview;
  final VoidCallback onDismiss;
  const PluginNotice({super.key, required this.icon, required this.text, required this.onReview, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surfaceContainerHigh,
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.of(context).separator)),
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Flexible(child: Text(text, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
            const SizedBox(width: 12),
            TextButton(onPressed: onReview, child: const Text('Review')),
            // No tooltip: the notice sits above the Navigator (no Overlay).
            IconButton(
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              icon: Icon(Icons.close, color: theme.hintColor, semanticLabel: 'Dismiss'),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A small count (the updates waiting) beside the Plugins entry.
class CountBadge extends StatelessWidget {
  final int count;
  final String? tooltip;
  const CountBadge(this.count, {super.key, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(9)),
      child: Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimary, fontWeight: FontWeight.w600)),
    );
    return tooltip == null ? badge : Tooltip(message: tooltip!, child: badge);
  }
}
