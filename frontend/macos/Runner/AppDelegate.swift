import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    // Resolving the login-shell environment can take a moment; do it while
    // Flutter boots so the backend starts quickly when Dart asks for it.
    BackendSupervisor.shared.prewarm()
    // Sparkle updates, created before Dart can ask for their state.
    UpdateController.shared.setUp()
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // No super call: FlutterAppDelegate doesn't implement this optional
    // method, so `super` raises "unrecognized selector", which AppKit
    // swallows, silently skipping everything after it.
    // "Check for Updates…" menu item, and About → the Flutter About panel.
    UpdateController.shared.installMenuItems()
    // View ▸ Command Palette…
    (mainFlutterWindow as? MainFlutterWindow)?.installMenuItems()
    // Running from Downloads, a disk image or a translocated copy: offer to
    // move into Applications (release builds only).
    AppMover.offerIfNeeded()
  }

  /// k8sman:// links, both while running and the one that launched the
  /// app (AppKit delivers that here too, after willFinishLaunching).
  /// Dart may not be listening yet: LinkRouter queues until it asks.
  override func application(_ application: NSApplication, open urls: [URL]) {
    super.application(application, open: urls)
    LinkRouter.shared.receive(urls)
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    // SIGTERM lets the backend stop its port-forwards cleanly. This also runs
    // before a Sparkle update replaces the bundle (it quits the app first).
    BackendSupervisor.shared.stop()
    // No super call (see applicationDidFinishLaunching).
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Hands k8sman:// URLs to Dart over the `k8sman/window` channel. URLs that
/// arrive before Dart has asked for them (`linksReady`) wait in a queue.
/// Dart parses and validates them; nothing here interprets a URL.
final class LinkRouter {
  static let shared = LinkRouter()
  var channel: FlutterMethodChannel?
  private var pending: [String] = []
  private var ready = false

  func receive(_ urls: [URL]) {
    for url in urls where url.scheme?.lowercased() == "k8sman" {
      let s = url.absoluteString
      if ready, let channel = channel {
        channel.invokeMethod("openLink", arguments: s)
      } else {
        pending.append(s)
      }
    }
  }

  /// Dart is listening: returns the queued URLs and sends later ones directly.
  func drain() -> [String] {
    ready = true
    let out = pending
    pending = []
    return out
  }
}
