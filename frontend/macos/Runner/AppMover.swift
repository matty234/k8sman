import Cocoa

/// Offers once to move k8sman into Applications when it's running from a
/// place it can't (or shouldn't) live: a translocated copy (macOS runs a
/// quarantined app that was opened straight from Downloads or an unzipped
/// folder from a hidden read-only mirror, where Sparkle can't install
/// updates), a mounted disk image, or the Downloads folder.
///
/// "Move to Applications" copies the bundle there (replacing an older copy,
/// which goes to the Trash), clears the quarantine flag the copy inherited,
/// moves the original to the Trash (unless it's on a disk image, which is
/// ejected instead) and relaunches from Applications.
enum AppMover {
  static let suppressKey = "MoveToApplicationsSuppressed"

  /// Testing only: a directory to install into instead of /Applications
  /// (`defaults write dev.k8sman.app MoveToApplicationsDestination <dir>`).
  static let destinationOverrideKey = "MoveToApplicationsDestination"

  enum Location: Equatable {
    case translocated, diskImage, downloads
  }

  /// Why [path] (a running app bundle) should be moved, or nil if it's fine
  /// where it is. [home] is the user's home directory.
  static func location(of path: String, home: String) -> Location? {
    let p = (path as NSString).standardizingPath
    if p.hasPrefix("/Applications/") || p.hasPrefix(home + "/Applications/") { return nil }
    if p.contains("/AppTranslocation/") { return .translocated }
    if p.hasPrefix("/Volumes/") { return .diskImage }
    if p.hasPrefix(home + "/Downloads/") { return .downloads }
    return nil
  }

  static func offerIfNeeded() {
    #if !DEBUG
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: suppressKey) else { return }
    let running = Bundle.main.bundleURL
    guard let where_ = location(of: running.path, home: NSHomeDirectory()) else { return }
    // Let the window come up first, so the alert has something to sit over.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { prompt(running: running, location: where_) }
    #endif
  }

  private static func prompt(running: URL, location: Location) {
    let alert = NSAlert()
    alert.messageText = "Move k8sman to your Applications folder?"
    let from: String
    switch location {
    case .diskImage: from = "the disk image"
    case .downloads, .translocated: from = "your Downloads folder"
    }
    alert.informativeText = "k8sman is running from \(from). In Applications it can update itself, and it stays put when you tidy up your downloads."
    alert.addButton(withTitle: "Move to Applications")
    alert.addButton(withTitle: "Not Now")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Don't ask again"
    let answer = alert.runModal()
    if alert.suppressionButton?.state == .on {
      UserDefaults.standard.set(true, forKey: suppressKey)
    }
    guard answer == .alertFirstButtonReturn else { return }
    do {
      try move(running: running, location: location)
    } catch {
      let a = NSAlert(error: error)
      a.messageText = "Couldn't move k8sman to Applications"
      a.informativeText = "\(error.localizedDescription)\n\nYou can drag k8sman into Applications in the Finder instead."
      a.runModal()
    }
  }

  private static func destinationDirectory() -> URL {
    if let dir = UserDefaults.standard.string(forKey: destinationOverrideKey), !dir.isEmpty {
      return URL(fileURLWithPath: dir, isDirectory: true)
    }
    let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
    if FileManager.default.isWritableFile(atPath: system.path) { return system }
    // Not an admin: the user's own Applications folder.
    let mine = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    try? FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
    return mine
  }

  private static func move(running: URL, location: Location) throws {
    let fm = FileManager.default
    let dest = destinationDirectory().appendingPathComponent(running.lastPathComponent)
    // Where the user actually put it (the translocated path is a mirror).
    let original = location == .translocated ? (originalURL(ofTranslocated: running) ?? running) : running

    if fm.fileExists(atPath: dest.path) {
      try fm.trashItem(at: dest, resultingItemURL: nil)
    }
    try fm.copyItem(at: running, to: dest)
    // The copy inherited the download's quarantine flag; the user already
    // approved this (notarized) app, so don't make Gatekeeper ask again.
    let xattr = Process()
    xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    xattr.arguments = ["-d", "-r", "com.apple.quarantine", dest.path]
    try? xattr.run()
    xattr.waitUntilExit()

    var eject: String?
    if location == .diskImage {
      // /Volumes/<name>/k8sman.app → eject /Volumes/<name> after quitting.
      let parts = original.standardizedFileURL.pathComponents
      if parts.count >= 3 { eject = "/" + parts[1...2].joined(separator: "/") }
    } else if original != dest {
      try? fm.trashItem(at: original, resultingItemURL: nil)
    }

    // Relaunch from the new place once this process has exited.
    let pid = ProcessInfo.processInfo.processIdentifier
    var script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
    if let eject { script += "/usr/bin/hdiutil detach \(shellQuote(eject)) -quiet; " }
    script += "/usr/bin/open \(shellQuote(dest.path))"
    let relaunch = Process()
    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
    relaunch.arguments = ["-c", script]
    try relaunch.run()
    NSApp.terminate(nil)
  }

  private static func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// The real location of a translocated bundle, via Security's
  /// SecTranslocateCreateOriginalPathForURL (public since 10.12, but not in
  /// the Swift overlay, so it's looked up at runtime).
  private static func originalURL(ofTranslocated url: URL) -> URL? {
    typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
          let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
    let fn = unsafeBitCast(sym, to: Fn.self)
    return fn(url as CFURL, nil)?.takeRetainedValue() as URL?
  }
}
