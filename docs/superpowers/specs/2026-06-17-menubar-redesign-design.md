# Desktop menu-bar / tray widget redesign

Date: 2026-06-17
Status: Design approved, ready for implementation plan

## Summary

The desktop menu-bar surface (macOS `NSStatusItem` menu) and its Windows twin
(notification-area tray icon + context menu) were designed around a Pomodoro
timer. Plot is now a messaging-and-tasks app first, with the timer secondary.
This redesign reorients both surfaces around the user's **current focus**,
their **today's events** (navigate + join call), and a short **to-do glance**,
adds **quick capture**, and demotes the Pomodoro timer to a compact, clearly
labelled section while keeping it fully functional.

Both surfaces already consume one shared `WidgetState` snapshot pushed from
Dart over the `day.plot/widgets` method channel. The feature/data design is
therefore specified once; each OS renders it with a native shell. The two
shells ship in parallel at feature parity.

## Goals

- Make the always-visible title a **context indicator** (current focus / event /
  timer), not a Pomodoro readout.
- Surface today's **current and next event**, each tappable to navigate into its
  focus view (Event Agenda + threads), with **Join call** when applicable.
- Show up to **5 top-ordered active to-do threads** in the current focus,
  each tappable to open.
- Provide a **focus switcher** that sets the app's global current focus.
- Provide **quick capture** without requiring Flutter multi-window support.
- Keep Pomodoro available but visually secondary (compact section + the running
  countdown in the title).
- Maintain macOS ↔ Windows parity from one shared data contract.

## Non-goals

- No Flutter multi-window / second `FlutterEngine`. All popover/popup UI is
  native; only data and small action payloads cross the bridge.
- No global cross-focus unread counter in the title or a tray badge (the to-do
  glance is scoped to the current focus only).
- No mobile/web changes. This is desktop (macOS + Windows) only.
- No change to how events, threads, focuses, roles, or the timer are stored or
  computed in the app's data layer — the widget reads existing state.

## Current state (what exists today)

- **macOS**: `apps/plot/macos/Runner/MenuBar/MenuBarController.swift` owns an
  `NSStatusItem`. The title shows the running Pomodoro countdown, or an event
  countdown when an event starts within 10 min, else empty. The dropdown is an
  `NSMenu` with disabled context labels (priority / event / timer status) plus
  Start / Pause / Stop / Add 15m / Remove 15m / Quit. Events are
  non-interactive labels — no navigation, no join.
- **Windows**: `apps/plot/windows/runner/system_tray/tray_icon.cpp` is a
  feature-parity twin — a `Shell_NotifyIcon` tray icon that renders the
  countdown into its bitmap (GDI, theme-aware), with a right-click `HMENU`
  carrying the same content as the macOS menu.
- **Shared bridge**: `apps/plot/lib/widget_bridge/` — `WidgetBridge` snapshots
  app state (`NowBloc` + `UserBloc`) into a `WidgetState`
  (`widget_data.dart`), serializes to JSON, and writes it over
  `WidgetBridgeChannel` (`day.plot/widgets`). Native actions route back to
  `WidgetBridge._handleAction` → `NowBloc`.

## Architecture decisions

1. **Dropdown shell → rich native popover, not a menu.**
   - macOS: replace the `NSMenu` with an **`NSPopover`** anchored under the
     status item (native AppKit/SwiftUI content).
   - Windows: replace the right-click `HMENU` with a **borderless popup window**
     (layered Win32 window, or WinUI/XAML island) anchored near the tray icon.
   - Rationale: the new content (text field, tappable rows, focus switcher,
     inline Join buttons) does not fit a tracking menu — text input and rich
     rows are awkward/finicky in both `NSMenu` and `HMENU`. Both replacements
     are 100% native and require no Flutter multi-window.

2. **Quick capture stays native; no multi-window.** The Flutter engine runs in
   the background regardless of main-window visibility (the bridge already
   snapshots every 500 ms), so its bloc layer is always live. Capture is: native
   text field → `captureThread(text, target)` over the existing channel → the
   running engine creates the thread/note via the same code path the in-app
   composer uses. Only a string + a target descriptor cross the bridge.

