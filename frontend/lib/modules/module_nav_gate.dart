import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import 'modules.dart';

/// Shows a module page's sidebar row (`navGate` of its [AppPage]) only on
/// clusters where the module's [AppModule.detect] found what it integrates
/// with, and always while the page itself is open. Hidden while the check
/// is under way and when it says the integration isn't there. When it
/// found the integration but it fails (an error), the row still shows if
/// [showOnError] (Hubble: the page explains what's wrong); GPUs hide it,
/// as their failing check means nothing was found.
class ModuleNavGate extends StatelessWidget {
  final AppModule module;
  final Widget child;
  final bool showOnError;
  const ModuleNavGate({super.key, required this.module, required this.child, this.showOnError = true});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final ApiClient api;
    try {
      api = context.read<ApiClient>();
    } catch (_) {
      return const SizedBox.shrink(); // no backend in this tree (tests)
    }
    return ListenableBuilder(
      listenable: moduleStatuses,
      builder: (context, _) {
        final s = moduleStatuses.of(module, api, app.currentContext);
        final show = app.view == module.pages.first.view ||
            (s != null &&
                s.state != ModuleState.notInstalled &&
                s.state != ModuleState.checking &&
                (showOnError || s.state != ModuleState.error));
        return show ? child : const SizedBox.shrink();
      },
    );
  }
}
