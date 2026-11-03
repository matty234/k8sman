import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../../actions/actions.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import 'exec_protocol.dart';
import 'terminal_tab.dart';

/// Dark palette used in both app themes (terminals read best dark).
const terminalTheme = TerminalTheme(
  cursor: Color(0xFFE6E6E9),
  selection: Color(0x660A84FF),
  foreground: Color(0xFFDCDCE0),
  background: Color(0xFF141518),
  black: Color(0xFF1E1F23),
  red: Color(0xFFFF6B61),
  green: Color(0xFF4CC38A),
  yellow: Color(0xFFE9B04A),
  blue: Color(0xFF5AA9FF),
  magenta: Color(0xFFC98BF2),
  cyan: Color(0xFF4FC6D9),
  white: Color(0xFFCFCFD4),
  brightBlack: Color(0xFF6E6F78),
  brightRed: Color(0xFFFF8A80),
  brightGreen: Color(0xFF6FDCA5),
  brightYellow: Color(0xFFF5C76E),
  brightBlue: Color(0xFF85C0FF),
  brightMagenta: Color(0xFFDDACFA),
  brightCyan: Color(0xFF7ED9E8),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFE9B04A),
  searchHitBackgroundCurrent: Color(0xFFFF9F0A),
  searchHitForeground: Color(0xFF000000),
);

/// An interactive terminal for one [TerminalTab]: toolbar, the xterm view
/// (which sizes the remote TTY), and exited / error / no-shell states.
///
/// While focused, keystrokes go to the terminal. Only ⌘ shortcuts reach the
/// app (⌘J dock, ⌘I inspector, …); ⌘C copies a selection, ⌘V pastes,
/// ⌘+/⌘−/⌘0 change the font size and ⌘K clears.
class TerminalSession extends StatefulWidget {
  final TerminalTab session;
  const TerminalSession({super.key, required this.session});

  @override
  State<TerminalSession> createState() => _TerminalSessionState();
}

class _TerminalSessionState extends State<TerminalSession> {
  final _focus = FocusNode(debugLabel: 'terminal');
  bool _focused = false;

