import Cocoa
import FlutterMacOS

/// Hosts the Flutter view on top of a sidebar-material NSVisualEffectView so
/// regions Flutter leaves transparent (the resource nav) get native vibrancy.
class VibrantRootViewController: NSViewController {
  let flutterViewController: FlutterViewController

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func loadView() {
    let effect = NSVisualEffectView()
    effect.material = .sidebar
    effect.blendingMode = .behindWindow
    effect.state = .followsWindowActiveState
    view = effect

    flutterViewController.backgroundColor = .clear
    addChild(flutterViewController)
    flutterViewController.view.frame = effect.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]
    effect.addSubview(flutterViewController.view)
  }
}

class MainFlutterWindow: NSWindow {
  /// Height of the app's own titlebar band (`titlebarHeight` in theme.dart).
  static let titlebarBand: CGFloat = 52
  static let frameAutosaveName = "k8sman.main"
  static let defaultSize = NSSize(width: 1440, height: 900)
  static let minimumSize = NSSize(width: 1000, height: 640)

  private var windowChannel: FlutterMethodChannel?
  private var backendChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = VibrantRootViewController(flutterViewController: flutterViewController)
    self.setFrame(windowFrame, display: true)

    // Transparent, full-size-content titlebar with no NSToolbar: Flutter
    // draws the 52pt band itself and receives every click in it. AppKit's
    // titlebar container is shrunk to just the traffic lights (see
    // layoutTrafficLights), so it can't swallow clicks elsewhere in the band.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.titlebarSeparatorStyle = .none
    self.styleMask.insert(.fullSizeContentView)
    self.toolbar = nil
    self.isMovableByWindowBackground = false

    // Size: about 1440×900 centred on first launch, then whatever the user
    // left it at (frame autosave).
    self.minSize = Self.minimumSize
    if !self.setFrameUsingName(Self.frameAutosaveName) {
      self.setFrame(Self.initialFrame(for: self.screen ?? NSScreen.main), display: true)
    }
    self.setFrameAutosaveName(Self.frameAutosaveName)

    let messenger = flutterViewController.engine.binaryMessenger

    // Window chrome: Flutter drag regions (WindowDragArea) and fullscreen state.
    let window = FlutterMethodChannel(name: "k8sman/window", binaryMessenger: messenger)
    window.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "startDrag":
        if let event = self.currentEvent { self.performDrag(with: event) }
        result(nil)
      case "zoom":
        self.zoom(nil)
        result(nil)
      case "isFullScreen":
        result(self.styleMask.contains(.fullScreen))
      case "linksReady":
        // Links queued before Dart listened (e.g. the one that launched us).
        result(LinkRouter.shared.drain())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = window
    LinkRouter.shared.channel = window

    // Embedded backend: status pushes and start/restart requests.
    let backend = FlutterMethodChannel(name: "k8sman/backend", binaryMessenger: messenger)
    backend.setMethodCallHandler { call, result in
      switch call.method {
      case "start":
        BackendSupervisor.shared.start()
        result(BackendSupervisor.shared.status())
      case "restart":
        BackendSupervisor.shared.restart()
        result(nil)
      case "status":
        result(BackendSupervisor.shared.status())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    BackendSupervisor.shared.onChange = { [weak backend] status in
      backend?.invokeMethod("status", arguments: status)
    }
    backendChannel = backend

    // Files: kubeconfig open panel and Reveal in Finder.
    let files = FlutterMethodChannel(name: "k8sman/files", binaryMessenger: messenger)
    files.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "chooseKubeconfig":
        let args = call.arguments as? [String: Any]
        self?.chooseFile(startingAt: args?["directory"] as? String, result: result)
      case "chooseYaml":
        self?.chooseYaml(result: result)
      case "saveYaml":
        let args = call.arguments as? [String: Any]
        self?.saveYaml(
          suggestedName: args?["name"] as? String ?? "views.yaml",
          extensions: args?["extensions"] as? [String] ?? ["yaml", "yml"],
          prompt: args?["prompt"] as? String ?? "Export",
          result: result)
      case "reveal":
        if let path = call.arguments as? String {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Updates (Sparkle): scheduling, banner and About panel live in Dart.
    UpdateController.shared.attach(messenger: messenger)

    let nc = NotificationCenter.default
    nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.windowChannel?.invokeMethod("fullScreenChanged", arguments: true)
    }
    nc.addObserver(forName: NSWindow.willExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.windowChannel?.invokeMethod("fullScreenChanged", arguments: false)
    }
    for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                 NSWindow.didBecomeKeyNotification, NSWindow.didEndLiveResizeNotification] {
      nc.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
        self?.layoutTrafficLights()
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    layoutTrafficLights()
    DispatchQueue.main.async { [weak self] in self?.layoutTrafficLights() }
  }

  override func layoutIfNeeded() {
    super.layoutIfNeeded()
    layoutTrafficLights()
  }

  static func initialFrame(for screen: NSScreen?) -> NSRect {
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let w = min(defaultSize.width, visible.width * 0.94)
    let h = min(defaultSize.height, visible.height * 0.94)
    return NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h).integral
  }

