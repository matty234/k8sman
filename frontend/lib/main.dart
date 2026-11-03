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
  const K8sManApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'k8sman',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: const Shell(),
      );
}
