import Cocoa
import FlutterMacOS
import WidgetKit

/// Bridges the Flutter `MethodChannel('day.plot/widgets')` to native
/// widget hosts. Today it persists JSON state to the shared App Group
/// and triggers `WidgetCenter.reloadAllTimelines()`. The status-item
/// controller registers a callback so it can refresh when state
/// changes.
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
  }

  /// Invoked from native code (e.g. status-item action handlers in the
  /// future) to send an action back into Flutter. Today nothing calls
  /// this; it's plumbed through so the eventual quick-create-note
  /// integration just needs to call this method.
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
      // Skip the App Group write when no widget surface is enabled —
      // otherwise the first call (which Flutter fires immediately on
      // launch) trips the macOS App Management TCC prompt for state
      // nothing currently reads.
      guard PlotWidgetSharedStorage.widgetSurfaceEnabled() else {
        result(nil)
        return
      }
      PlotWidgetSharedStorage.sharedDefaults()?.set(json, forKey: PlotWidgetSharedStorage.widgetStateKey)
      result(nil)
    case "reloadAll":
      guard PlotWidgetSharedStorage.widgetSurfaceEnabled() else {
        result(nil)
        return
      }
      if #available(macOS 11.0, *) {
        WidgetCenter.shared.reloadAllTimelines()
      }
      statusItemController?.refresh()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
