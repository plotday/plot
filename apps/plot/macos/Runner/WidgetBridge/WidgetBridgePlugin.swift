import Cocoa
import FlutterMacOS

/// Bridges the Flutter `MethodChannel('day.plot/widgets')` to the
/// menu-bar surface. State flows in-process: Flutter calls
/// `writeState`, the plugin stashes the JSON, and `MenuBarController`
/// reads from it directly. We deliberately do NOT write through the
/// shared App Group container — accessing it would trigger the macOS
/// App Management TCC prompt ("Plot would like to access data from
/// other apps") at launch, and the menu bar runs inside the host app
/// process so it doesn't need shared storage anyway.
///
/// When a future macOS WidgetKit surface needs real data, that path
/// can opt in to the App Group write under its own user-facing
/// "Enable widget" affordance — keeping this prompt scoped to the
/// surface that actually requires it.
final class WidgetBridgePlugin: NSObject {
  static let channelName = "day.plot/widgets"

  private let channel: FlutterMethodChannel
  private weak var statusItemController: MenuBarController?

  init(messenger: FlutterBinaryMessenger, statusItemController: MenuBarController?) {
    self.channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    self.statusItemController = statusItemController
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    statusItemController?.actionDispatcher = { [weak self] name, args in
      self?.sendAction(name, args: args)
    }
  }

  func sendAction(_ name: String, args: [String: Any] = [:]) {
    channel.invokeMethod("onWidgetAction", arguments: ["name": name, "args": args])
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "writeState":
      guard
        let arguments = call.arguments as? [String: Any],
        let json = arguments["json"] as? String
      else {
        result(FlutterError(code: "bad-args", message: "writeState requires {json}", details: nil))
        return
      }
      statusItemController?.applyState(json)
      result(nil)
    case "reloadAll":
      statusItemController?.refresh()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
