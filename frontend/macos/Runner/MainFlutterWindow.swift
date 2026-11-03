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
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = VibrantRootViewController(flutterViewController: flutterViewController)
    self.setFrame(windowFrame, display: true)

    // Unified, transparent titlebar: traffic lights float over the nav and
    // the app's own toolbar rows (52pt, see `titlebarHeight` in theme.dart)
    // sit in the titlebar area.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    let toolbar = NSToolbar(identifier: "k8sman.main")
    toolbar.displayMode = .iconOnly
    self.toolbar = toolbar
    self.toolbarStyle = .unified
    self.minSize = NSSize(width: 900, height: 560)

    // Flutter-side drag regions (WindowDragArea) call into here.
    let channel = FlutterMethodChannel(name: "k8sman/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "startDrag":
        if let event = self.currentEvent { self.performDrag(with: event) }
        result(nil)
      case "zoom":
        self.zoom(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
