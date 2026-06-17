# Menu-bar redesign — Plan 2: macOS NSPopover shell

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the macOS status-item `NSMenu` with an `NSPopover` that renders
the redesigned surface from Plan 1's `WidgetState` (NOW/NEXT events with Join,
current focus + switcher, top-5 to-dos, quick capture, compact timer, footer),
and render the computed title (with a live ticking countdown) in the status-item
button.

**Architecture:** The status-item button toggles an `NSPopover` whose
content is a SwiftUI view (`MenuBarContentView`) driven by an
`ObservableObject` (`MenuBarModel`) decoded from the structured state the
bridge pushes. User interactions call back through the existing
`WidgetBridgePlugin.sendAction(name, args)` channel into Plan 1's
`_handleAction`. The status-item title keeps its 1 Hz tick for the running-timer
case. **Depends on Plan 1** (the contract + action handlers must exist).

**Tech Stack:** Swift, AppKit (`NSStatusItem`, `NSPopover`), SwiftUI
(`NSHostingController`), FlutterMacOS method channel. macOS deployment target is
15.0 (`macos/Podfile`), so SwiftUI is fully available.

## Global Constraints

- UI text sentence case (first word + proper nouns only).
- macOS target 15.0 — SwiftUI APIs through macOS 15 are allowed.
- The menu bar runs in-process; state is pushed in-process (no App Group /
  TCC prompt) — preserve this (see `WidgetBridgePlugin` doc comment).
- Action names are the constants from Plan 1 Task 3 (`navigateThread`,
  `navigateFocus`, `setCurrentFocus`, `joinCall`, `capture`, `openApp`) plus the
  existing timer actions (`startTimer`, `pauseTimer`, `stopTimer`, `addTime`,
  `removeTime`).
- Build check: `cd apps/plot && flutter build macos --debug` must succeed (or
  the `run-app` skill launches it). Native UI is verified manually via run-app,
  not unit tests.
- Do not break the signed-out surface (show a minimal popover: a label + Quit).

## File structure

- **Modify** `apps/plot/lib/widget_bridge/widget_bridge_channel.dart` — `writeState`
  sends the structured `state` map alongside the legacy `json` string (shared
  prerequisite; also unblocks Plan 3).
- **Modify** `apps/plot/macos/Runner/WidgetBridge/WidgetBridgePlugin.swift` —
  pass the structured dictionary to the controller; widen the action dispatcher
  to `(name, args)`.
- **Create** `apps/plot/macos/Runner/MenuBar/MenuBarModel.swift` — Swift state
  model (`Codable`-style decode from `[String: Any]`) + `ObservableObject`.
- **Create** `apps/plot/macos/Runner/MenuBar/MenuBarContentView.swift` — the
  SwiftUI popover content.
- **Modify** `apps/plot/macos/Runner/MenuBar/MenuBarController.swift` — own an
  `NSPopover`, toggle it from the status-item button, feed the model, keep the
  ticking title; remove the `NSMenu` build.

---

### Task 1: Channel sends the structured state map (shared prerequisite)

**Files:**
- Modify: `apps/plot/lib/widget_bridge/widget_bridge_channel.dart:84-96`
- Test: `apps/plot/test/widget_bridge/widget_write_state_test.dart`

**Interfaces:**
- Produces: `writeState` invokes `'writeState'` with
  `{'json': <legacy string>, 'state': <Map from toJson()>}`. Native shells read
  `state` (nested maps/lists) directly; `json` stays until both shells migrate.
- Consumed by: Task 2 (macOS plugin) and Plan 3 (Windows plugin).

- [ ] **Step 1: Write the failing test** (uses a mock method channel):

