import 'package:flutter/foundation.dart';

/// One tab in the bottom dock: a log stream ([LogStream]) or a terminal
/// session ([TerminalTab]). The dock owns its tabs and disposes them when
/// they close, so a tab keeps working while hidden or the dock is collapsed.
abstract class DockTab extends ChangeNotifier {
  /// Stable identity within the dock.
  String get id;

  /// Short label, e.g. `pod/container`.
  String get label;

  /// Namespace and pod the tab belongs to.
  String get namespace;
  String get pod;

  /// True if closing the tab would end something the user may still want
  /// (e.g. a running shell). The dock view asks before closing it.
  bool get confirmClose => false;
}
