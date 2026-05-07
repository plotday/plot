import Flutter
import UIKit
import WidgetKit

/// iOS counterpart to the macOS WidgetBridgePlugin. Persists Flutter
/// state to the shared App Group and triggers WidgetKit reloads.
final class WidgetBridgePlugin: NSObject {
  static let channelName = "day.plot/widgets"

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  /// Send an action back into Flutter. Plumbed through for future
  /// widget tap handlers to call.
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
      PlotWidgetSharedStorage.sharedDefaults()?.set(json, forKey: PlotWidgetSharedStorage.widgetStateKey)
      result(nil)
    case "reloadAll":
      if #available(iOS 14.0, *) {
        WidgetCenter.shared.reloadAllTimelines()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
