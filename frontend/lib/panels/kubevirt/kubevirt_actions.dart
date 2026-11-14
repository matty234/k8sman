import '../../actions/actions.dart';
import '../../ui/terminal/vm_console.dart';
import '../panel.dart';
import 'vm_export.dart';

/// Actions the host adds to a kind's own panel actions, keyed by `group/Kind`
/// (`ResourceType.gk`). Lets a plugin wrap these kinds' panels while the
/// native features (serial console, disk export) stay available.
List<ResourceAction> hostKindActions(PanelContext ctx) => switch (ctx.type.gk) {
      'kubevirt.io/VirtualMachine' => [?vmConsoleAction(ctx), ...vmExportActions(ctx)],
      'kubevirt.io/VirtualMachineInstance' => [?vmConsoleAction(ctx)],
      '/PersistentVolumeClaim' || 'export.kubevirt.io/VirtualMachineExport' => vmExportActions(ctx),
      _ => const [],
    };
