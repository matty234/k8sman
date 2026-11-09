import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api/client.dart';
import 'app/backend.dart';
import 'app/links.dart';
import 'app/updates/github_releases.dart';
import 'app/updates/update_controller.dart';
import 'app/updates/update_ui.dart';
import 'app/window_chrome.dart';
import 'state/app_state.dart';
import 'state/log_dock.dart';
import 'modules/modules.dart' show kindHomes;
import 'prometheus/metric_history_chart.dart' show ChartHoverScope;
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
  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<BackendController>.value(value: backend),
        ChangeNotifierProvider<LogDock>.value(value: dock),
        ChangeNotifierProvider<UpdateController>.value(value: updates),
      ],
      child: const K8sManApp(),
    ),
  );
  backend.start();
  updates.start();
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
