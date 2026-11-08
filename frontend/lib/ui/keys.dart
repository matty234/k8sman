import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart' show CodeEditor;
import 'package:xterm/xterm.dart' show TerminalView;

import 'logs/log_stream_view.dart';

/// App shortcuts use Ctrl on Windows and Linux and ⌘ elsewhere (macOS, and
/// tests, which run as Android).
bool get useCtrlShortcuts =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux);

/// ⌘[key] on macOS, Ctrl+[key] on Windows/Linux.
SingleActivator primaryShortcut(LogicalKeyboardKey key) =>
    SingleActivator(key, meta: !useCtrlShortcuts, control: useCtrlShortcuts);

/// "⌘J" or "Ctrl+J", for tooltips and hints.
String shortcutLabel(String key) => useCtrlShortcuts ? 'Ctrl+$key' : '⌘$key';

/// Whether the platform's shortcut modifier (⌘ or Ctrl) is held.
bool get primaryModifierPressed =>
    useCtrlShortcuts ? HardwareKeyboard.instance.isControlPressed : HardwareKeyboard.instance.isMetaPressed;

/// Whether keyboard focus is in something that wants plain characters: a text
/// field (a focused field is an [EditableText]; Flutter delivers the key event
/// to it as well as to ancestor shortcuts, so unmodified-key shortcuts such
/// as `:` must check this), the code editor, a terminal, or the log viewer.
bool get textEntryFocused {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorWidgetOfExactType<EditableText>() != null ||
      context.findAncestorWidgetOfExactType<CodeEditor>() != null ||
      context.findAncestorWidgetOfExactType<TerminalView>() != null ||
      context.findAncestorWidgetOfExactType<LogStreamView>() != null;
}
