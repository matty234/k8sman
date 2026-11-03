import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/client.dart';
import 'app/backend.dart';
import 'app/updates/update_controller.dart';
import 'app/updates/update_ui.dart';
import 'app/window_chrome.dart';
import 'state/app_state.dart';
import 'state/log_dock.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WindowChrome.init();
  final api = ApiClient();
  final app = AppState(api);
  // Spawns the embedded backend (macOS app) or uses K8SMAN_BACKEND, then
  // loads the app state whenever the backend (re)connects.
  final backend = BackendController(api, onReady: app.backendConnected);
  // Sparkle updates: daily background check, banner, About panel.
  final updates = UpdateController();
  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<BackendController>.value(value: backend),
        ChangeNotifierProvider<LogDock>(create: (_) => LogDock(api)),
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
        home: const BackendGate(child: Shell()),
      );
}
