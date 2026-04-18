# Global Hotkey Quick-Add Window — Design

**Status:** Approved
**Platforms:** macOS, Windows (desktop only)
**Date:** 2026-04-18

## Goal

A Raycast-style quick capture experience: a global hotkey opens a small,
always-on-top window containing `NewThreadPage` so the user can add a thread
without bringing the main app to the foreground. Works while the main window
is minimized or backgrounded; the main window is unaffected by the hotkey.

## Non-Goals (v1)

- Hotkey customization UI (hardcoded default; can ship settings later)
- Pre-filling the new thread from selection, clipboard, or context
- Linux, web, iOS, Android support (no-op on those platforms)
- Persisting an in-flight draft across quick-add window closes
- Launching the quick-add window when the main app is not running

## User Experience

- **Default hotkey:** `⌘⇧N` on macOS, `Ctrl+Shift+N` on Windows.
- **Show:** the second window appears centered on the active display, focused,
  frameless, rounded, ~720 px wide with auto height. The thread editor field
  is auto-focused. Form state is fresh each open.
- **Dismiss:** `Esc`, clicking outside the window, submitting the thread, or
  the window losing focus all hide the window (not destroy — next open
  reuses it so opening is fast).
- **Main window:** never shown, raised, or focused by the hotkey. Minimized
  or backgrounded state is preserved.
- **Multi-press:** pressing the hotkey while the window is already visible
  re-focuses it and resets the form.

## Architecture

Two decoupled pieces:

### 1. Global hotkey registration

- New dependency: `hotkey_manager` (leanflutter — macOS + Windows support).
- Registration happens once during `main.dart` startup, after
  `Window.init()`, gated by `Platform.isMacOS || Platform.isWindows`.
- Hotkey callback invokes a `QuickAdd.show()` Dart API, which delegates to
  the native method channel `plot/quick_add`.
- No unregister on app exit — the OS cleans up when the process exits.

### 2. Second native window with a shared Flutter engine

Following the `flutter/flutter` `examples/multiple_windows` approach: **one
`FlutterEngine`, multiple `FlutterView`s.** The native layer creates a
second top-level window hosting a new `FlutterView` that binds to the same
engine as the main window. This keeps all Dart state (Blocs, Drift DB,
auth, providers) in a single isolate — critical because `NewThreadPage`
has deep provider dependencies we do not want to duplicate.

#### Dart side

- New file `lib/quick_add/quick_add.dart` exposing:
  - `QuickAdd.init()` — called from `main.dart`; registers the hotkey and
    the method channel.
  - `QuickAdd.show()` / `QuickAdd.hide()` — method-channel wrappers.
- New widget `QuickAddWindow` — a root widget providing the same top-level
  providers `App` uses (auth, bloc scope, theme, router-free). Its body is
  `NewThreadPage` wrapped in a minimal scaffold.
- `main.dart` switches from `runApp(const App())` to the multi-view pattern:
  enumerate `PlatformDispatcher.instance.views`, render `App` into the
  primary view and `QuickAddWindow` into the secondary view (when present).
  View identification is by `FlutterView.viewId`; the native side assigns
  the secondary view a known id reported back over the method channel.
- Submit/close handlers in the quick-add instance of `NewThreadPage` call
  `QuickAdd.hide()` instead of `context.router.pop()`. This requires a
  small prop on `NewThreadPage` (e.g. `onDismiss`) so the page doesn't need
  to know about windows.

#### macOS

- Modify `apps/plot/macos/Runner/MainFlutterWindow.swift` (and add a new
  `QuickAddWindow.swift`) to:
  - Register `FlutterMethodChannel("plot/quick_add")` on the main engine.
  - On `show`: lazily create an `NSWindow` with
    - style mask: `.borderless, .resizable` (resizable optional)
    - `isOpaque = false`, rounded `contentView` layer
    - `level = .floating`
    - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
    - contentView = `FlutterView` attached to the shared engine via a new
      `FlutterViewController(engine:nibName:bundle:)`
    - center on `NSScreen.main`
    - call `makeKeyAndOrderFront(nil)` and `NSApp.activate`.
  - On `hide`: `orderOut(nil)`.
  - Observe `NSWindow.didResignKeyNotification` on the quick-add window to
    hide on focus loss.
  - Report the secondary view's id back over the channel on first creation
    so Dart can route `QuickAddWindow` to the correct view.

