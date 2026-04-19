# Global Hotkey Quick-Add Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Raycast-style quick-capture window that opens on a global hotkey (`⌘⇧N` / `Ctrl+Shift+N`), shows `NewThreadPage` in a second native window, and leaves the main window untouched.

**Architecture:** One Flutter engine, two `FlutterView`s (following the `flutter/flutter` `examples/multiple_windows` pattern). Native code on macOS and Windows owns a second top-level window hosting a `FlutterView` bound to the same engine. Dart switches from `runApp` to `runWidget` + `ViewCollection` to route the primary view to `App` and the secondary view to `QuickAddWindow`. A `hotkey_manager` plugin registers the shortcut and calls a `plot/quick_add` method channel.

**Tech Stack:** Flutter multi-view (≥ 3.10 view APIs), `hotkey_manager` package, Swift/AppKit (macOS), Win32 + Flutter C++ embedder (Windows).

**Spec:** `docs/superpowers/specs/2026-04-18-global-hotkey-quick-add-design.md`

---

## File Map

**Created (Dart):**
- `apps/plot/lib/quick_add/quick_add.dart` — hotkey registration + method-channel wrapper + secondary-view id state.
- `apps/plot/lib/quick_add/quick_add_window.dart` — root widget for the secondary view: providers + `NewThreadPage` shell.

**Created (native):**
- `apps/plot/macos/Runner/QuickAddWindowController.swift` — secondary `NSWindow` + `FlutterViewController` lifecycle.
- `apps/plot/windows/runner/quick_add_window.h` / `.cpp` — secondary `Win32Window` + `FlutterViewController` lifecycle.

**Modified:**
- `apps/plot/pubspec.yaml` — add `hotkey_manager`.
- `apps/plot/lib/main.dart` — init `QuickAdd`, switch to multi-view `runWidget`.
- `apps/plot/lib/page/new_thread.dart` — add optional `onDismiss` callback prop.
- `apps/plot/macos/Runner/MainFlutterWindow.swift` — register `plot/quick_add` method channel, own the `QuickAddWindowController`.
- `apps/plot/windows/runner/flutter_window.cpp` / `.h` — register `plot/quick_add` method channel, own the `QuickAddWindow`.
- `apps/plot/windows/runner/CMakeLists.txt` — add the new .cpp/.h.

---

## Task 1: Add `hotkey_manager` dependency

**Files:**
- Modify: `apps/plot/pubspec.yaml`

- [ ] **Step 1: Add the dependency**

Insert under existing desktop deps (near `window_manager`):

```yaml
  hotkey_manager: ^0.2.3
```

- [ ] **Step 2: Install**

Run: `cd apps/plot && flutter pub get`
Expected: succeeds; `pubspec.lock` updates.

- [ ] **Step 3: Verify macOS Podfile picks it up**

Run: `cd apps/plot/macos && pod install`
Expected: succeeds, `hotkey_manager` appears in `Pods/`.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/pubspec.yaml apps/plot/pubspec.lock apps/plot/macos/Podfile.lock
git commit -m "Add hotkey_manager dependency"
```

---

## Task 2: Dart scaffolding for `QuickAdd` (hotkey + method channel)

**Files:**
- Create: `apps/plot/lib/quick_add/quick_add.dart`
- Modify: `apps/plot/lib/main.dart`

- [ ] **Step 1: Create `quick_add.dart` with hotkey + channel stubs**

```dart
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier;
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:logging/logging.dart';

import 'package:plot/analytics/tracker.dart';

final _log = Logger('QuickAdd');

/// Public API for the global hotkey quick-add window.
///
/// Desktop (macOS + Windows) only; a no-op elsewhere.
class QuickAdd {
  QuickAdd._();

  static const MethodChannel _channel = MethodChannel('plot/quick_add');

  /// View id of the secondary FlutterView once the native side has created
  /// the quick-add window. `null` until creation completes.
  static final ValueNotifier<int?> secondaryViewId = ValueNotifier<int?>(null);

  /// Bumped every time the window is shown so the secondary view can remount
  /// `NewThreadPage` with fresh state.
  static final ValueNotifier<int> showEpoch = ValueNotifier<int>(0);

