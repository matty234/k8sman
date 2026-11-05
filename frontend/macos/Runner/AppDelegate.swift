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
