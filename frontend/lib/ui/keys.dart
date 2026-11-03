import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