  static bool get _supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  static Future<void> init() async {
    if (!_supported) return;

    _channel.setMethodCallHandler(_onNativeCall);

    try {
      await hotKeyManager.unregisterAll();
      final hotKey = HotKey(
        key: PhysicalKeyboardKey.keyN,
        modifiers: [
          if (Platform.isMacOS) HotKeyModifier.meta,
          if (Platform.isWindows) HotKeyModifier.control,
          HotKeyModifier.shift,
        ],
        scope: HotKeyScope.system,
      );
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) => _onHotKeyPressed(),
      );
      _log.info('Registered global quick-add hotkey');
    } catch (error, stackTrace) {
      _log.warning('Hotkey registration failed', error, stackTrace);
      await Tracker.captureException(error, stackTrace);
    }
  }

  static Future<void> show() async {
    if (!_supported) return;
    showEpoch.value = showEpoch.value + 1;
    try {
      await _channel.invokeMethod<void>('show');
    } catch (error, stackTrace) {
      _log.warning('Quick-add show failed', error, stackTrace);
      await Tracker.captureException(error, stackTrace);
    }
  }

  static Future<void> hide() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('hide');
    } catch (error, stackTrace) {
      _log.warning('Quick-add hide failed', error, stackTrace);
      await Tracker.captureException(error, stackTrace);
    }
  }

  static Future<void> _onHotKeyPressed() => show();

  static Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'viewCreated':
        final id = call.arguments as int?;
        _log.info('Quick-add secondary view id: $id');
        secondaryViewId.value = id;
        return null;
      case 'viewDestroyed':
        secondaryViewId.value = null;
        return null;
      case 'requestHide':
        // Native-side dismissal (focus loss, Esc handled natively, etc.)
        return null;
      default:
        throw PlatformException(
          code: 'unimplemented',
          message: 'Unknown method ${call.method}',
        );
    }
  }
}
```

- [ ] **Step 2: Wire `QuickAdd.init()` into `main.dart`**

In `apps/plot/lib/main.dart`, add the import and call after `AppInfo.init()`:

```dart
import 'quick_add/quick_add.dart';
```

Inside the main `try { ... }` block in `run(...)`, after `await AppInfo.init();`:

```dart
    await QuickAdd.init();
```

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/quick_add/quick_add.dart lib/main.dart`
Expected: no issues.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/quick_add/quick_add.dart apps/plot/lib/main.dart
git commit -m "Scaffold QuickAdd service (hotkey + method channel)"
```

---

## Task 3: macOS — register method channel + spawn an empty secondary window

**Files:**
- Create: `apps/plot/macos/Runner/QuickAddWindowController.swift`
- Modify: `apps/plot/macos/Runner/MainFlutterWindow.swift`

Goal of this task: pressing the hotkey causes a second empty `NSWindow` to appear. Dart content comes in Task 5.

- [ ] **Step 1: Create `QuickAddWindowController.swift`**

```swift
import Cocoa
import FlutterMacOS

/// Owns the secondary NSWindow that hosts the quick-add Flutter view.
/// The view is attached to the *same* FlutterEngine as the main window so
/// it shares Dart state (Blocs, DB, providers) with the main app.
final class QuickAddWindowController: NSObject, NSWindowDelegate {
  private let engine: FlutterEngine
  private let channel: FlutterMethodChannel
  private var window: NSWindow?
  private var viewController: FlutterViewController?

  init(engine: FlutterEngine, channel: FlutterMethodChannel) {
    self.engine = engine
    self.channel = channel
    super.init()
  }

