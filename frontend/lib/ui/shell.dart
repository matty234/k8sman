import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'detail/detail_sidebar.dart';
import 'resource_nav.dart';
import 'resource_table.dart';
import 'widgets/common.dart';

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
    if (app.loading && app.types.isEmpty) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (app.error != null && app.types.isEmpty) {
      return Scaffold(
        body: Center(
          child: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              InlineMessage('Cannot reach the k8sman backend: ${app.error}', isError: true),
              const SizedBox(height: 8),
              const Text('Start it with `make backend` (listens on 127.0.0.1:7443).'),
              const SizedBox(height: 12),
              FilledButton(onPressed: app.init, child: const Text('Retry')),
            ]),
          ),
        ),
      );
    }
    final type = app.selectedType;
    return Scaffold(
      body: LayoutBuilder(builder: (context, box) {
        final maxSidebar = (box.maxWidth - 220 - 360).clamp(320.0, 1400.0);
        final sidebar = _sidebarWidth.clamp(320.0, maxSidebar);
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(width: 220, child: ResourceNav()),
          const VerticalDivider(width: 1),
          Expanded(
            child: type == null ? const Center(child: Text('Select a resource kind')) : ResourceTableView(type: type),
          ),
          if (app.detail != null) ...[
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (d) => setState(() => _sidebarWidth = (sidebar - d.delta.dx).clamp(320.0, maxSidebar)),
                child: const SizedBox(width: 5, child: VerticalDivider(width: 5)),
              ),
            ),
            SizedBox(width: sidebar, child: const DetailSidebar()),
          ],
        ]);
      }),
    );
  }
}