3. **One shared `WidgetState` contract; two native shells in parallel.** All
   feature/data logic lives on the Dart side and is rendered identically by both
   OS shells. New fields/actions are added to the existing channel.

## Always-visible title (menu bar / tray)

A single context slot. First match wins:

1. Event starting within ~2 min (today) → `2m → Standup`
2. Event currently in progress (today) → `Design review`
3. Timer running → the timer's focus shown exactly like the current-focus
   display, with the countdown appended → `Marketing · 24m`
   (or `AFC Marlow › Marketing · 24m` when the user has multiple roles)
4. Otherwise → current focus → `Marketing` (or `AFC Marlow › Marketing`)

Notes:

- States 1–2 only consider **today's** events. If the calendar is not connected
  or there is nothing today, the title falls through to 3/4.
- A running timer is tied to a focus; while running, state 3 effectively
  replaces state 4 (same focus rendering, plus the countdown). The multi-role
  `Role › Focus` prefix follows the existing focus-prefix display rule (shown
  only when the user has 2+ roles).
- Windows renders this string into the tray-icon bitmap as today (GDI,
  theme-aware), keeping the existing ceil-to-minute redraw throttle.

## Popover / popup layout

Top is the most glanceable. Sections, top to bottom:

### 1. Events — `NOW` / `NEXT` (conditional)

```
NOW
 🔴 Design review            [Join]  ›
NEXT
 Standup · in 25m                    ›
```

- Sourced from the user's whole schedule (**cross-focus**), scoped to **today**.
- `NOW` = an event currently in progress. `NEXT` = the next event later today.
- Each row tappable → `navigateToThread(eventThreadId)`: brings the app forward
  and opens that event's focus view (Event Agenda + threads in the same focus).
- **Join** button appears when the event has a call link and the user is within
  the join window: from ~5 min before start through the event's end. Tapping →
  `joinCall(eventThreadId)`.
- **If there is no current and no upcoming event today, the entire section is
  hidden** (common for users who have not connected a calendar). The popover
  then opens straight to the focus section.

### 2. Current focus + to-do glance

```
AFC Marlow › Marketing                ⌄
 ◻ Finalize Q3 budget
 ◻ Review vendor contract
 ◻ Reply to sponsor
 ◻ Draft newsletter
 ◻ Approve logo variants
```

- Header shows the current focus as `Role › Focus` (role prefix only with 2+
  roles), in the focus/role colour, consistent with in-app focus labels.
- The `⌄` opens the **focus switcher**: roles → focuses. Selecting a focus calls
  `setCurrentFocus(focusId)`, which sets the app's **global** current focus — the
  title, this to-do list, and the capture default all follow it.
- Tapping the header text itself → `navigateToFocus(focusId)` (open the app to
  that focus).
- Below the header: up to **5** active task ("to-do") threads in the current
  focus, in the focus's normal in-app top order. Each tappable →
  `navigateToThread(threadId)`. If the focus has no active to-dos, show a short
  empty hint instead of rows.

### 3. Quick capture

```
✎ Add note in Design review…          [↵]
```

- Native single-line (expandable) text field. Submit (`↵` or button) →
  `captureThread(text, target)`.
- **Target default**: the **current event thread** when an event is in progress
  (`Add note in Design review…`); otherwise a **new thread in the current
  focus** (`Add note in Marketing…`). A small toggle flips between the two when
  both are available.
- Label is always **"Add note in {target}…"**.
- On success the field clears and shows a brief confirmation; the popover stays
  open.

### 4. Focus timer (Pomodoro)

```
⏱  Focus timer            25:00   [Start]
```

- Compact section near the bottom. At rest: label + duration + **Start**.
- While running: remaining time + **Pause** / **Stop** + **±15m**, mapping to the
  existing timer actions. The running countdown also drives title state 3.
- This is the demoted home for all Pomodoro controls that used to dominate the
  menu.

### 5. Footer

```
Open Plot                          Quit
```

- **Open Plot** → `openApp` (show/restore the main window). **Quit** as today.

## Shared `WidgetState` contract changes