```dart
// apps/plot/test/widget_bridge/widget_write_state_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_bridge_channel.dart';
import 'package:plot/widget_bridge/widget_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('writeState passes a structured state map', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(widgetBridgeChannelName),
      (call) async {
        calls.add(call);
        return null;
      },
    );

    await WidgetBridgeChannel.instance.writeState(const WidgetState(
      isSignedIn: true,
      title: 'Marketing',
      todos: [WidgetTodo(threadId: 't1', title: 'Draft')],
    ));

    final write = calls.firstWhere((c) => c.method == 'writeState');
    final args = (write.arguments as Map).cast<String, Object?>();
    expect(args.containsKey('state'), isTrue);
    final state = (args['state']! as Map).cast<String, Object?>();
    expect(state['title'], 'Marketing');
    expect((state['todos']! as List).length, 1);
  });
}
```

(Note: this test only passes on a platform `isSupportedPlatform` accepts. Guard
the test with `debugDefaultTargetPlatformOverride = TargetPlatform.macOS;` in
`setUp` and reset it in `tearDown`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_write_state_test.dart`
Expected: FAIL — `args` has no `state` key.

- [ ] **Step 3: Implement** — change `writeState` body:

```dart
      await _channel.invokeMethod<void>('writeState', <String, Object?>{
        'json': jsonEncode(state.toJson()),
        'state': state.toJson(),
      });
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_write_state_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

```bash
cd apps/plot && flutter analyze
git add apps/plot/lib/widget_bridge/widget_bridge_channel.dart apps/plot/test/widget_bridge/widget_write_state_test.dart
git commit -m "feat(widget-bridge): push structured state map over the channel"
```

---

### Task 2: macOS plugin passes structured state + widened action args

**Files:**
- Modify: `apps/plot/macos/Runner/WidgetBridge/WidgetBridgePlugin.swift:30-49`
- Modify: `apps/plot/macos/Runner/MenuBar/MenuBarController.swift:25,37`
- Verify: build only.

**Interfaces:**
- Produces:
  - `MenuBarController.applyState(_ dict: [String: Any])` (new overload taking the
    structured dictionary; the old `applyState(_ json: String)` is removed once
    nothing calls it).
  - `MenuBarController.actionDispatcher: ((String, [String: Any]) -> Void)?`
    (widened signature).
- Consumed by: Tasks 3–6.

- [ ] **Step 1: Widen the dispatcher + add the dict apply path.**

In `MenuBarController.swift` change the property (line 25):

```swift
  var actionDispatcher: ((String, [String: Any]) -> Void)?
```

Add a dictionary `applyState` (alongside / replacing the JSON one):

```swift
  func applyState(_ dict: [String: Any]) {
    currentState = dict
    model.apply(dict)     // see Task 3
    updateTitle()
    restartTickTimer()
  }
```

In `WidgetBridgePlugin.swift`:
- Update the `writeState` case to prefer the structured map:

```swift
    case "writeState":
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad-args", message: "writeState requires a map", details: nil))
        return
      }
      if let state = arguments["state"] as? [String: Any] {
        statusItemController?.applyState(state)
      }
      result(nil)
```

- Update the dispatcher wiring (line 30-32):

```swift
    statusItemController?.actionDispatcher = { [weak self] name, args in
      self?.sendAction(name, args: args)
    }
```

- [ ] **Step 2: Build**

Run: `cd apps/plot && flutter build macos --debug`
Expected: compiles (the `model` reference resolves after Task 3 — implement Task
3 in the same task if executing strictly TDD-free; otherwise temporarily stub
`model.apply`).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/macos/Runner/WidgetBridge/WidgetBridgePlugin.swift apps/plot/macos/Runner/MenuBar/MenuBarController.swift
git commit -m "feat(macos): plugin passes structured state + args to the menu-bar controller"
```

---

### Task 3: `MenuBarModel` — Swift state model

**Files:**
- Create: `apps/plot/macos/Runner/MenuBar/MenuBarModel.swift`

**Interfaces:**
- Produces:
  - `struct MBFocus { let focusId, focusName: String; let roleName: String?; let colorHex: String? }`
  - `struct MBEvent { let threadId, title, startIso: String; let endIso: String?; let hasCall: Bool }`
  - `struct MBTodo { let threadId, title: String }`
  - `final class MenuBarModel: ObservableObject` with `@Published` fields:
    `isSignedIn`, `title: String?`, `titleIsTimer: Bool`, `timerTitlePrefix: String?`,
    `currentFocus: MBFocus?`, `currentEvent: MBEvent?`, `nextEvent: MBEvent?`,
    `todos: [MBTodo]`, `focuses: [MBFocus]`, and a `var onAction: ((String, [String: Any]) -> Void)?`.
  - `func apply(_ dict: [String: Any])` populating the published fields from the
    structured payload keys (`title`, `titleIsTimer`, `timerTitlePrefix`,
    `currentFocus`, `currentEvent2`, `nextEvent2`, `todos`, `focuses`,
    `isSignedIn`).
- Consumed by: Tasks 2, 4, 5.

- [ ] **Step 1: Implement the model**

```swift
import Foundation
import SwiftUI

struct MBFocus: Identifiable, Equatable {
  let focusId: String
  let focusName: String
  let roleName: String?
  let colorHex: String?
  var id: String { focusId }
}

struct MBEvent: Equatable {
  let threadId: String
  let title: String
  let startIso: String
  let endIso: String?
  let hasCall: Bool
}

struct MBTodo: Identifiable, Equatable {
  let threadId: String
  let title: String
  var id: String { threadId }
}

final class MenuBarModel: ObservableObject {
  @Published var isSignedIn = false
  @Published var title: String?
  @Published var titleIsTimer = false
  @Published var timerTitlePrefix: String?
  @Published var currentFocus: MBFocus?
  @Published var currentEvent: MBEvent?
  @Published var nextEvent: MBEvent?
  @Published var todos: [MBTodo] = []
  @Published var focuses: [MBFocus] = []

  /// Set by the controller so SwiftUI rows can emit actions back to Flutter.
  var onAction: ((String, [String: Any]) -> Void)?

  func apply(_ d: [String: Any]) {
    isSignedIn = (d["isSignedIn"] as? Bool) ?? false
    title = d["title"] as? String
    titleIsTimer = (d["titleIsTimer"] as? Bool) ?? false
    timerTitlePrefix = d["timerTitlePrefix"] as? String
    currentFocus = Self.focus(d["currentFocus"] as? [String: Any])
    currentEvent = Self.event(d["currentEvent2"] as? [String: Any])
    nextEvent = Self.event(d["nextEvent2"] as? [String: Any])
    todos = (d["todos"] as? [[String: Any]] ?? []).compactMap {
      guard let id = $0["threadId"] as? String,
            let t = $0["title"] as? String else { return nil }
      return MBTodo(threadId: id, title: t)
    }
    focuses = (d["focuses"] as? [[String: Any]] ?? []).compactMap { Self.focus($0) }
  }

  private static func focus(_ d: [String: Any]?) -> MBFocus? {
    guard let d, let id = d["focusId"] as? String,
          let name = d["focusName"] as? String else { return nil }
    return MBFocus(focusId: id, focusName: name,
                   roleName: d["roleName"] as? String,
                   colorHex: d["colorHex"] as? String)
  }

  private static func event(_ d: [String: Any]?) -> MBEvent? {
    guard let d, let id = d["threadId"] as? String,
          let t = d["title"] as? String,
          let s = d["startIso"] as? String else { return nil }
    return MBEvent(threadId: id, title: t, startIso: s,
                   endIso: d["endIso"] as? String,
                   hasCall: (d["hasCall"] as? Bool) ?? false)
  }
}
```

- [ ] **Step 2: Build**

Run: `cd apps/plot && flutter build macos --debug`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/macos/Runner/MenuBar/MenuBarModel.swift
git commit -m "feat(macos): MenuBarModel decoding the structured widget state"
```

---

### Task 4: Controller owns the popover + ticking title

**Files:**
- Modify: `apps/plot/macos/Runner/MenuBar/MenuBarController.swift`

**Interfaces:**
- Consumes: `MenuBarModel` (Task 3), `MenuBarContentView` (Task 5).
- Produces: a controller that (a) toggles an `NSPopover` from the status-item
  button, (b) keeps `model` current, (c) renders the title from `model.title` /
  `titleIsTimer` / `timerTitlePrefix` with a ticking remaining.

- [ ] **Step 1: Add the popover + model + button action.**

Add stored properties:

```swift
  private let model = MenuBarModel()
  private var popover: NSPopover?
```

In `ensureStatusItem()`, after configuring the button, make it toggle the popover:

```swift
    if let button = item.button {
      button.action = #selector(togglePopover(_:))
      button.target = self
    }
```

Add the popover lifecycle + toggle:

```swift
  private func ensurePopover() {
    guard popover == nil else { return }
    model.onAction = { [weak self] name, args in self?.actionDispatcher?(name, args) }
    let p = NSPopover()
    p.behavior = .transient                 // dismiss on outside click
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
```

- [ ] **Step 2: Rewrite `updateTitle()`** to use the computed title (no more
local precedence):

```swift
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
```

Update `isTimerRunning()`/`needsTicking()` to tick when `model.titleIsTimer` is
true (drop the approaching-event-window special case — the imminent label is now
baked into `model.title` and pushed on each state change; a 60 s tick still
flips the countdown promptly):

```swift
  private func needsTicking() -> Bool { model.titleIsTimer }
```

- [ ] **Step 3: Remove the `NSMenu` code.** Delete `rebuildMenu()`,
`addAction(...)`, `timerLabel()`, `menuWillOpen(...)`, and the `@objc` menu
handlers (`handleStart`…`handleRemoveTime`, `quitApp` stays only if still used —
Quit now lives in the SwiftUI footer via the `openApp`/quit path; keep a
`quitApp` selector reachable from SwiftUI by exposing an action, or send a
dedicated quit through `onAction`). Remove `NSMenuDelegate` conformance and the
`item.menu = menu` assignments. In `init()` replace `rebuildMenu()` with
`ensurePopover()`.

For Quit: add a `widgetActionQuit = 'quit'` handling — simplest is to keep a
native quit. Expose on the model:

```swift
  // in MenuBarModel
  var onQuit: (() -> Void)?
```

and wire `model.onQuit = { NSApp.terminate(nil) }` in `ensurePopover()`.

- [ ] **Step 4: Build + run-app smoke**

Run: `cd apps/plot && flutter build macos --debug`
Then use the `run-app` skill to launch; click the menu-bar icon → the popover
appears (content lands in Task 5). Title shows focus/timer.
Expected: build clean; popover toggles.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/macos/Runner/MenuBar/MenuBarController.swift apps/plot/macos/Runner/MenuBar/MenuBarModel.swift
git commit -m "feat(macos): status item toggles NSPopover; title from computed state"
```

---

### Task 5: `MenuBarContentView` — the SwiftUI popover content

**Files:**
- Create: `apps/plot/macos/Runner/MenuBar/MenuBarContentView.swift`

**Interfaces:**
- Consumes: `MenuBarModel` (`@ObservedObject`), `model.onAction`, `model.onQuit`.
- Produces: the popover UI emitting the Plan 1 action names.

Layout per spec: NOW/NEXT (hidden when both nil) → focus header + switcher →
≤5 to-dos → capture field → compact timer → footer (Open Plot / Quit).

- [ ] **Step 1: Implement the view** (skeleton — refine styling during run-app):

```swift
import SwiftUI

struct MenuBarContentView: View {
  @ObservedObject var model: MenuBarModel
  @State private var captureText = ""

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
        if let e = model.currentEvent { eventRow("Now", e) }
        if let e = model.nextEvent { eventRow("Next", e) }
      }
      Divider()
    }
  }

  private func eventRow(_ label: String, _ e: MBEvent) -> some View {
    HStack {
      VStack(alignment: .leading) {
        Text(label).font(.caption).foregroundStyle(.secondary)
        Text(e.title).lineLimit(1)
      }
      Spacer()
      if e.hasCall {
        Button("Join") {
          model.onAction?("joinCall", ["threadId": e.threadId])
        }
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      model.onAction?("navigateThread",
                      ["threadId": e.threadId,
                       "priorityId": model.currentFocus?.focusId ?? ""])
    }
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
        .menuStyle(.borderlessButton).frame(width: 24)
      }
      .contentShape(Rectangle())
      .onTapGesture { model.onAction?("navigateFocus", ["priorityId": f.focusId]) }

      ForEach(model.todos) { t in
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
    HStack {
      TextField(capturePlaceholder, text: $captureText)
        .textFieldStyle(.plain)
        .onSubmit(submitCapture)
      Button(action: submitCapture) { Image(systemName: "return") }
        .disabled(captureText.isEmpty)
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
  private func submitCapture() {
    let text = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    model.onAction?("capture", ["text": text, "target": captureSection_target])
    captureText = ""
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
```

(The `roleName` here is already role-gated by Plan 1 — it is null unless the user
has 2+ roles — so the view renders the prefix whenever it is present.)

- [ ] **Step 2: Build**

Run: `cd apps/plot && flutter build macos --debug`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/macos/Runner/MenuBar/MenuBarContentView.swift
git commit -m "feat(macos): SwiftUI popover content (events/focus/todos/capture/timer)"
```

---

### Task 6: End-to-end verification via run-app

**Files:** none (verification + styling polish only).

- [ ] **Step 1:** Launch with the `run-app` skill against a seeded local account
  (the margot seed has 3 roles + events).
- [ ] **Step 2:** Verify each behaviour and note results:
  - Title: focus label at rest; `Role › Focus` with multiple roles; switches to
    `Nm → Event` when an event is ≤2 min out; event title while in progress;
    `Focus · Nm` ticking while a timer runs.
  - Popover NOW/NEXT: present with seeded events; **section hidden** when the
    account has no events today.
  - Join: shown only for events whose primary link has a conferencing action;
    clicking launches the URL.
  - Focus switcher: changes current focus; title + to-dos + capture placeholder
    follow.
  - To-dos: ≤5 active tasks for the current focus, tap opens the thread.
  - Capture: typing + Enter creates a note in the current event thread (when an
    event is in progress) or a new thread in the current focus; field clears.
  - Timer: Start/Pause/Stop drive the in-app pill identically.
  - Footer: Open Plot restores the window; Quit terminates.
- [ ] **Step 3:** Polish spacing/typography to match the app; re-verify; commit
  any tweaks.

```bash
git add apps/plot/macos/Runner/MenuBar/
git commit -m "polish(macos): menu-bar popover styling after run-app verification"
```

## Self-review

- **Spec coverage:** title (Task 4), NOW/NEXT + Join + hide-when-empty (Task 5),
  focus header + switcher (Task 5), to-dos (Task 5), capture with target rule
  (Task 5), compact timer (Task 5), footer (Task 5). Structured payload (Task 1)
  unblocks Windows (Plan 3).
- **Placeholder scan:** SwiftUI styling is intentionally skeleton-level and
  finalized in Task 6 via run-app — this is native-UI polish, not a logic TBD.
  No vague logic placeholders.
- **Type consistency:** `MBFocus`/`MBEvent`/`MBTodo` fields match the JSON keys
  Plan 1 emits (`focusId`/`focusName`/`roleName`/`colorHex`,
  `threadId`/`title`/`startIso`/`endIso`/`hasCall`, `currentEvent2`/`nextEvent2`).
  Action names + arg keys (`threadId`, `priorityId`, `focusId`, `text`, `target`)
  match Plan 1 Task 8's `routeWidgetActionForTest`/`_handleAction` expectations.
- **Note:** Plan 1 Task 8 does not define a `quit` action; this plan keeps Quit
  native (`model.onQuit`), so no Dart change is needed. If a future cleanup wants
  Quit to route through Dart, add `widgetActionQuit` to Plan 1 Task 3.
