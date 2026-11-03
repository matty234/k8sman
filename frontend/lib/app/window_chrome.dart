import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ui/theme.dart';

/// Native window state pushed from `MainFlutterWindow.swift` over the
/// `k8sman/window` channel.
class WindowChrome {
  WindowChrome._();

  static const _channel = MethodChannel('k8sman/window');

  /// True while the window is in macOS fullscreen. The titlebar (with the
  /// traffic lights) is then hidden until the pointer reaches the top edge,
  /// so the app drops its 52pt titlebar band.
  static final isFullScreen = ValueNotifier<bool>(false);

  /// Listen for fullscreen changes. Call once at startup (macOS only).
  static void init() {
    if (!nativeMacChrome) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fullScreenChanged') isFullScreen.value = call.arguments == true;
      return null;
    });
    _channel.invokeMethod<bool>('isFullScreen').then((v) => isFullScreen.value = v == true, onError: (Object _) {});
  }
}

/// Rebuilds dependents when [WindowChrome.isFullScreen] changes. Installed
/// by `K8sManApp` around the whole app.
class WindowChromeScope extends InheritedNotifier<ValueNotifier<bool>> {
  WindowChromeScope({super.key, required super.child}) : super(notifier: WindowChrome.isFullScreen);

  static bool isFullScreen(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WindowChromeScope>();
    return scope?.notifier?.value ?? WindowChrome.isFullScreen.value;
  }
}

/// Space reserved at the top of the window for the native titlebar (traffic
/// lights): [titlebarHeight] when windowed, 0 in fullscreen.
double topChromeInset(BuildContext context) => WindowChromeScope.isFullScreen(context) ? 0 : titlebarHeight;

/// Height of the top toolbar rows (nav header, table toolbar): the 52pt
/// unified titlebar band when windowed, a compact 40pt row in fullscreen.
double toolbarRowHeight(BuildContext context) => WindowChromeScope.isFullScreen(context) ? 40 : titlebarHeight;