  TerminalTab get s => widget.session;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted && _focus.hasFocus != _focused) setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // ---- actions ----------------------------------------------------------------

  Future<void> _copy() async {
    final t = s.selectedText;
    if (t == null || t.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: t));
    s.controller.clearSelection();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null && d!.text!.isNotEmpty) s.paste(d.text!);
    _focus.requestFocus();
  }

  void _clear() {
    s.terminal.write('\x1b[H\x1b[2J\x1b[3J');
    if (s.phase == TerminalPhase.running) s.terminal.textInput('\x0c'); // ask the shell to redraw its prompt
    _focus.requestFocus();
  }

  void _restart({String? shell, List<String>? command}) {
    s.restart(shell: shell, command: command);
    _focus.requestFocus();
  }

  Future<void> _customCommand() async {
    final ctl = TextEditingController(text: s.request.command == null ? '' : shellJoinArgs(s.request.command!));
    final cmd = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run a command'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Executed directly (no shell), e.g. /bin/bash -l, python3, redis-cli.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('terminal-command-field'),
              controller: ctl,
              autofocus: true,
              style: monoStyle(context),
              decoration: const InputDecoration(hintText: '/bin/bash -l', isDense: true),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('Run')),
        ],
      ),
    );
    final args = cmd == null ? const <String>[] : splitCommandLine(cmd);
    if (args.isNotEmpty) _restart(command: args);
  }

  Future<void> _startDebug() async {
    final app = context.read<AppState>();
    final target = s.container ?? s.request.container ?? 'the container';
    var image = TerminalSettings.debugImages.first;
    final ok = await confirmAction(
      context,
      title: 'Start a debug container in ${s.pod}?',
      message: 'Adds an ephemeral container to the pod that shares the process namespace of "$target" '
          '(like kubectl debug -it --target). Use /proc/1/root to reach its filesystem.\n\n'
          'This changes the pod spec and cannot be undone: ephemeral containers stay in the pod '
          'until it is deleted.',
      kubeContext: app.currentContext,
      objectName: s.pod,
      destructive: true,
      confirmLabel: 'Start debug container',
      extra: _DebugImagePicker(initial: image, onChanged: (v) => image = v),
    );
    if (ok != true || !mounted) return;
    await s.startDebugContainer(image.trim().isEmpty ? TerminalSettings.debugImages.first : image.trim());
    if (mounted) _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final hw = HardwareKeyboard.instance;
    if (!hw.isMetaPressed) {
      // Everything without ⌘ belongs to the terminal: stop app shortcuts
      // but let the platform deliver text (IME) to the terminal.
      return KeyEventResult.skipRemainingHandlers;
    }
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd) {
      s.setFontSize(s.fontSize + 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
      s.setFontSize(s.fontSize - 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.digit0) {
      s.setFontSize(13);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyK) {
      _clear();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // ⌘J, ⌘I, ... go to the app
  }

  Future<void> _contextMenu(TapDownDetails d) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final p = overlay.globalToLocal(d.globalPosition);
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(p.dx, p.dy, overlay.size.width - p.dx, overlay.size.height - p.dy),
      items: [
        PopupMenuItem(value: 'copy', height: 28, enabled: s.hasSelection, child: const Text('Copy')),
        const PopupMenuItem(value: 'paste', height: 28, child: Text('Paste')),
        const PopupMenuDivider(height: 9),
        const PopupMenuItem(value: 'clear', height: 28, child: Text('Clear')),
      ],
    );
    switch (v) {
      case 'copy':
        await _copy();
      case 'paste':
        await _paste();
      case 'clear':
        _clear();
    }
  }

  // ---- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Toolbar(
          session: s,
          onShell: (sh) => _restart(shell: sh),
          onCustomCommand: _customCommand,
          onRestart: () => _restart(),
          onCopy: s.hasSelection ? _copy : null,
          onPaste: _paste,
          onClear: _clear,
        ),
        Expanded(
          child: Container(
            color: terminalTheme.background,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  decoration: BoxDecoration(
                    border: Border.all(
                      width: 1.5,
                      color: _focused ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.75) : Colors.transparent,
                    ),
                  ),
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _onKey,
                    child: TerminalView(
                      s.terminal,
                      key: const ValueKey('terminal-view'),
                      controller: s.controller,
                      focusNode: _focus,
                      autofocus: true,
                      theme: terminalTheme,
                      textStyle: TerminalStyle(fontSize: s.fontSize, height: 1.25, fontFamily: monoFamily, fontFamilyFallback: monoFallback),
                      textScaler: TextScaler.noScaling,
                      padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
                      keyboardType: TextInputType.text,
                      readOnly: !s.isLive,
                      onSecondaryTapDown: (d, _) => _contextMenu(d),
                    ),
                  ),
                ),
              ),
              // Below the output (not over it) so the last lines stay readable.
              if (!s.isLive)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                  child: _StateBanner(
                    session: s,
                    canDebug: !context.select<AppState, bool>((a) => a.readOnly),
                    onRestart: () => _restart(),
                    onAutoShell: () => _restart(shell: 'auto'),
                    onCustomCommand: _customCommand,
                    onDebug: _startDebug,
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ---- toolbar ------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  final TerminalTab session;
  final ValueChanged<String> onShell;
  final VoidCallback onCustomCommand;
  final VoidCallback onRestart;
  final VoidCallback? onCopy;
  final VoidCallback onPaste;
  final VoidCallback onClear;
  const _Toolbar({
    required this.session,
    required this.onShell,
    required this.onCustomCommand,
    required this.onRestart,
    required this.onCopy,
    required this.onPaste,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final s = session;
    final small = theme.textTheme.bodySmall?.copyWith(fontSize: 11, color: theme.hintColor);
    Widget icon(String key, String tip, IconData i, VoidCallback? onPressed) => SizedBox(
          width: 26,
          height: 26,
          child: IconButton(
            key: ValueKey(key),
            tooltip: tip,
            padding: EdgeInsets.zero,
            iconSize: 15,
            onPressed: onPressed,
            icon: Icon(i),
          ),
        );
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: colors.inspector, border: Border(bottom: BorderSide(color: colors.separator))),
      child: Row(children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: severityColor(context, terminalSeverity(s)), shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: s.pod, style: monoStyle(context, size: 11)),
              TextSpan(text: ' / ${s.container ?? 'default'}', style: monoStyle(context, size: 11, color: theme.hintColor)),
              if (s.debugTarget != null) TextSpan(text: '  (debugging ${s.debugTarget})', style: small),
              TextSpan(text: '  ·  ${terminalPhaseLabel(s)}', style: small),
            ]),
            key: const ValueKey('terminal-status'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          key: const ValueKey('terminal-shell-picker'),
          tooltip: 'Shell or command (restarts the session)',
          onSelected: (v) => v == '__custom' ? onCustomCommand() : onShell(v),
          itemBuilder: (_) => [
            for (final sh in terminalShells)
              CheckedPopupMenuItem(
                value: sh,
                height: 28,
                checked: s.request.command == null && s.request.shell == sh,
                child: Text(sh == 'auto' ? 'Auto (zsh → bash → ash → sh)' : sh),
              ),
            const PopupMenuDivider(height: 9),
            CheckedPopupMenuItem(value: '__custom', height: 28, checked: s.request.command != null, child: const Text('Custom command…')),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: colors.separator), borderRadius: BorderRadius.circular(4)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.terminal, size: 13, color: theme.hintColor),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(s.commandLabel, style: monoStyle(context, size: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              Icon(Icons.arrow_drop_down, size: 16, color: theme.hintColor),
            ]),
          ),
        ),
        const SizedBox(width: 4),
        icon('terminal-restart', 'Restart session', Icons.refresh, onRestart),
        icon('terminal-copy', 'Copy selection (⌘C)', Icons.copy, onCopy),
        icon('terminal-paste', 'Paste (⌘V)', Icons.content_paste, onPaste),
        icon('terminal-clear', 'Clear (⌘K)', Icons.clear_all, onClear),
        icon('terminal-font-smaller', 'Smaller text (⌘−)', Icons.text_decrease,
            s.fontSize > TerminalSettings.minFontSize ? () => s.setFontSize(s.fontSize - 1) : null),
        icon('terminal-font-larger', 'Larger text (⌘+)', Icons.text_increase,
            s.fontSize < TerminalSettings.maxFontSize ? () => s.setFontSize(s.fontSize + 1) : null),
        PopupMenuButton<int>(
          tooltip: 'Scrollback',
          icon: const Icon(Icons.more_horiz, size: 16),
          padding: EdgeInsets.zero,
          iconSize: 16,
          onSelected: (v) => TerminalSettings.scrollback = v,
          itemBuilder: (_) => [
            const PopupMenuItem(enabled: false, height: 24, child: Text('Scrollback for new sessions')),
            for (final n in TerminalSettings.scrollbackChoices)
              CheckedPopupMenuItem(value: n, height: 28, checked: TerminalSettings.scrollback == n, child: Text('$n lines')),
          ],
        ),
      ]),
    );
  }
}