  func show() {
    if window == nil {
      createWindow()
    }
    guard let window = window else { return }
    centerOnActiveScreen(window)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func hide() {
    window?.orderOut(nil)
  }

  private func createWindow() {
    let size = NSSize(width: 720, height: 420)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.isMovableByWindowBackground = true
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.delegate = self

    // Rounded corners via layer on contentView.
    window.contentView?.wantsLayer = true
    window.contentView?.layer?.cornerRadius = 12
    window.contentView?.layer?.masksToBounds = true

    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    window.contentViewController = controller

    self.window = window
    self.viewController = controller

    // Report the secondary view id to Dart.
    if let viewId = controller.viewIdentifier {
      channel.invokeMethod("viewCreated", arguments: Int(viewId))
    }
  }

  private func centerOnActiveScreen(_ window: NSWindow) {
    let screen = NSScreen.main ?? NSScreen.screens.first
    guard let frame = screen?.visibleFrame else { window.center(); return }
    let size = window.frame.size
    let origin = NSPoint(
      x: frame.midX - size.width / 2,
      y: frame.midY - size.height / 2 + 80 // bias slightly above center
    )
    window.setFrameOrigin(origin)
  }

  // MARK: NSWindowDelegate

  func windowDidResignKey(_ notification: Notification) {
    hide()
  }
}

extension FlutterViewController {
  /// The view id used by Flutter's multi-view APIs.
  /// `FlutterViewController.viewIdentifier` is exposed on recent embedder
  /// versions; fall back via key path to stay version-tolerant.
  var viewIdentifier: Int64? {
    if responds(to: Selector(("viewIdentifier"))) {
      return (value(forKey: "viewIdentifier") as? NSNumber)?.int64Value
    }
    return nil
  }
}
```

- [ ] **Step 2: Register the method channel + controller in `MainFlutterWindow.swift`**

Replace the file contents with:

```swift
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var quickAddController: QuickAddWindowController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "plot/quick_add",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    let controller = QuickAddWindowController(
      engine: flutterViewController.engine,
      channel: channel
    )
    self.quickAddController = controller

