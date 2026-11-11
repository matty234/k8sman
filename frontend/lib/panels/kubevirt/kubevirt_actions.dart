import '../../actions/actions.dart';
import '../../ui/terminal/vm_console.dart';
import '../panel.dart';

/// Actions the host adds to a kind's own panel actions, keyed by `group/Kind`
/// (`ResourceType.gk`). Lets a plugin wrap these kinds' panels while the
/// native features (serial console) stay available.
List<ResourceAction> hostKindActions(PanelContext ctx) => switch (ctx.type.gk) {
      'kubevirt.io/VirtualMachine' || 'kubevirt.io/VirtualMachineInstance' => [?vmConsoleAction(ctx)],
      _ => const [],
    };
