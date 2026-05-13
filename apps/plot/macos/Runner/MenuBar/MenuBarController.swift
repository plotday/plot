import Cocoa

/// Owns the macOS status-item / menu-bar surface.
///
/// State is pushed in-process from `WidgetBridgePlugin.applyState` —
/// we don't go through the App Group container because accessing it
/// would trigger the macOS App Management TCC prompt. The menu bar
/// runs inside the host app process so the in-memory copy stored
/// here is the canonical source.
///
/// The menu mirrors the unified-header tracking control: current
/// priority, current event, current timer, and Start / Pause / Stop /
/// Add 15 min / Remove 15 min controls. The button title shows a live
/// countdown tied to `timerEndsAtIso` from the last state push,
/// ticked by an `NSTimer` so the menu surface stays in sync between
/// Flutter state writes.
final class MenuBarController: NSObject, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var tickTimer: Timer?
  private var currentState: [String: Any] = [:]

  /// Set by `WidgetBridgePlugin` so menu actions can be sent back into
  /// Flutter. Weak-style indirection (a closure capturing the plugin)
  /// keeps the controller decoupled from the plugin class.
  var actionDispatcher: ((String) -> Void)?

  override init() {
    super.init()
    ensureStatusItem()
    rebuildMenu()
    updateTitle()
  }

  /// Replace the state snapshot the menu reads from and re-render
  /// everything that depends on it. Called from
  /// `WidgetBridgePlugin.writeState`.
  func applyState(_ json: String) {
    if let data = json.data(using: .utf8),
       let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      currentState = parsed
    } else {
      currentState = [:]
    }
    rebuildMenu()
    updateTitle()
    restartTickTimer()
  }

  /// Re-render the surface without changing the state snapshot.
  /// Called when Flutter fires `reloadAll` outside of a fresh
  /// `writeState` (e.g. after a force-sync).
  func refresh() {
    rebuildMenu()
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
    }
    statusItem = item
  }

  // MARK: - Title (live countdown)

  /// Window within which an upcoming scheduled event takes over the
  /// menu-bar label as `Nm → EVENT NAME`. Matches the value documented
  /// on `WidgetState.nextEventStartIso` in `widget_data.dart`.
  private static let approachingEventWindow: TimeInterval = 10 * 60

  private func restartTickTimer() {
    tickTimer?.invalidate()
    tickTimer = nil
    guard needsTicking() else { return }
    // Tick at 1Hz so the minute boundary flips promptly. The label
    // itself is ceil-to-minutes, so most ticks are no-ops — but the
    // overhead is negligible and the implementation stays simple.
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.updateTitle()
    }
    RunLoop.main.add(timer, forMode: .common)
    tickTimer = timer
  }

  private func isTimerRunning() -> Bool {
    (currentState["timerState"] as? String) == "running"
  }

  /// True when either a timer is running *or* the next scheduled event
  /// is close enough that the approaching-event banner will appear
  /// within the next tick — both cases need the 1Hz refresh so the
  /// minute label flips promptly.
  private func needsTicking() -> Bool {
    if isTimerRunning() { return true }
    if let secondsUntil = secondsUntilNextEvent(),
       secondsUntil > 0,
       secondsUntil <= Self.approachingEventWindow + 60
    {
      // Add a one-minute pad so we start ticking just before the
      // banner is supposed to appear, instead of waiting for the next
      // `applyState` push from Flutter.
      return true
    }
    return false
  }

  private func updateTitle() {
    guard let button = statusItem?.button else { return }
    // Approaching-event banner takes precedence: "10m → EVENT NAME".
    if let secondsUntil = secondsUntilNextEvent(),
       secondsUntil > 0,
       secondsUntil <= Self.approachingEventWindow,
       let title = currentState["nextEventTitle"] as? String,
       !title.isEmpty
    {
      button.title =
        " " + Self.formatRemaining(secondsUntil) + " → " + title
      return
    }
    if isTimerRunning(), let endsAt = parsedDate(forKey: "timerEndsAtIso") {
      let remaining = endsAt.timeIntervalSinceNow
      button.title = " " + Self.formatRemaining(remaining)
    } else {
      button.title = ""
    }
  }

  /// Seconds until the next scheduled event's start, or nil when no
  /// future event is on the agenda. Negative when the event has
  /// already started (caller filters with `> 0`).
  private func secondsUntilNextEvent() -> TimeInterval? {
    guard let start = parsedDate(forKey: "nextEventStartIso") else {
      return nil
    }
    return start.timeIntervalSinceNow
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
  /// so the menu reads identically to the in-app pill.
  static func formatRemaining(_ seconds: TimeInterval) -> String {
    if seconds <= 0 { return "0m" }
    let totalMinutes = Int((seconds + 59.0) / 60.0)
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
  }

  // MARK: - Menu

  private func rebuildMenu() {
    guard let item = statusItem else { return }
    let menu = NSMenu()
    menu.delegate = self
    // Honor our explicit `isEnabled` flags on action items instead of
    // letting AppKit decide based on responder-chain reachability.
    menu.autoenablesItems = false

    let isSignedIn = (currentState["isSignedIn"] as? Bool) ?? false
    if !isSignedIn {
      let signedOut = NSMenuItem(title: "Plot", action: nil, keyEquivalent: "")
      signedOut.isEnabled = false
      menu.addItem(signedOut)
      menu.addItem(.separator())
      let quitItem = NSMenuItem(
        title: "Quit Plot",
        action: #selector(quitApp(_:)),
        keyEquivalent: "q")
      quitItem.target = self
      menu.addItem(quitItem)
      item.menu = menu
      return
    }

    let priorityTitle = (currentState["currentPriorityTitle"] as? String) ?? "Plot"
    let priorityItem = NSMenuItem(
      title: priorityTitle, action: nil, keyEquivalent: "")
    priorityItem.isEnabled = false
    menu.addItem(priorityItem)

    if let eventTitle = currentState["currentEventTitle"] as? String, !eventTitle.isEmpty {
      let eventItem = NSMenuItem(
        title: eventTitle, action: nil, keyEquivalent: "")
      eventItem.isEnabled = false
      eventItem.indentationLevel = 1
      menu.addItem(eventItem)
    }

    let timerItem = NSMenuItem(
      title: timerLabel(), action: nil, keyEquivalent: "")
    timerItem.isEnabled = false
    timerItem.indentationLevel = 1
    menu.addItem(timerItem)

    menu.addItem(.separator())

    addAction(
      to: menu, title: "Start", action: #selector(handleStart(_:)),
      enabled: (currentState["canStart"] as? Bool) ?? false)
    addAction(
      to: menu, title: "Pause", action: #selector(handlePause(_:)),
      enabled: (currentState["canPause"] as? Bool) ?? false)
    addAction(
      to: menu, title: "Stop", action: #selector(handleStop(_:)),
      enabled: (currentState["canStop"] as? Bool) ?? false)

    menu.addItem(.separator())

    addAction(
      to: menu, title: "Add 15 minutes", action: #selector(handleAddTime(_:)),
      enabled: (currentState["canAddTime"] as? Bool) ?? false)
    addAction(
      to: menu, title: "Remove 15 minutes", action: #selector(handleRemoveTime(_:)),
      enabled: (currentState["canRemoveTime"] as? Bool) ?? false)

    menu.addItem(.separator())
    let quitItem = NSMenuItem(
      title: "Quit Plot",
      action: #selector(quitApp(_:)),
      keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    item.menu = menu
  }

  private func addAction(
    to menu: NSMenu, title: String, action: Selector, enabled: Bool
  ) {
    let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
    mi.target = self
    mi.isEnabled = enabled
    menu.addItem(mi)
  }

  private func timerLabel() -> String {
    let timerState = (currentState["timerState"] as? String) ?? "inactive"
    if timerState != "running" {
      return "No timer"
    }
    let prefix = (currentState["timerSource"] as? String) == "event" ? "Event" : "Running"
    if let endsAt = parsedDate(forKey: "timerEndsAtIso") {
      let remaining = endsAt.timeIntervalSinceNow
      return "\(prefix) · \(Self.formatRemaining(remaining))"
    }
    return prefix
  }

  // Rebuild on open so the timer label inside the dropdown is fresh
  // even if `writeState` hasn't fired in the last few seconds.
  func menuWillOpen(_ menu: NSMenu) {
    rebuildMenu()
  }

  // MARK: - Action handlers

  @objc private func handleStart(_ sender: NSMenuItem) {
    actionDispatcher?("startTimer")
  }

  @objc private func handlePause(_ sender: NSMenuItem) {
    actionDispatcher?("pauseTimer")
  }

  @objc private func handleStop(_ sender: NSMenuItem) {
    actionDispatcher?("stopTimer")
  }

  @objc private func handleAddTime(_ sender: NSMenuItem) {
    actionDispatcher?("addTime")
  }

  @objc private func handleRemoveTime(_ sender: NSMenuItem) {
    actionDispatcher?("removeTime")
  }

  @objc private func quitApp(_ sender: NSMenuItem) {
    NSApp.terminate(nil)
  }
}
