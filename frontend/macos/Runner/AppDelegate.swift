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
    super.applicationDidFinishLaunching(notification)
    // "Check for Updates…" menu item, and About → the Flutter About panel.
    UpdateController.shared.installMenuItems()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    // SIGTERM lets the backend stop its port-forwards cleanly. This also runs
    // before a Sparkle update replaces the bundle (it quits the app first).
    BackendSupervisor.shared.stop()
    super.applicationWillTerminate(notification)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