// ---- exited / error banner ------------------------------------------------------------

class _StateBanner extends StatelessWidget {
  final TerminalTab session;
  final bool canDebug;
  final VoidCallback onRestart;
  final VoidCallback onAutoShell;
  final VoidCallback onCustomCommand;
  final VoidCallback onDebug;
  const _StateBanner({
    required this.session,
    required this.canDebug,
    required this.onRestart,
    required this.onAutoShell,
    required this.onCustomCommand,
    required this.onDebug,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = session;
    final (sev, title) = switch (s.phase) {
      TerminalPhase.exited => (s.exitCode == 0 ? Severity.ok : Severity.warn, 'Session ended · exit code ${s.exitCode}'),
      TerminalPhase.startingDebug => (Severity.info, 'Starting debug container…'),
      _ => switch (s.errorReason) {
          ExecReason.noShell => (Severity.warn, 'No shell in container ${s.container ?? ''}'),
          ExecReason.commandNotFound => (Severity.error, 'Command not found: ${s.commandLabel}'),
          ExecReason.containerNotRunning => (Severity.warn, 'Container is not running'),
          ExecReason.forbidden => (Severity.error, 'Not allowed'),
          ExecReason.connection => (Severity.error, 'Disconnected'),
          _ => (Severity.error, 'Could not start the session'),
        },
    };
    final color = severityColor(context, sev);
    final detail = switch (s.phase) {
      TerminalPhase.exited => null,
      TerminalPhase.startingDebug => 'Creating an ephemeral container and waiting for it to run (pulling the image can take a moment).',
      _ when s.noShell => 'The image has no /bin/sh (it may be distroless). Start a debug container that shares this '
          "container's processes, or run a binary the image does have.",
      _ => s.errorMessage,
    };
    final dense = ButtonStyle(visualDensity: VisualDensity.compact, padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 10)));
    return Material(
      key: const ValueKey('terminal-state-banner'),
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 3,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border(left: BorderSide(color: color, width: 3))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            if (s.phase == TerminalPhase.startingDebug)
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(s.phase == TerminalPhase.exited ? Icons.stop_circle_outlined : Icons.error_outline, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
          ]),
          if (detail != null) ...[
            const SizedBox(height: 4),
            SelectionArea(
              child: Text(detail, maxLines: 4, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ),
          ],
          if (s.phase != TerminalPhase.startingDebug) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              if (s.noShell && canDebug)
                FilledButton.icon(
                  key: const ValueKey('terminal-start-debug'),
                  style: dense,
                  onPressed: onDebug,
                  icon: const Icon(Icons.bug_report_outlined, size: 16),
                  label: const Text('Start debug container…'),
                ),
              if (s.noShell || s.errorReason == ExecReason.commandNotFound)
                OutlinedButton(style: dense, onPressed: onCustomCommand, child: const Text('Run a command…')),
              if (s.errorReason == ExecReason.commandNotFound)
                OutlinedButton(style: dense, onPressed: onAutoShell, child: const Text('Use a shell')),
              if (s.noShell)
                OutlinedButton(key: const ValueKey('terminal-restart-session'), style: dense, onPressed: onRestart, child: const Text('Retry'))
              else
                FilledButton(
                  key: const ValueKey('terminal-restart-session'),
                  style: dense,
                  onPressed: onRestart,
                  child: Text(s.phase == TerminalPhase.exited ? 'Restart session' : 'Retry'),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _DebugImagePicker extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onChanged;
  const _DebugImagePicker({required this.initial, required this.onChanged});

  @override
  State<_DebugImagePicker> createState() => _DebugImagePickerState();
}

class _DebugImagePickerState extends State<_DebugImagePicker> {
  late final _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(String v) {
    _ctl.text = v;
    widget.onChanged(v);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Image', style: theme.textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          for (final img in TerminalSettings.debugImages)
            ChoiceChip(
              label: Text(img, style: monoStyle(context, size: 11)),
              selected: _ctl.text == img,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => _set(img),
            ),
        ]),
        const SizedBox(height: 6),
        TextField(
          key: const ValueKey('debug-image-field'),
          controller: _ctl,
          style: monoStyle(context),
          decoration: const InputDecoration(isDense: true, hintText: 'any image with a shell'),
          onChanged: (v) {
            widget.onChanged(v);
            setState(() {});
          },
        ),
      ]),
    );
  }
}

