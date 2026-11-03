import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'detail/detail_sidebar.dart';
import 'overview/overview_view.dart';
import 'portforward/portforward_view.dart';
import 'resource_nav.dart';
import 'resource_table.dart';
import 'theme.dart';
import 'widgets/common.dart';

const _navWidth = 232.0;

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  double _sidebarWidth = 560;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    if (app.loading && app.types.isEmpty) {
      return const Scaffold(body: WindowDragArea(child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator()))));
    }
    if (app.error != null && app.types.isEmpty) {
      return Scaffold(
        body: WindowDragArea(
          child: Center(
            child: SizedBox(
              width: 460,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Cannot reach the k8sman backend', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                InlineMessage('${app.error}', isError: true),
                const SizedBox(height: 8),
                Text('Start it with `make backend` (listens on 127.0.0.1:7443).', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                const SizedBox(height: 16),
                FilledButton(onPressed: app.init, child: const Text('Retry')),
              ]),
            ),
          ),
        ),
      );
    }
    final type = app.selectedType;
    return Scaffold(
      // On macOS the nav shows the window's sidebar vibrancy through.
      backgroundColor: nativeMacChrome ? Colors.transparent : null,
      body: LayoutBuilder(builder: (context, box) {
        final maxSidebar = (box.maxWidth - _navWidth - 360).clamp(320.0, 1400.0);
        final sidebar = _sidebarWidth.clamp(320.0, maxSidebar);
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(width: _navWidth, child: ResourceNav()),
          Container(width: 1, color: colors.separator),
          Expanded(
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: switch (app.view) {
                MainView.overview => const OverviewView(),
                MainView.portForwards => const PortForwardView(),
                MainView.resources => type == null
                    ? WindowDragArea(child: Center(child: Text('Select a resource kind', style: TextStyle(color: theme.hintColor))))
                    : ResourceTableView(type: type),
              },
            ),
          ),
          if (app.detail != null) ...[
            // Hairline splitter with a wider grab area.
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => setState(() => _sidebarWidth = (sidebar - d.delta.dx).clamp(320.0, maxSidebar)),
                child: SizedBox(
                  width: 5,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(width: 1, color: colors.separator),
                    Expanded(child: ColoredBox(color: colors.inspector)),
                  ]),
                ),
              ),
            ),
            SizedBox(width: sidebar - 4, child: ColoredBox(color: colors.inspector, child: const DetailSidebar())),
          ],
        ]);
      }),
    );
  }
}