Additive to the existing snapshot. Current focus, events, to-dos, and the focus
list are new; timer fields remain.

- `currentFocus`: `{ focusId, roleName, focusName, color }` (roleName null when
  single-role).
- `timerFocus`: same shape, present only while a timer runs (usually equals
  `currentFocus`); drives title state 3.
- `currentEvent` / `nextEvent`: `{ id, threadId, title, startIso, endIso,
  joinUrl }` — today-only; null when absent. `joinUrl` null when no call link.
- `joinableNow` (per event): derived bool (within ~5 min before start → end and
  `joinUrl` non-null), so the shell does not compute time windows.
- `todos`: ordered list, ≤5, of `{ threadId, title }` for the current focus.
- `focuses`: list for the switcher — `{ focusId, roleName, focusName, color }`,
  grouped/orderable by role.

New actions Dart must handle in `WidgetBridge._handleAction` (joining the
existing timer actions):

- `navigateToThread(threadId)`
- `navigateToFocus(focusId)`
- `setCurrentFocus(focusId)`
- `joinCall(eventThreadId)`
- `captureThread(text, target)` where `target ∈ { currentEventThread,
  newThreadInCurrentFocus }`
- `openApp`

## Navigation & window handling

- Tapping any row or `Open Plot` must bring the main window forward, recreating
  / showing it if it was closed (macOS: re-show the `FlutterViewController`'s
  window; Windows: restore via `window_manager`). Routing reuses the app's
  existing in-app navigation to a focus or thread.
- `joinCall` opens the event's call link (existing join behaviour / URL launch),
  not a Plot navigation.
- `setCurrentFocus` and `captureThread` do **not** require the window to be
  visible — they act on the live engine and refresh the next snapshot.

## Platform shells (parallel build, parity)

- **macOS**: `NSPopover` anchored to the `NSStatusItem`; AppKit/SwiftUI content
  rendering the sections above; title string unchanged in mechanism (status-item
  button title).
- **Windows**: borderless popup window anchored to the tray icon rendering the
  same sections; tray-icon bitmap continues to render the title string. Replaces
  the right-click `HMENU` for the main surface (a minimal right-click menu may
  remain for Quit as a fallback).
- Both read the same `WidgetState` JSON and emit the same action names. Any
  layout/wording change is made once in the contract/spec and mirrored in both.

## Edge cases

- **No calendar / no events today** → hide the entire `NOW`/`NEXT` section;
  title falls to focus/timer; capture defaults to new-thread-in-focus.
- **No active to-dos in the focus** → show an empty hint, not blank rows.
- **No current focus resolvable** (rare, fresh account) → header shows a neutral
  default; switcher still lists available focuses.
- **Signed out** → minimal popover: a sign-in prompt + Quit (mirror current
  signed-out menu).
- **Event with no call link** → no Join button; row still navigates.
- **Timer running during an in-progress event** → title state 2 (event) wins
  over state 3 (timer); the popover's timer section still reflects the running
  timer.

## Testing

- Dart: unit tests over `WidgetBridge._snapshot` producing the new `WidgetState`
  fields for representative cases (timer running, event now/next, no events
  today, no to-dos, multi-role vs single-role title) and over `_handleAction`
  routing for each new action.
- Title-string precedence: table-driven test of the 4-state precedence including
  the today-only event gating.
- Native shells: manual verification via `run-app` on macOS (popover content,
  navigation, capture, join, focus switch, timer) and a Windows check for the
  parity popup. Native UI is thin (renders state, emits actions), so logic is
  covered on the Dart side.

## Open questions (resolved during design)

- Title content → context indicator with the 4-state precedence above. ✅
- Dropdown features → events (now/next), focus + ≤5 to-dos, quick capture, focus
  switcher, compact timer. ✅
- Quick capture without multi-window → yes, native input + existing engine. ✅
- Shell → `NSPopover` / Windows borderless popup. ✅
- Platform scope → both, in parallel, one shared contract. ✅
- Pomodoro → compact section + running countdown in title. ✅
- Events cross-focus & today-only; hide section when none. ✅
- Focus switch sets global current focus. ✅
- Capture label "Add note in …". ✅
