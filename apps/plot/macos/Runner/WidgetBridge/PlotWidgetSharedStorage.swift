import Foundation

/// Identifiers shared by the macOS Runner app, the WidgetKit extension,
/// and the status-item controller. Keeping them in one place keeps the
/// app group identifier (which must match the entitlement) and the
/// UserDefaults keys from drifting apart.
enum PlotWidgetSharedStorage {
  /// App Group identifier. Must match the entry under
  /// `com.apple.security.application-groups` in both Runner and PlotWidget
  /// entitlement files, and the App Group ID configured in the Apple
  /// Developer portal. Shared with the iOS share extension so we don't
  /// need to provision a separate widget-only group.
  static let appGroup = "group.day.plot.app"

  /// JSON-encoded `WidgetState` (see `lib/widget_bridge/widget_data.dart`).
  static let widgetStateKey = "widgetState"

  /// Bool flag controlling whether the status-item (macOS menu bar)
  /// surface is created at app launch. Defaults to `false`. Toggling
  /// this is reserved for the future settings flow; today nothing
  /// writes it.
  static let statusItemEnabledKey = "statusItemEnabled"

  /// Returns the shared `UserDefaults` suite, or `nil` if the App Group
  /// entitlement is misconfigured (e.g. development build without the
  /// group provisioned).
  static func sharedDefaults() -> UserDefaults? {
    UserDefaults(suiteName: appGroup)
  }

  /// Decoded snapshot of the latest state Flutter wrote.
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
