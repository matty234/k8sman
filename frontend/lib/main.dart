import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api/client.dart';
import 'app/backend.dart';
import 'app/diagnostics/diagnostics_hooks.dart';
import 'app/diagnostics/diagnostics_log.dart';
import 'app/links.dart';
import 'app/updates/github_releases.dart';
import 'app/updates/update_controller.dart';
import 'app/updates/update_ui.dart';
import 'app/window_chrome.dart';
import 'plugins/plugin_notices.dart' show pluginNotices;
import 'state/app_state.dart';
import 'state/issues_feed.dart';
import 'state/log_dock.dart';
import 'modules/modules.dart' show kindHomes, pageFor;
import 'prometheus/metric_history_chart.dart' show ChartHoverScope;
import 'ui/settings/settings_page.dart' show SettingsSection, showSettings;
import 'ui/shell.dart';
import 'ui/theme.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  WindowChrome.init();
  // Windows and Linux open k8sman:// links by launching the app with the
  // URL as an argument (macOS sends them over the window channel).
  LinkInbox.receiveArgs(args);
  final api = ApiClient();
  final app = AppState(api)..kindHomes = kindHomes;
  // Spawns the embedded backend (macOS/Windows app) or uses K8SMAN_BACKEND, then
  // loads the app state whenever the backend (re)connects.
  final dock = LogDock(api);
  final issues = IssuesFeed(api, app: app, dock: dock);
  final backend = BackendController(
    api,
    onReady: () {
      dock.loadPrefs();
      return app.backendConnected();
    },
  );
  // Updates: background check, banner, About panel. Sparkle on macOS; on
  // Windows and Linux a GitHub "latest release" check linking to the download.
  final noSparkle = !kIsWeb && defaultTargetPlatform != TargetPlatform.macOS;
  final updates = UpdateController(github: noSparkle ? GitHubReleases() : null, openUrl: launchUrl);
  _installDiagnostics(app, updates);
  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<BackendController>.value(value: backend),
        ChangeNotifierProvider<LogDock>.value(value: dock),
        ChangeNotifierProvider<IssuesFeed>.value(value: issues),
        ChangeNotifierProvider<UpdateController>.value(value: updates),
      ],
      child: const K8sManApp(),
    ),
  );
  backend.start();
  issues.start();
  updates.start();
  // Plugin directory notices: suggestions for each context, and updates.
  pluginNotices.attach(app);
}

/// Errors go to the local diagnostics log (Settings ▸ Diagnostics), with
/// where in the app they happened and the cluster's names to redact.
void _installDiagnostics(AppState app, UpdateController updates) {
  diagnostics
    ..file = DiagnosticsLog.defaultFile()
    ..appVersion = (() => updates.info.version.isNotEmpty ? updates.info.displayVersion : (buildVersion.isEmpty ? 'dev' : buildVersion))
    ..place = () {
      final page = app.view == MainView.resources
          ? (app.selectedType == null ? 'Resources' : '${app.selectedType!.kind} table')
          : (pageFor(app.view)?.label ?? app.view.name);
      final d = app.detail;
      return d == null ? page : '$page › ${d.type.kind} inspector';
    }
    ..sensitiveTerms = () => [
          app.currentContext,
          for (final c in app.contexts) ...[c.name, c.cluster, c.user],
          ...app.namespaces,
          ?app.detail?.name,
          ?app.detail?.namespace,
        ];
  installDiagnostics(diagnostics, onReport: () => showSettings(app, section: SettingsSection.diagnostics));
  diagnostics.load();
}

class K8sManApp extends StatelessWidget {
  final ThemeMode themeMode;
  const K8sManApp({super.key, this.themeMode = ThemeMode.system});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'k8sman',
        debugShowCheckedModeBanner: false,
        scrollBehavior: const AppScrollBehavior(),
        // No 200ms theme cross-fade: text/colours appear immediately (native feel).
        themeAnimationDuration: Duration.zero,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        // Follow the system appearance, like a native app (the window's
        // vibrancy follows it too).
        themeMode: themeMode,
        navigatorKey: context.read<UpdateController?>()?.navigatorKey,
        builder: (context, child) => WindowChromeScope(child: UpdateHost(child: child ?? const SizedBox.shrink())),
        // One shared chart hover: hovering any chart moves the cursor on
        // every other chart on screen to the same time.
        home: const ChartHoverScope(child: BackendGate(child: Shell())),
      );
}
