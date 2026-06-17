import Cocoa
import SwiftUI

/// Owns the macOS status-item / menu-bar surface.
///
/// State is pushed in-process from `WidgetBridgePlugin.applyState` —
/// we don't go through the App Group container because accessing it
/// would trigger the macOS App Management TCC prompt. The menu bar
/// runs inside the host app process so the in-memory copy stored
/// here is the canonical source.
///
/// Clicking the status-item button toggles an `NSPopover` that hosts
/// `MenuBarContentView` driven by `MenuBarModel`. The button title shows
/// a live countdown or focus name, ticked by an `NSTimer` when a timer
/// is active.
final class MenuBarController: NSObject {
  private var statusItem: NSStatusItem?
  private var tickTimer: Timer?
  private var currentState: [String: Any] = [:]
  private let model = MenuBarModel()
  private var popover: NSPopover?

  /// Set by `WidgetBridgePlugin` so menu actions can be sent back into
  /// Flutter. Weak-style indirection (a closure capturing the plugin)
  /// keeps the controller decoupled from the plugin class.
  var actionDispatcher: ((String, [String: Any]) -> Void)?

  override init() {
    super.init()
    ensureStatusItem()
    ensurePopover()
    updateTitle()
  }

  /// Replace the state snapshot and re-render everything that depends on
  /// it. Called from `WidgetBridgePlugin.writeState`.
  func applyState(_ json: String) {
    if let data = json.data(using: .utf8),
       let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      currentState = parsed
    } else {
      currentState = [:]
    }
    model.apply(currentState)
    updateTitle()
    restartTickTimer()
  }

  /// Re-render the surface without changing the state snapshot.
  /// Called when Flutter fires `reloadAll` outside of a fresh
  /// `writeState` (e.g. after a force-sync).
  func refresh() {
    model.apply(currentState)
    updateTitle()
    restartTickTimer()
  }

  private func ensureStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      if let image = NSImage(named: "MenuBarIcon") {
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeft
      } else if let fallback = NSImage(
        systemSymbolName: "clock",
        accessibilityDescription: "Plot")
      {
        fallback.isTemplate = true
        button.image = fallback
        button.imagePosition = .imageLeft
      } else {
        button.title = "Plot"
      }
      button.action = #selector(togglePopover(_:))
      button.target = self
    }
    statusItem = item
  }

  private func ensurePopover() {
    guard popover == nil else { return }
    model.onAction = { [weak self] name, args in self?.actionDispatcher?(name, args) }
    model.onQuit = { NSApp.terminate(nil) }
    let p = NSPopover()
    p.behavior = .transient
    p.contentViewController = NSHostingController(
      rootView: MenuBarContentView(model: model))
    popover = p
  }

  @objc private func togglePopover(_ sender: Any?) {
    ensurePopover()
    guard let button = statusItem?.button, let popover else { return }
    if popover.isShown {
      popover.performClose(sender)
    } else {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  // MARK: - Title (live countdown)

  private func restartTickTimer() {
    tickTimer?.invalidate()
    tickTimer = nil
    guard needsTicking() else { return }
    // Tick at 1Hz so the minute boundary flips promptly.
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.updateTitle()
    }
    RunLoop.main.add(timer, forMode: .common)
    tickTimer = timer
  }

  private func needsTicking() -> Bool { model.titleIsTimer }

  private func updateTitle() {
    guard let button = statusItem?.button else { return }
    if model.titleIsTimer, let endsAt = parsedDate(forKey: "timerEndsAtIso") {
      let remaining = endsAt.timeIntervalSinceNow
      let prefix = model.timerTitlePrefix ?? ""
      button.title = prefix.isEmpty
        ? " " + Self.formatRemaining(remaining)
        : " " + prefix + " · " + Self.formatRemaining(remaining)
    } else {
      button.title = (model.title?.isEmpty == false) ? " " + model.title! : ""
    }
  }

  /// Parses an ISO 8601 timestamp stored at `currentState[key]`. Falls
  /// back to a local-time parser if the value is missing a timezone
  /// designator (`DateTime.toIso8601String()` on a non-UTC Dart
  /// DateTime emits `2026-05-13T15:30:00.000` which
  /// `ISO8601DateFormatter` refuses).
  private func parsedDate(forKey key: String) -> Date? {
    guard let iso = currentState[key] as? String else { return nil }
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFormatter.date(from: iso) { return date }
    isoFormatter.formatOptions = [.withInternetDateTime]
    if let date = isoFormatter.date(from: iso) { return date }
    let fallback = DateFormatter()
    fallback.locale = Locale(identifier: "en_US_POSIX")
    fallback.timeZone = TimeZone.current
    for format in [
      "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
      "yyyy-MM-dd'T'HH:mm:ss.SSS",
      "yyyy-MM-dd'T'HH:mm:ss",
    ] {
      fallback.dateFormat = format
      if let date = fallback.date(from: iso) { return date }
    }
    return nil
  }

  /// Ceil-to-minutes, formatted as `Nm` / `Hh` / `Hh Mm`. Mirrors
  /// `_PillLabel._formatMinutes` in `lib/widget/unified_header.dart`
  /// so the status-item title reads identically to the in-app pill.
  static func formatRemaining(_ seconds: TimeInterval) -> String {
    if seconds <= 0 { return "0m" }
    let totalMinutes = Int((seconds + 59.0) / 60.0)
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
  }
}