  /// Centre the traffic lights vertically in the 52pt band over the nav, and
  /// shrink AppKit's titlebar container to just around them. Everything else
  /// in the band then hit-tests straight to the Flutter view.
  private func layoutTrafficLights() {
    guard !styleMask.contains(.fullScreen),
          let close = standardWindowButton(.closeButton),
          let mini = standardWindowButton(.miniaturizeButton),
          let zoom = standardWindowButton(.zoomButton),
          let container = close.superview?.superview else { return }
    let band = Self.titlebarBand
    let buttons = [close, mini, zoom]
    let spacing: CGFloat = 20
    let left: CGFloat = 20
    let width = left + spacing * 2 + zoom.frame.width + 12
    let target = NSRect(x: 0, y: frame.height - band, width: width, height: band)
    if container.frame != target { container.frame = target }
    for (i, b) in buttons.enumerated() {
      let origin = NSPoint(x: left + CGFloat(i) * spacing, y: ((band - b.frame.height) / 2).rounded())
      if b.frame.origin != origin { b.setFrameOrigin(origin) }
    }
  }

  /// View ▸ Command Palette… (Flutter opens the palette). Its key
  /// equivalent is ⌘P, not ⌘K: should AppKit ever match a menu key
  /// equivalent before Flutter sees the key, ⌘K still reaches a focused
  /// terminal ("clear"). Flutter binds both keys itself.
  ///
  /// Also turns the app menu's "Preferences…" (⌘,) into "Settings…", which
  /// opens Flutter's Settings page (Flutter binds ⌘, itself too).
  func installMenuItems() {
    if let appMenu = NSApp.mainMenu?.items.first?.submenu,
       let prefs = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
      prefs.title = "Settings…"
      prefs.target = self
      prefs.action = #selector(showSettings(_:))
    }
    guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else { return }
    let item = NSMenuItem(title: "Command Palette…", action: #selector(showCommandPalette(_:)), keyEquivalent: "p")
    item.target = self
    view.insertItem(item, at: 0)
    view.insertItem(NSMenuItem.separator(), at: 1)
  }

  @objc func showCommandPalette(_ sender: Any?) {
    windowChannel?.invokeMethod("commandPalette", arguments: nil)
  }

  @objc func showSettings(_ sender: Any?) {
    windowChannel?.invokeMethod("settings", arguments: nil)
  }

  /// Open panel for a .yaml / .yml file (importing saved views).
  private func chooseYaml(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "Choose a YAML file"
    panel.prompt = "Import"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedFileTypes = ["yaml", "yml"]
    panel.beginSheetModal(for: self) { response in
      result(response == .OK ? panel.url?.path : nil)
    }
  }

  /// Save panel for a text file (exporting saved views as .yaml, log
  /// downloads); returns the chosen path, which Dart writes.
  private func saveYaml(suggestedName: String, extensions: [String], prompt: String, result: @escaping FlutterResult) {
    let panel = NSSavePanel()
    panel.title = prompt
    panel.prompt = prompt
    panel.nameFieldStringValue = suggestedName
    panel.allowedFileTypes = extensions
    panel.canCreateDirectories = true
    panel.beginSheetModal(for: self) { response in
      result(response == .OK ? panel.url?.path : nil)
    }
  }

  private func chooseFile(startingAt directory: String?, result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "Choose a kubeconfig file"
    panel.prompt = "Use Kubeconfig"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.treatsFilePackagesAsDirectories = true
    let home = FileManager.default.homeDirectoryForCurrentUser
    panel.directoryURL = directory.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".kube")
    panel.beginSheetModal(for: self) { response in
      result(response == .OK ? panel.url?.path : nil)
    }
  }
}
