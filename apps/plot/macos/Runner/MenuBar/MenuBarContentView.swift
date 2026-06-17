import SwiftUI

struct MenuBarContentView: View {
  @ObservedObject var model: MenuBarModel
  @State private var captureText = ""
  @State private var captureAsTodo = false
  @State private var captureTodoHover = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !model.isSignedIn {
        Text("Plot").foregroundStyle(.secondary)
      } else {
        eventsSection
        focusSection
        captureSection
        timerSection
      }
      Divider()
      footer
    }
    .padding(12)
    .frame(width: 320)
  }

  @ViewBuilder private var eventsSection: some View {
    if model.currentEvent != nil || model.nextEvent != nil {
      VStack(alignment: .leading, spacing: 6) {
        if let e = model.currentEvent { eventRow("Now", e, showTime: false) }
        if let e = model.nextEvent { eventRow("Next", e, showTime: true) }
      }
      Divider()
    }
  }

  private func eventRow(_ label: String, _ e: MBEvent, showTime: Bool) -> some View {
    HStack {
      Button {
        var args: [String: String] = ["threadId": e.threadId]
        if let focusId = model.currentFocus?.focusId {
          args["priorityId"] = focusId
        }
        model.onAction?("navigateThread", args)
      } label: {
        VStack(alignment: .leading, spacing: 1) {
          Text(label).font(.caption).foregroundStyle(.secondary)
          HStack {
            Text(e.title).lineLimit(1)
            Spacer()
            if showTime, let t = eventTimeText(e) {
              Text(t).font(.subheadline).foregroundStyle(.secondary)
            }
          }
        }
      }
      .buttonStyle(.plain)
      if e.hasCall {
        Button("Join") {
          model.onAction?("joinCall", ["threadId": e.threadId])
        }
      }
    }
  }

  /// Human-friendly time for an upcoming event: "in 25m" within the hour,
  /// "at 7:00 PM" later today, else "Wed 7:00 PM". Nil if the start can't be
  /// parsed. Computed at render — the popover opens fresh each time.
  private func eventTimeText(_ e: MBEvent) -> String? {
    guard let start = Self.parseIso(e.startIso) else { return nil }
    let secs = start.timeIntervalSinceNow
    if secs <= 60 { return "now" }
    let mins = Int((secs / 60).rounded())
    if mins < 60 { return "in \(mins)m" }
    let fmt = DateFormatter()
    if Calendar.current.isDateInToday(start) {
      fmt.dateFormat = "h:mm a"
      return fmt.string(from: start)
    }
    fmt.dateFormat = "EEE h:mm a"
    return fmt.string(from: start)
  }

  static func parseIso(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
  }

  @ViewBuilder private var focusSection: some View {
    if let f = model.currentFocus {
      HStack {
        Text(focusLabel(f)).font(.headline)
          .foregroundStyle(color(f.colorHex) ?? .primary)
        Spacer()
        Menu {
          ForEach(model.focuses) { opt in
            Button(focusLabel(opt)) {
              model.onAction?("setCurrentFocus", ["focusId": opt.focusId])
            }
          }
        } label: { Image(systemName: "chevron.down") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
      }
      .contentShape(Rectangle())
      .onTapGesture { model.onAction?("navigateFocus", ["priorityId": f.focusId]) }

      ForEach(Array(model.todos.prefix(5))) { t in
        Button {
          model.onAction?("navigateThread",
                          ["threadId": t.threadId, "priorityId": f.focusId])
        } label: {
          HStack { Image(systemName: "square"); Text(t.title).lineLimit(1); Spacer() }
        }
        .buttonStyle(.plain)
      }
      Divider()
    }
  }

  @ViewBuilder private var captureSection: some View {
    HStack(spacing: 6) {
      // To-do toggle: plus.circle (make a to-do) → filled circle (is a to-do),
      // swapping to xmark.circle on hover to signal "click to make it a note".
      Button {
        captureAsTodo.toggle()
      } label: {
        Image(systemName: captureAsTodo
            ? (captureTodoHover ? "xmark.circle" : "circle.inset.filled")
            : "plus.circle")
          .foregroundStyle(captureAsTodo ? Color.accentColor : .secondary)
      }
      .buttonStyle(.plain)
      .onHover { captureTodoHover = $0 }
      .help(captureAsTodo
          ? "To-do — click to make it a note"
          : "Add as a to-do (⌘↵)")

      TextField(capturePlaceholder, text: $captureText)
        .textFieldStyle(.plain)
        .onSubmit { submitCapture(asTodo: captureAsTodo) }
      Button(action: { submitCapture(asTodo: captureAsTodo) }) {
        Image(systemName: "return")
      }
      .disabled(captureText.isEmpty)

      // Hidden ⌘↵ shortcut: always submit as a to-do (mirrors the app).
      Button("") { submitCapture(asTodo: true) }
        .keyboardShortcut(.return, modifiers: .command)
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
  }

  private var captureSection_target: String {
    model.currentEvent != nil ? "currentEventThread" : "newThreadInCurrentFocus"
  }
  private var capturePlaceholder: String {
    if let e = model.currentEvent { return "Add note in \(e.title)…" }
    if let f = model.currentFocus { return "Add note in \(f.focusName)…" }
    return "Add a note…"
  }
  private func submitCapture(asTodo: Bool) {
    let text = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    model.onAction?("capture", [
      "text": text,
      "target": captureSection_target,
      "asTodo": asTodo,
    ])
    captureText = ""
    captureAsTodo = false
  }

  @ViewBuilder private var timerSection: some View {
    Divider()
    HStack {
      Image(systemName: "timer")
      Text(model.titleIsTimer ? "Focus timer running" : "Focus timer")
      Spacer()
      if model.titleIsTimer {
        Button("Pause") { model.onAction?("pauseTimer", [:]) }
        Button("Stop") { model.onAction?("stopTimer", [:]) }
      } else {
        Button("Start") { model.onAction?("startTimer", [:]) }
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("Open Plot") { model.onAction?("openApp", [:]) }
      Spacer()
      Button("Quit") { model.onQuit?() }
    }
  }

  private func focusLabel(_ f: MBFocus) -> String {
    if let r = f.roleName { return "\(r) › \(f.focusName)" }
    return f.focusName
  }
  private func color(_ hex: String?) -> Color? {
    guard let hex, hex.hasPrefix("#"), hex.count == 7,
          let v = Int(hex.dropFirst(), radix: 16) else { return nil }
    return Color(red: Double((v >> 16) & 0xff) / 255,
                 green: Double((v >> 8) & 0xff) / 255,
                 blue: Double(v & 0xff) / 255)
  }
}
