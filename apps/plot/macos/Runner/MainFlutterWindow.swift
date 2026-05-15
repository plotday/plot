import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var menuBarController: MenuBarController?
  private var widgetBridgePlugin: WidgetBridgePlugin?

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
