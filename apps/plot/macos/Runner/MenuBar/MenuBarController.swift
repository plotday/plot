import Cocoa

/// Owns the (optional) macOS status-item / menu-bar surface.
///
/// Always instantiated at app launch; only takes effect when the
/// `statusItemEnabled` flag in the shared App Group `UserDefaults` is
/// `true`. Default is `false` so this controller is a no-op until a
/// future settings toggle (or the user editing UserDefaults directly)
/// flips it on.
///
/// Today the controller has no menu items — it exists so that the
/// menu-bar integration can be designed and dropped into [refresh]
/// without re-plumbing app launch code.
final class MenuBarController {
  private var statusItem: NSStatusItem?

  init() {
    refresh()
  }

  /// Re-evaluate whether the status item should be visible and update
  /// its presentation. Called at startup and again whenever
  /// `WidgetBridgePlugin.reloadAll` fires (i.e. after Flutter writes
  /// new state).
  func refresh() {
    let enabled = isEnabled()
    if enabled {
      ensureStatusItem()
    } else {
      tearDownStatusItem()
    }
  }

  private func isEnabled() -> Bool {
    PlotWidgetSharedStorage.sharedDefaults()?
      .bool(forKey: PlotWidgetSharedStorage.statusItemEnabledKey) ?? false
  }

  private func ensureStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      // Placeholder glyph — replaced when the menu-bar surface is
      // designed. Visible only after the enable flag flips on, which
      // is intentional for now.
      button.title = "Plot"
    }
    statusItem = item
  }

  private func tearDownStatusItem() {
    if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
    }
    statusItem = nil
  }
}
