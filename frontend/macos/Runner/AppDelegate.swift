import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    // Resolving the login-shell environment can take a moment; do it while
    // Flutter boots so the backend starts quickly when Dart asks for it.
    BackendSupervisor.shared.prewarm()
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    // SIGTERM lets the backend stop its port-forwards cleanly.
    BackendSupervisor.shared.stop()
    super.applicationWillTerminate(notification)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
