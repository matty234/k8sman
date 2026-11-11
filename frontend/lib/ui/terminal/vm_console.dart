import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../panels/panel.dart';
import '../../state/app_state.dart';
import '../../state/log_dock.dart';
import 'exec_protocol.dart';
import 'terminal_tab.dart';

/// Action id for "Serial console" on a KubeVirt VM / VMI.
const String kVmConsoleActionId = 'vm-console';

/// Opens the serial console of VMI [name] (a VM's console is its VMI's) as a
/// dock tab, like a pod terminal. Null (with a message) in read-only mode.
TerminalTab? openVmConsole(BuildContext context, String namespace, String name) {
  final app = context.read<AppState>();
  if (app.readOnly) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('The serial console is disabled in read-only mode')));
    return null;
  }
  final tab = TerminalTab(
    transport: execTransportFor(context.read<ApiClient>()),
    request: ExecRequest.vmConsole(namespace: namespace, name: name),
  );
  context.read<LogDock>().add(tab);
  return tab;
}

/// "Serial console" action for a VirtualMachine or VirtualMachineInstance,
/// or null unless it is running (VMI `status.phase`, VM
/// `status.printableStatus` / `status.ready`) and the context is writable.
ResourceAction? vmConsoleAction(PanelContext ctx) {
  if (ctx.app.readOnly) return null;
  final status = ctx.status;
  final running = ctx.type.kind == 'VirtualMachineInstance'
      ? status['phase'] == 'Running'
      : status['printableStatus'] == 'Running' || status['ready'] == true;
  final ns = ctx.namespace;
  if (!running || ns == null) return null;
  return ResourceAction(
    id: kVmConsoleActionId,
    label: 'Serial console',
    icon: Icons.terminal,
    tooltip: 'Open the VM serial console (bottom panel)',
    run: (context) async => openVmConsole(context, ns, ctx.name),
  );
}
