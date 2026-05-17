import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var menuBarController: MenuBarController?
  private var widgetBridgePlugin: WidgetBridgePlugin?
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let menuBarController = MenuBarController()
    self.menuBarController = menuBarController
    self.widgetBridgePlugin = WidgetBridgePlugin(
      messenger: flutterViewController.engine.binaryMessenger,
      statusItemController: menuBarController
    )

    // window_manager's `show()` unconditionally calls
    // `NSApp.activate(ignoringOtherApps: true)` even when Dart passes
    // `inactive: true` — the flag is dropped. That steals focus from the
    // editor when Plot is launched via `flutter run`. Use `orderFront(nil)`
    // ourselves: it makes the window visible without making it key, so the
    // process never becomes the foreground app.
    let channel = FlutterMethodChannel(
      name: "day.plot.app/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "showInactive":
        self?.orderFront(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel

    super.awakeFromNib()
  }

  // Keep the window invisible the first time AppKit orders it on-screen so
  // Dart can restore the saved size/position before the user sees it.
  // `Window.init()` calls `windowManager.show()` once restoration finishes.
  // Subsequent calls are no-ops (window_manager guards with a `configured`
  // associated flag), so user-initiated show/focus still work.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