// ---- helpers -------------------------------------------------------------------------------

Severity terminalSeverity(TerminalTab s) => switch (s.phase) {
      TerminalPhase.running => Severity.ok,
      TerminalPhase.connecting || TerminalPhase.startingDebug => Severity.info,
      TerminalPhase.exited => Severity.neutral,
      TerminalPhase.error => s.noShell ? Severity.warn : Severity.error,
    };

String terminalPhaseLabel(TerminalTab s) => switch (s.phase) {
      TerminalPhase.connecting => 'connecting…',
      TerminalPhase.running => 'connected · ${s.terminal.viewWidth}×${s.terminal.viewHeight}',
      TerminalPhase.exited => 'exited (${s.exitCode})',
      TerminalPhase.startingDebug => 'starting debug container…',
      TerminalPhase.error => s.noShell ? 'no shell' : 'error',
    };

/// Splits a command line into argv with simple shell quoting ('…', "…", \).
List<String> splitCommandLine(String line) {
  final out = <String>[];
  final cur = StringBuffer();
  var inWord = false;
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else if (ch == r'\' && quote == '"' && i + 1 < line.length) {
        cur.write(line[++i]);
      } else {
        cur.write(ch);
      }
    } else if (ch == "'" || ch == '"') {
      quote = ch;
      inWord = true;
    } else if (ch == r'\' && i + 1 < line.length) {
      cur.write(line[++i]);
      inWord = true;
    } else if (ch == ' ' || ch == '\t' || ch == '\n') {
      if (inWord) {
        out.add(cur.toString());
        cur.clear();
        inWord = false;
      }
    } else {
      cur.write(ch);
      inWord = true;
    }
  }
  if (inWord) out.add(cur.toString());
  return out;
}

/// Inverse of [splitCommandLine] for pre-filling the command field.
String shellJoinArgs(List<String> args) => args.map((a) => RegExp(r'''^[A-Za-z0-9_./:=@%+-]+$''').hasMatch(a) ? a : "'${a.replaceAll("'", r"'\''")}'").join(' ');