#### Windows

- Modify `apps/plot/windows/runner/flutter_window.cpp` and
  `win32_window.cpp` (or add a `quick_add_window.cpp`) to:
  - Register `flutter::MethodChannel("plot/quick_add")` on the main engine.
  - On `show`: lazily create a top-level `HWND` with `WS_POPUP`,
    `WS_EX_TOPMOST | WS_EX_TOOLWINDOW`, rounded via `DwmSetWindowAttribute`
    / `SetWindowRgn`, centered on the monitor containing the cursor.
    Attach a new `FlutterViewController` to the shared engine, bind its
    view to the HWND.
  - On `hide`: `ShowWindow(hwnd, SW_HIDE)`.
  - Handle `WM_KILLFOCUS` / `WM_ACTIVATE`(WA_INACTIVE) to auto-hide.
  - Report the secondary view's id to Dart over the channel.

## Data Flow

1. User presses hotkey (anywhere, any app).
2. `hotkey_manager` callback fires in Dart → `QuickAdd.show()` →
   native `show` handler creates/shows the window.
3. Native sends view id over method channel; Dart's multi-view `runApp`
   mounts `QuickAddWindow` into that view on next frame.
4. User types and submits. `NewThreadPage` persists via existing
   commands/Blocs (same engine, same DB). On success, `onDismiss` → Dart
   `QuickAdd.hide()` → native `hide`.
5. Next hotkey press: show the existing window (fast path, no view
   re-creation), reset form state via a `ValueNotifier`/`Key` bump so
   `NewThreadPage` remounts fresh.

## Error Handling

- Hotkey registration failure (e.g. another app owns the shortcut): log
  warning, capture via `Tracker.captureException`, leave app otherwise
  functional. No user-facing UI in v1.
- Native window creation failure: log + `captureException`, surface a
  one-line toast in the main window if visible, otherwise silently fail.
- If the secondary view id never arrives (channel race), the show call
  is a no-op; the hotkey remains functional on retry.

## Files to Create / Modify

**Created:**
- `apps/plot/lib/quick_add/quick_add.dart`
- `apps/plot/lib/quick_add/quick_add_window.dart`
- `apps/plot/macos/Runner/QuickAddWindow.swift`
- `apps/plot/windows/runner/quick_add_window.cpp` + `.h`

**Modified:**
- `apps/plot/pubspec.yaml` — add `hotkey_manager`.
- `apps/plot/lib/main.dart` — init `QuickAdd`, switch to multi-view
  `runWidget` pattern.
- `apps/plot/lib/app.dart` — no-op if routing is already view-scoped;
  otherwise minor extraction so providers can be reused by
  `QuickAddWindow`.
- `apps/plot/lib/page/new_thread.dart` — add optional `onDismiss`
  callback; when present, use it in place of router pop.
- `apps/plot/macos/Runner/MainFlutterWindow.swift` — register method
  channel, own the secondary window lifecycle.
- `apps/plot/windows/runner/flutter_window.cpp` — register method
  channel, own the secondary window lifecycle.

## Testing

- Manual: primary user flow (hotkey → type → submit → thread appears in
  main window when visible) on both macOS and Windows.
- Manual: hotkey while main window minimized / hidden / on another Space
  — window appears without raising main.
- Manual: Esc, outside-click, focus-loss, submit all dismiss correctly.
- Manual: rapid repeat hotkey presses do not leak windows.
- `flutter analyze` on changed Dart files.
- No unit tests for native window code (minimal logic, manual verification).

## Open Questions

None — approved.

## References

- Flutter multi-window example:
  https://github.com/flutter/flutter/tree/master/examples/multiple_windows
- `hotkey_manager`: https://pub.dev/packages/hotkey_manager
