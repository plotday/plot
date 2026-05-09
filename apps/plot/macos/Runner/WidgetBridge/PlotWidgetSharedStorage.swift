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

  /// Master gate for all App Group access from the host app. Stored in
  /// `UserDefaults.standard` (the app's PRIVATE container) so reading
  /// or writing it never crosses the sandbox boundary, and therefore
  /// never triggers the macOS App Management TCC prompt
  /// ("Plot would like to access data from other apps").
  ///
  /// While this is `false`, every caller in Runner skips
  /// `sharedDefaults()` entirely. Flip it to `true` only when the user
  /// enables a widget surface (status item, home-screen widget, etc.).
  /// Today no UI flips it — the surfaces don't exist yet — so no
  /// launch ever touches the App Group.
  static let widgetSurfaceEnabledKey = "widgetSurfaceEnabled"

  static func widgetSurfaceEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: widgetSurfaceEnabledKey)
  }

  static func setWidgetSurfaceEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: widgetSurfaceEnabledKey)
  }

  /// Returns the shared `UserDefaults` suite, or `nil` if the App Group
  /// entitlement is misconfigured (e.g. development build without the
  /// group provisioned). Callers MUST gate on `widgetSurfaceEnabled()`
  /// first — otherwise launching with no widget surface enabled trips
  /// the macOS App Management TCC prompt.
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
