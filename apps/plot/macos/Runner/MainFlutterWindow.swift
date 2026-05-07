import Cocoa
import FlutterMacOS

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
}
