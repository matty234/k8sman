import Cocoa
import FlutterMacOS
import Sparkle

/// In-app updates via Sparkle 2 (see docs/UPDATES.md).
///
/// - Sparkle does the checking, EdDSA verification, download, install and
///   relaunch. It replaces the whole bundle, so the embedded k8sman-server is
///   swapped together with the app.
/// - Background checks are scheduled by Dart (`lib/app/updates`) through the
///   `k8sman/updates` channel; Sparkle's own scheduler is off
///   (`SUEnableAutomaticChecks` = NO in Info.plist).
/// - A background check that finds an update doesn't pop up Sparkle's window
///   ("gentle reminders"): Dart shows a banner, and its Install button brings
///   Sparkle's update window into focus.
/// - Updates are disabled in Debug builds, for version 0.0.0, and when no
///   EdDSA public key or feed is configured.
///
/// Testing overrides (release builds too; the EdDSA key still has to match):
/// `K8SMAN_UPDATE_FEED_URL=http://127.0.0.1:8000/appcast.xml` in the
/// environment, or `defaults write dev.k8sman.app UpdateFeedURL <url>`.
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
  static let shared = UpdateController()

  private static let autoCheckKey = "UpdatesAutomaticChecks"
  private static let lastCheckKey = "UpdatesLastCheck"

  private var controller: SPUStandardUpdaterController?
  private var channel: FlutterMethodChannel?
  /// Why updates are off ("" when they are on).
  private(set) var disabledReason = ""
  /// The update found by the last background check, waiting for the user.
  private var pending: SUAppcastItem?

  private let info = Bundle.main.infoDictionary ?? [:]
  var version: String { info["CFBundleShortVersionString"] as? String ?? "0.0.0" }
  var build: String { info["CFBundleVersion"] as? String ?? "" }

  /// Create and start the updater (unless updates are disabled). Call once
  /// from applicationWillFinishLaunching.
  func setUp() {
    guard controller == nil else { return }
    disabledReason = Self.disabledReason(
      debug: Self.isDebugBuild,
      version: version,
      publicKey: info["SUPublicEDKey"] as? String,
      feed: Self.feedOverride() ?? (info["SUFeedURL"] as? String))
    guard disabledReason.isEmpty else {
      NSLog("k8sman: updates disabled: \(disabledReason)")
      return
    }
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
  }

  static var isDebugBuild: Bool {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }

  static func disabledReason(debug: Bool, version: String, publicKey: String?, feed: String?) -> String {
    if debug { return "development build" }
    if version.isEmpty || version == "0.0.0" || version.contains("dev") { return "development version (\(version))" }
    if (publicKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return "no update signing key configured" }
    if (feed ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return "no update feed configured" }
    return ""
  }

  // MARK: - Menu

  /// Add "Check for Updates…" under "About k8sman", and route About to the
  /// Flutter About panel (version + update settings).
  func installMenuItems() {
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
    if let about = appMenu.items.first(where: { $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) }) {
      about.target = self
      about.action = #selector(showAbout(_:))
    }
    let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
    item.target = self
    let index = appMenu.items.firstIndex(where: { $0.isSeparatorItem }) ?? 1
    appMenu.insertItem(item, at: index)
  }

  @objc func checkForUpdates(_ sender: Any?) {
    guard let controller = controller else { return }
    recordCheck()
    controller.checkForUpdates(sender)
  }

  @objc func showAbout(_ sender: Any?) {
    NSApp.activate(ignoringOtherApps: true)
    if let channel = channel {
      channel.invokeMethod("showAbout", arguments: nil)
    } else {
      NSApp.orderFrontStandardAboutPanel(sender)
    }
  }

  @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(checkForUpdates(_:)) {
      return controller?.updater.canCheckForUpdates ?? false
    }
    return true
  }

  // MARK: - Flutter channel

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "k8sman/updates", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "info":
        result(self.snapshot())
      case "setAutomaticChecks":
        UserDefaults.standard.set(call.arguments as? Bool ?? true, forKey: Self.autoCheckKey)
        result(self.snapshot())
      case "checkInBackground":
        // Scheduled check: a found update comes back as "updateAvailable".
        if let updater = self.controller?.updater, updater.canCheckForUpdates {
          self.recordCheck()
          updater.checkForUpdatesInBackground()
          result(true)
        } else {
          result(false)
        }
      case "checkNow", "install":
        // User-initiated: Sparkle's window shows the (pending) update with
        // its release notes and Install / Install and Relaunch buttons.
        self.checkForUpdates(nil)
        result(self.controller != nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  private func recordCheck() {
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
  }

  private func snapshot() -> [String: Any] {
    let defaults = UserDefaults.standard
    var s: [String: Any] = [
      "version": version,
      "build": build,
      "enabled": controller != nil,
      "automaticChecks": defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true,
    ]
    if !disabledReason.isEmpty { s["disabledReason"] = disabledReason }
    let last = defaults.double(forKey: Self.lastCheckKey)
    if last > 0 { s["lastCheck"] = Int(last * 1000) }
    if let feed = controller?.updater.feedURL?.absoluteString { s["feedURL"] = feed }
    if let item = pending { s["available"] = Self.describe(item) }
    return s
  }

  static func describe(_ item: SUAppcastItem) -> [String: Any] {
    var m: [String: Any] = [
      "version": item.displayVersionString,
      "build": item.versionString,
    ]
    let notes = item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL
    if let notes = notes { m["releaseNotesURL"] = notes.absoluteString }
    if let date = item.date { m["date"] = Int(date.timeIntervalSince1970 * 1000) }
    if item.contentLength > 0 { m["size"] = Int(item.contentLength) }
    m["critical"] = item.isCriticalUpdate
    return m
  }

  // MARK: - SPUUpdaterDelegate

  func feedURLString(for updater: SPUUpdater) -> String? {
    return Self.feedOverride()
  }

  /// Testing override of the feed, or nil for Info.plist's SUFeedURL.
  static func feedOverride() -> String? {
    if let env = ProcessInfo.processInfo.environment["K8SMAN_UPDATE_FEED_URL"], !env.isEmpty { return env }
    if let url = UserDefaults.standard.string(forKey: "UpdateFeedURL"), !url.isEmpty { return url }
    return nil
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    pending = nil
    channel?.invokeMethod("upToDate", arguments: snapshot())
  }

  /// About to quit for "Install and Relaunch": remember which port-forwards
  /// were running so the relaunched app restarts them (AutoStart ones come
  /// back anyway). The backend itself is stopped (SIGTERM) by
  /// applicationWillTerminate before Sparkle swaps the bundle.
  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    BackendSupervisor.shared.rememberRunningForwards()
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    channel?.invokeMethod("error", arguments: error.localizedDescription)
  }

  // MARK: - SPUStandardUserDriverDelegate (gentle reminders)

  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
    // Let the in-app banner announce scheduled updates when Flutter is up.
    return channel == nil
  }

  func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
    pending = update
    if !handleShowingUpdate {
      channel?.invokeMethod("updateAvailable", arguments: Self.describe(update))
    }
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    channel?.invokeMethod("attended", arguments: nil)
  }

  func standardUserDriverWillFinishUpdateSession() {
    // Skipped, dismissed or installed: the banner goes away. "Remind me
    // later" brings it back on the next scheduled check.
    pending = nil
    channel?.invokeMethod("sessionFinished", arguments: nil)
  }
}
