import Foundation

/// Identifiers shared by the iOS Runner app and the WidgetKit
/// extension. Reuses the existing share-extension App Group so we
/// don't have to provision a widget-only group.
enum PlotWidgetSharedStorage {
  static let appGroup = "group.day.plot.app"
  static let widgetStateKey = "widgetState"

  static func sharedDefaults() -> UserDefaults? {
    UserDefaults(suiteName: appGroup)
  }

  static func currentState() -> [String: Any]? {
    guard
      let defaults = sharedDefaults(),
      let raw = defaults.string(forKey: widgetStateKey),
      let data = raw.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return json
  }
}