    channel.setMethodCallHandler { [weak controller] call, result in
      guard let controller = controller else {
        result(FlutterError(code: "unavailable", message: "QuickAdd not ready", details: nil))
        return
      }
      switch call.method {
      case "show":
        controller.show()
        result(nil)
      case "hide":
        controller.hide()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
```

- [ ] **Step 3: Build and manually verify**

Run: `cd apps/plot && flutter run -d macos`
Press `⌘⇧N`. Expected: a second empty floating window appears, centered. Clicking away hides it. Logs show `Registered global quick-add hotkey` and `Quick-add secondary view id: <n>`.

If `viewIdentifier` returns `nil` on your Flutter version, temporarily pass `-1` through so the rest of the flow still runs — Task 5 will validate the id is real.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/macos/Runner/QuickAddWindowController.swift apps/plot/macos/Runner/MainFlutterWindow.swift
git commit -m "macOS: spawn empty secondary window on quick-add hotkey"
```

---

## Task 4: `NewThreadPage` — accept optional `onDismiss`

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Add constructor param**

In the `NewThreadPage` class (around line 63), add:

```dart
  const NewThreadPage({
    super.key,
    @QueryParam('startTime') this.startTime,
    @QueryParam('endTime') this.endTime,
    @QueryParam('duration') this.duration,
    @QueryParam('priorityId') this.priorityId,
    @QueryParam('sharedUrl') this.sharedUrl,
    this.onDismiss,
  });

  final String? startTime;
  final String? endTime;
  final int? duration;
  final String? priorityId;
  final String? sharedUrl;

  /// Called when the page wants to close itself (submit or cancel).
  /// When set, overrides the default router-pop behavior — used by the
  /// quick-add window so the page can hide a native window instead of
  /// popping a route.
  final VoidCallback? onDismiss;
```

- [ ] **Step 2: Use it wherever the page currently pops**

Search for existing close/submit/cancel paths in `new_thread.dart`. For each site that would pop a route (e.g. after `threads.save()` completes, in the Esc shortcut handler, in the close button), replace the pop call with:

```dart
if (widget.onDismiss != null) {
  widget.onDismiss!();
} else {
  // existing router pop / navigator pop / AutoRouter.of(context).maybePop()
}
```

The concrete pop site(s) live near the submit button and the Esc `CallbackShortcuts` map; use `grep -n 'router\|pop\|maybePop' apps/plot/lib/page/new_thread.dart` to confirm you hit them all. Every call site that today removes the route must be guarded.

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/page/new_thread.dart`
Expected: no issues.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart
git commit -m "Add onDismiss callback to NewThreadPage"
```

---

## Task 5: `QuickAddWindow` widget — render `NewThreadPage` in the secondary view

**Files:**
- Create: `apps/plot/lib/quick_add/quick_add_window.dart`
- Modify: `apps/plot/lib/main.dart`

Goal: primary view renders `App`, secondary view (when present) renders `QuickAddWindow`. This uses multi-view `runWidget` so both views share one engine.

- [ ] **Step 1: Create `quick_add_window.dart`**

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/page/new_thread.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/settings.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/state/root_provider.dart';
import 'package:plot/command/command.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/widget.dart' show ColourScheme;

import 'quick_add.dart';

/// Root widget rendered into the secondary FlutterView.
///
/// Mirrors the provider stack used by [App] so [NewThreadPage] sees the
/// same Blocs / router / theme it expects. Shares the Flutter engine (and
/// therefore the Drift DB + auth state) with the primary view.
class QuickAddWindow extends StatelessWidget {
  const QuickAddWindow({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => ThemeBloc()),
        BlocProvider(create: (_) => LocalPreferencesBloc()),
        BlocProvider(create: (_) => SettingsBloc()),
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ColourScheme(
          child: Builder(
            builder: (context) => CommandProvider(
              child: FTheme(
                data: buildTheme(context, context.colour),
                child: FToaster(
                  child: RootProvider(
                    builder: (_) => material.MaterialApp(
                      debugShowCheckedModeBanner: false,
                      theme: material.ThemeData(
                        colorScheme: material.ColorScheme.fromSeed(
                          seedColor: const Color(0x002BDD66),
                          brightness:
                              context.colour.brightness == Brightness.light
                                  ? material.Brightness.light
                                  : material.Brightness.dark,
                        ),
                      ),
                      home: ValueListenableBuilder<int>(
                        valueListenable: QuickAdd.showEpoch,
                        builder: (context, epoch, _) => NewThreadPage(
                          key: ValueKey('quick-add-$epoch'),
                          onDismiss: () => QuickAdd.hide(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

Note: `buildTheme` and `ColourScheme` are imported from the same modules `App` uses. If `App`'s provider stack drifts, keep this file in sync.

- [ ] **Step 2: Switch `main.dart` to multi-view `runWidget`**

Replace the final `return runApp(const App());` in `run(...)` with a multi-view render. Imports:

```dart
import 'dart:ui' show FlutterView, PlatformDispatcher;
import 'quick_add/quick_add_window.dart';
```

New render helper near the bottom of `main.dart`:

```dart
void _renderViews() {
  final dispatcher = PlatformDispatcher.instance;
  final primary = dispatcher.implicitView;
  final secondaryId = QuickAdd.secondaryViewId.value;
  FlutterView? secondary;
  if (secondaryId != null) {
    for (final view in dispatcher.views) {
      if (view.viewId == secondaryId) {
        secondary = view;
        break;
      }
    }
  }

  runWidget(
    ViewCollection(
      views: [
        if (primary != null) View(view: primary, child: const App()),
        if (secondary != null)
          View(view: secondary, child: const QuickAddWindow()),
      ],
    ),
  );
}
```

Replace the `return runApp(const App());` with:

```dart
    log.info('Starting App');
    _renderViews();
    QuickAdd.secondaryViewId.addListener(_renderViews);
    return;
```

- [ ] **Step 3: Run and verify**

Run: `cd apps/plot && flutter run -d macos`
Press `⌘⇧N`. Expected: secondary window now shows `NewThreadPage`. Submitting or pressing Esc hides the window (because `onDismiss` calls `QuickAdd.hide`). Pressing the hotkey again reopens with a fresh form (key bumps from `showEpoch`).

If the second window shows a blank frame: check that `viewIdentifier` on `FlutterViewController` returned a real id (print it from Swift). Some Flutter versions expose it as `FlutterViewController.viewId` — fall back in Swift to that property if needed.

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/quick_add lib/main.dart`
Expected: no issues.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/quick_add/quick_add_window.dart apps/plot/lib/main.dart
git commit -m "Render NewThreadPage in quick-add secondary view (macOS)"
```

---

## Task 6: macOS polish — Esc dismisses; fresh form on re-show

**Files:**
- Modify: `apps/plot/macos/Runner/QuickAddWindowController.swift`

- [ ] **Step 1: Make the window accept Esc**

Add an `NSWindow` subclass that treats Esc as a hide, so it works even when focus is inside a non-editable area. Inside `QuickAddWindowController.swift`, above the class, add:

```swift
final class QuickAddNSWindow: NSWindow {
  var onEscape: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_ sender: Any?) {
    onEscape?()
  }
}
```

In `createWindow()` change the `NSWindow(...)` construction to `QuickAddNSWindow(...)` and, after configuring it, set:

```swift
    (window as? QuickAddNSWindow)?.onEscape = { [weak self] in self?.hide() }
```

- [ ] **Step 2: Verify**

Run: `cd apps/plot && flutter run -d macos`
Press `⌘⇧N`, then Esc. Expected: window hides. Re-open, type, submit → window hides and thread appears in main app list.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/macos/Runner/QuickAddWindowController.swift
git commit -m "macOS: Esc dismisses quick-add window"
```

---

## Task 7: Windows — method channel + secondary `Win32Window` + `FlutterViewController`

**Files:**
- Create: `apps/plot/windows/runner/quick_add_window.h`
- Create: `apps/plot/windows/runner/quick_add_window.cpp`
- Modify: `apps/plot/windows/runner/flutter_window.h`
- Modify: `apps/plot/windows/runner/flutter_window.cpp`
- Modify: `apps/plot/windows/runner/CMakeLists.txt`

- [ ] **Step 1: Create `quick_add_window.h`**

```cpp
#ifndef RUNNER_QUICK_ADD_WINDOW_H_
#define RUNNER_QUICK_ADD_WINDOW_H_

#include <flutter/method_channel.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/flutter_engine.h>

#include <memory>
#include <Windows.h>

#include "win32_window.h"

// Secondary top-level window that hosts a FlutterViewController bound to the
// *shared* FlutterEngine owned by FlutterWindow. Used for the global-hotkey
// quick-add surface.
class QuickAddWindow : public Win32Window {
 public:
  QuickAddWindow(flutter::FlutterEngine* engine,
                 flutter::MethodChannel<flutter::EncodableValue>* channel);
  ~QuickAddWindow() override;

  // Lazily creates and shows the window; centered on the cursor's monitor.
  void Show();
  void Hide();

 protected:
  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept override;

 private:
  bool EnsureCreated();
  void CenterOnCursorMonitor();

  flutter::FlutterEngine* engine_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  bool created_ = false;
};

#endif  // RUNNER_QUICK_ADD_WINDOW_H_
```

- [ ] **Step 2: Create `quick_add_window.cpp`**

```cpp
#include "quick_add_window.h"

#include <dwmapi.h>
#include <flutter/encodable_value.h>

namespace {
constexpr int kWidth = 720;
constexpr int kHeight = 420;
}  // namespace

QuickAddWindow::QuickAddWindow(
    flutter::FlutterEngine* engine,
    flutter::MethodChannel<flutter::EncodableValue>* channel)
    : engine_(engine), channel_(channel) {}

QuickAddWindow::~QuickAddWindow() {
  controller_ = nullptr;
}

bool QuickAddWindow::EnsureCreated() {
  if (created_) return true;

  const wchar_t* title = L"Plot Quick Add";
  const Point origin(0, 0);
  const Size size(kWidth, kHeight);
  if (!Win32Window::Create(title, origin, size)) {
    return false;
  }
  created_ = true;

  // Borderless + topmost + tool window (no taskbar entry).
  HWND hwnd = GetHandle();
  LONG style = GetWindowLong(hwnd, GWL_STYLE);
  style &= ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
             WS_SYSMENU);
  style |= WS_POPUP;
  SetWindowLong(hwnd, GWL_STYLE, style);
  LONG ex = GetWindowLong(hwnd, GWL_EXSTYLE);
  ex |= WS_EX_TOPMOST | WS_EX_TOOLWINDOW;
  SetWindowLong(hwnd, GWL_EXSTYLE, ex);

  // Rounded corners (Windows 11+; no-op on Win10).
  DWM_WINDOW_CORNER_PREFERENCE pref = DWMWCP_ROUND;
  DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &pref,
                        sizeof(pref));

  // Attach a second FlutterViewController to the shared engine.
  controller_ = std::make_unique<flutter::FlutterViewController>(
      kWidth, kHeight, engine_);
  if (!controller_ || !controller_->view()) {
    created_ = false;
    return false;
  }
  SetChildContent(controller_->view()->GetNativeWindow());

  // Report view id to Dart.
  int64_t view_id = controller_->view()->view_id();
  channel_->InvokeMethod(
      "viewCreated",
      std::make_unique<flutter::EncodableValue>(view_id));

  return true;
}

void QuickAddWindow::Show() {
  if (!EnsureCreated()) return;
  CenterOnCursorMonitor();
  HWND hwnd = GetHandle();
  ShowWindow(hwnd, SW_SHOW);
  SetForegroundWindow(hwnd);
  SetFocus(hwnd);
}

void QuickAddWindow::Hide() {
  if (!created_) return;
  ShowWindow(GetHandle(), SW_HIDE);
}

void QuickAddWindow::CenterOnCursorMonitor() {
  POINT pt;
  GetCursorPos(&pt);
  HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {sizeof(MONITORINFO)};
  if (!GetMonitorInfo(mon, &info)) return;
  int x = (info.rcWork.left + info.rcWork.right) / 2 - kWidth / 2;
  int y = (info.rcWork.top + info.rcWork.bottom) / 2 - kHeight / 2 - 80;
  SetWindowPos(GetHandle(), HWND_TOPMOST, x, y, kWidth, kHeight,
               SWP_NOACTIVATE);
}

LRESULT QuickAddWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam) noexcept {
  if (controller_) {
    auto result = controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                        lparam);
    if (result) return *result;
  }
  switch (message) {
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        Hide();
        return 0;
      }
      break;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        Hide();
        return 0;
      }
      break;
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
```

- [ ] **Step 3: Own a `QuickAddWindow` from `FlutterWindow`**

In `flutter_window.h`, add:

```cpp
#include "quick_add_window.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
```

Add private members:

```cpp
  std::unique_ptr<QuickAddWindow> quick_add_window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> quick_add_channel_;
```

In `flutter_window.cpp` `OnCreate()`, after `RegisterPlugins(flutter_controller_->engine());`, add:

```cpp
  quick_add_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "plot/quick_add",
          &flutter::StandardMethodCodec::GetInstance());

  quick_add_window_ = std::make_unique<QuickAddWindow>(
      flutter_controller_->engine(), quick_add_channel_.get());

  quick_add_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "show") {
          quick_add_window_->Show();
          result->Success();
        } else if (call.method_name() == "hide") {
          quick_add_window_->Hide();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
```

- [ ] **Step 4: Add to `CMakeLists.txt`**

In `apps/plot/windows/runner/CMakeLists.txt`, find the `BINARY_NAME` executable sources list and add:

```
  "quick_add_window.cpp"
  "quick_add_window.h"
```

- [ ] **Step 5: Build**

Run: `cd apps/plot && flutter build windows --debug`
Expected: builds; no C++ errors.

If `flutter::FlutterView::view_id()` doesn't exist on your embedder version, use `flutter_controller_->view()->view_id()` with an integer fallback; consult the Flutter Windows embedder headers.

- [ ] **Step 6: Manual verify**

Run: `cd apps/plot && flutter run -d windows`
Press `Ctrl+Shift+N`. Expected: frameless topmost window appears showing `NewThreadPage`. Esc / click-away / submit dismiss it. Main window unaffected.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/windows/runner/quick_add_window.h apps/plot/windows/runner/quick_add_window.cpp apps/plot/windows/runner/flutter_window.h apps/plot/windows/runner/flutter_window.cpp apps/plot/windows/runner/CMakeLists.txt
git commit -m "Windows: spawn quick-add secondary window on Ctrl+Shift+N"
```

---

## Task 8: End-to-end verification + docs

**Files:**
- Modify: `docs/updates.md`
- Modify: `docs/features.md`

- [ ] **Step 1: macOS E2E checklist**

Run the app on macOS and verify all of:
- Main window open, focused → `⌘⇧N` → quick-add appears, main unaffected.
- Main window minimized → `⌘⇧N` → quick-add appears, main stays minimized.
- Main window backgrounded (another app focused) → `⌘⇧N` → quick-add appears without raising main app.
- Submit a new thread → quick-add hides, thread visible in main window.
- Esc dismisses.
- Click outside dismisses.
- Rapid `⌘⇧N` presses do not leak windows (check `lsof | grep -i plot` or Activity Monitor window count).

- [ ] **Step 2: Windows E2E checklist (if Windows environment available)**

Same list with `Ctrl+Shift+N`.

- [ ] **Step 3: Update `docs/updates.md`**

Add a bullet at the top:

```markdown
- Global hotkey quick-add: press ⌘⇧N (macOS) or Ctrl+Shift+N (Windows) from anywhere to pop up a floating window for capturing a new thread — without leaving your current app.
```

- [ ] **Step 4: Update `docs/features.md`**

Add a short "Global hotkey quick-add" section describing the feature.

- [ ] **Step 5: Lint**

Run: `cd apps/plot && flutter analyze`
Expected: no new issues.

- [ ] **Step 6: Commit**

```bash
git add docs/updates.md docs/features.md
git commit -m "Document global hotkey quick-add"
```

---

## Manual Test Matrix

| Scenario | macOS | Windows |
|---|---|---|
| Hotkey while main focused | quick-add on top | quick-add on top |
| Hotkey while main minimized | quick-add appears, main stays minimized | same |
| Hotkey while in another app | quick-add appears, other app *not* raised | same |
| Submit creates thread | appears in main list on next open | same |
| Esc dismisses | yes | yes |
| Click outside dismisses | yes | yes |
| Repeat hotkey doesn't leak windows | yes | yes |
| Quitting app unregisters hotkey | yes (OS cleans up on process exit) | same |

## Risks / Pitfalls

- **`FlutterViewController.viewIdentifier` / `view_id()` API surface** — exact symbol varies by Flutter version. Task 3 and Task 7 both have fallback notes; if neither call works, consult the embedder headers in your installed Flutter SDK and use whatever property returns the `FlutterView` id.
- **Provider drift** — `QuickAddWindow` mirrors `App`'s provider stack. If `App` adds another top-level bloc, `QuickAddWindow` needs the same one or `NewThreadPage` will throw `ProviderNotFoundException` in the secondary view. A short comment in both files should flag this.
- **macOS app activation policy** — `NSApp.activate(ignoringOtherApps: true)` raises the Plot process. If this pulls the main window forward in practice, switch to `makeKeyAndOrderFront(nil)` alone and verify.
- **Windows focus stealing** — `SetForegroundWindow` can be refused by Windows. If the window comes up without focus, use the `AttachThreadInput` workaround or `AllowSetForegroundWindow` from the process that set the hotkey (which is us — should be fine).
- **Double hotkey registration** — `hotkey_manager.unregisterAll()` at init avoids duplicates across hot-restart.

## Self-Review Notes

- Spec coverage: hotkey (Task 2), second window (Tasks 3/7), multi-view Dart (Task 5), dismiss (Tasks 4/6/7), fresh form on re-show (Task 5 via `showEpoch`), main-window untouched (Task 3/7 window config), macOS + Windows only (Task 2 platform gate). Non-goals remain out.
- No placeholders: every step has complete code or a specific command.
- Type consistency: `QuickAdd.show/hide`, `QuickAdd.secondaryViewId`, `QuickAdd.showEpoch`, `onDismiss`, method names `show` / `hide` / `viewCreated` are consistent across Dart + Swift + C++.
