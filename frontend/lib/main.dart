import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/client.dart';
import 'state/app_state.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

void main() {
  final api = ApiClient();
  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AppState>(create: (_) => AppState(api)..init()),
      ],
      child: const K8sManApp(),
    ),
  );
}

class K8sManApp extends StatelessWidget {
  final ThemeMode themeMode;
  const K8sManApp({super.key, this.themeMode = ThemeMode.system});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'k8sman',
        debugShowCheckedModeBanner: false,
        scrollBehavior: const AppScrollBehavior(),
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        // Follow the system appearance, like a native app (the window's
        // vibrancy follows it too).
        themeMode: themeMode,
        home: const Shell(),
      );
}
