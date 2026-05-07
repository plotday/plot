import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Retain the channel and its handler for the app's lifetime. Without this,
  // the local `channel` in `didInitializeImplicitFlutterEngine` is deallocated
  // as soon as that method returns and the handler block is dropped, producing
  // MissingPluginException on the Dart side.
  private var shareChannel: FlutterMethodChannel?
  private var widgetBridgePlugin: WidgetBridgePlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Method channel for reading shared content written by the ShareExtension.
    // iOS lowercases URL schemes via Launch Services, which breaks
    // share_handler_ios's case-sensitive `hasPrefix("ShareMedia-...")` check,
    // so app_links intercepts the URL instead. We read the payload ourselves
    // from the App Group UserDefaults.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PlotSharePlugin") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "day.plot.app/share_ios",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "readSharedContent":
        let args = call.arguments as? [String: Any]
        let key = (args?["key"] as? String) ?? "ShareKey"
        let appGroupId = (Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String)
          ?? "group.\(Bundle.main.bundleIdentifier ?? "")"
        guard let defaults = UserDefaults(suiteName: appGroupId) else {
          result(nil)
          return
        }
        // The ShareExtension stores a JSONEncoder-encoded SharedMedia
        // as Data; extract the `content` field (used for text/URL shares).
        if let data = defaults.object(forKey: key) as? Data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          let content = json["content"] as? String
          defaults.removeObject(forKey: key)
          result(content)
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.shareChannel = channel

    self.widgetBridgePlugin = WidgetBridgePlugin(messenger: registrar.messenger())
  }
}
