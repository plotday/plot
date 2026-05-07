# Widget Bridge Scaffolding

Date: 2026-05-06
Status: Approved (verbal, 2026-05-06)

## Goal

Land the framework code required for menubar/system-tray widgets on macOS and Windows, and home-screen widgets on Android and iOS, without exposing any user-visible surface yet. The intent is that future design work can plug in widget UI quickly without touching the bridge plumbing.

Out of scope: any actual widget UI, any setting that lets users enable a widget, any deep-linking from widget actions, any production-grade quick-note creation flow.

## Architecture

```
Flutter (lib/widget_bridge/)
  WidgetState (DTO) ── JSON ──> shared storage per platform
  WidgetBridge (subscribes to PriorityBloc/UserBloc) ── MethodChannel('day.plot/widgets') ──> native plugin
                                                                                     │
                                                                                     ▼
                                                               iOS/macOS:   WidgetCenter.reloadAllTimelines()
                                                               Android:     AppWidgetManager.updateAppWidget()
                                                               Windows:     tray icon repaint
```

Native widgets read shared storage on refresh; they never call back into Flutter to fetch data. The method channel exists only to (a) signal "state changed, reload your timelines" from Flutter and (b) accept future "user tapped X" actions from native back into Flutter.

### Flutter (`apps/plot/lib/widget_bridge/`)

- `widget_data.dart` — `WidgetState` immutable DTO with: `userId`, `isSignedIn`, `currentPriorityId`, `currentPriorityTitle`. JSON serializable. Equatable.
- `widget_bridge.dart` — Service started from `app.dart`. Subscribes to `PriorityBloc` and `UserBloc`. Debounces (500ms). On change, calls `WidgetBridgeChannel.writeState` then `reloadAll`.
- `widget_bridge_channel.dart` — `MethodChannel('day.plot/widgets')`. Outbound: `writeState(Map)`, `reloadAll()`. Inbound stub: `onWidgetAction(String name, Map args)` — no-op handler logged at info level. This is the future hook for "create quick note" etc.
- Platform support gate: only attaches the channel on `Platform.isIOS || isMacOS || isAndroid || isWindows`. Other platforms (web, linux) are silent no-ops.

No new bloc; no new state files. The bridge is a side-effect listener.

### iOS (`apps/plot/ios/`)

- New target `PlotWidget` (WidgetKit extension), added via `apps/plot/scripts/add_widget_targets.rb` (idempotent; uses the `xcodeproj` Ruby gem):
  - `PlotWidget/PlotWidgetBundle.swift` — `@main` `WidgetBundle` containing one private `PlotPlaceholderWidget` with a static `Text("Plot")` view. WidgetKit requires at least one widget per bundle for the extension to compile, so a minimal placeholder is the smallest scaffold that builds. The placeholder is not embedded into the host app today (see below), so it does not surface to end users.
  - `PlotWidget/Info.plist`, `PlotWidget/PlotWidget.entitlements` (App Group `group.day.plot.app`).
- `Runner/Runner.entitlements` already includes `group.day.plot.app` (added previously for the share extension); the same group is reused for widgets so we don't have to provision an extra one.
- `Runner/WidgetBridge/WidgetBridgePlugin.swift` — registers the method channel from `AppDelegate.didInitializeImplicitFlutterEngine`. Implements `writeState` (writes JSON to shared `UserDefaults(suiteName: "group.day.plot.app")`) and `reloadAll` (`WidgetCenter.shared.reloadAllTimelines()`).
- `Runner/WidgetBridge/PlotWidgetSharedStorage.swift` — read helpers shared between Runner and PlotWidget targets via Xcode project membership.
- `Podfile` left untouched (extension uses no pods).

Signing for the new bundle ID `day.plot.app.PlotWidget` is set to ad-hoc (`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGNING_ALLOWED = NO`) so the target compiles without provisioning. The extension is intentionally **not embedded** into the Runner build today — embedding requires the bundle ID to be provisioned, which would force every developer / CI to do extra setup. Re-enable embedding (uncomment the body of `embed_extension_into_runner` in `add_widget_targets.rb`) once a real widget is shipping and the bundle ID is provisioned in the Apple Developer portal.

### macOS (`apps/plot/macos/`)

Same WidgetKit pattern as iOS, also added by `add_widget_targets.rb`:
- Target `PlotWidget` with the same single `PlotPlaceholderWidget`, `Info.plist`, entitlement file with App Group `group.day.plot.app`.
- `Runner/DebugProfile.entitlements` and `Runner/Release.entitlements` updated to include the App Group (macOS Runner did not have one before).
- `Runner/WidgetBridge/WidgetBridgePlugin.swift`, `Runner/WidgetBridge/PlotWidgetSharedStorage.swift` (shared with the extension via Xcode project membership).
- Same ad-hoc signing + non-embedded posture as iOS.

Plus status item scaffolding:
- `Runner/MenuBar/MenuBarController.swift` — owns an `NSStatusItem`. Reads the `statusItemEnabled` flag from shared `UserDefaults` and only adds the icon when true. Default false.
- `MainFlutterWindow.swift` — creates the controller after the Flutter view is set up, then constructs `WidgetBridgePlugin` and hands the controller to it so `reloadAll` can re-evaluate the enable flag. No menu items on the controller today.

### Android (`apps/plot/android/`)

- `app/src/main/kotlin/day/plot/app/widgets/PlotAppWidgetProvider.kt` — minimal `AppWidgetProvider` with stub `onUpdate` that reads JSON from `SharedPreferences("day.plot.widgets", MODE_PRIVATE)` and inflates the placeholder layout. Logs only.
- `app/src/main/res/xml/plot_app_widget_info.xml` — minimum required `appwidget-provider` (sizes, update period, no preview).
- `app/src/main/res/layout/plot_app_widget.xml` — single empty `FrameLayout`. Will be replaced when real widget UI is designed.
- `app/src/main/AndroidManifest.xml` — declare the receiver with `android:enabled="false"` so it does not appear in the widget picker. The `<intent-filter>` and `meta-data` are still present so it can be flipped on with one attribute change later.
- `app/src/main/kotlin/day/plot/app/widgets/WidgetBridgePlugin.kt` — `MethodChannel.MethodCallHandler` registered from `MainActivity.kt`. Implements `writeState` (writes to `SharedPreferences`) and `reloadAll` (calls `AppWidgetManager.getInstance(context).notifyAppWidgetViewDataChanged(...)` for any active provider IDs; no-op when none).

### Windows (`apps/plot/windows/runner/`)

- `system_tray/tray_icon.h` and `system_tray/tray_icon.cpp` — RAII wrapper around `Shell_NotifyIconW`. Constructor parameter `enable`; if false, performs no Win32 calls. Default false.
- `flutter_window.cpp` — instantiate the tray after the Flutter view is created, reading the enable flag from `%APPDATA%\Plot\widget-flags.json` (default false; missing file → false).
- `CMakeLists.txt` updated to add the new sources to the runner target.
- `WidgetBridgePlugin` (C++) — registers the method channel via the Flutter engine's plugin registrar, persists state to `%APPDATA%\Plot\widget-state.json`, repaints the tray on `reloadAll`.

### Data flow

1. `PriorityBloc` or `UserBloc` emits.
2. `WidgetBridge` builds a fresh `WidgetState` and `jsonEncode`s it.
3. `WidgetBridgeChannel.writeState({json})` over MethodChannel.
4. Native plugin writes to platform shared storage (UserDefaults / SharedPreferences / file).
5. `WidgetBridgeChannel.reloadAll()` triggers platform-specific reload.
6. Native widget (when registered later) reads shared storage during its refresh.

Action flow (future-proofing only — not exercised today):
1. Native widget invokes `channel.invokeMethod("onWidgetAction", { "name": "createNote", "args": {...} })`.
2. Flutter handler logs and returns null. To be replaced when designs land.

## Verification

- `flutter analyze` clean.
- `flutter build macos --debug`, `flutter build ios --no-codesign --debug --simulator`, `flutter build apk --debug` succeed.
- macOS and iOS PlotWidget targets build standalone via `xcodebuild -target PlotWidget`.
- Windows build was not exercised on macOS host; CMake additions and source files were validated by inspection only.
- The PlotWidget extensions are not embedded into the Runner host today, so iOS and macOS users see no new entries in their widget galleries. Android receiver is `android:enabled="false"`. macOS status item / Windows tray gates default off.
- No user-visible diff in the running app (no menu items, no extra UI).

## Decisions Locked In

- "Menubar widget" on desktop = system tray / status item only, not native app menu items.
- Bridge approach = shared storage + method channel (Flutter pushes; widgets pull from local store).
- Build scope = native targets compile and ship; nothing registered to the user.

## Non-goals

- Designing the widget UI.
- Designing the menu/popover.
- Wiring up "quick note" or any other user action.
- Background data refresh (e.g. iOS background tasks, Android `WorkManager`).
- Localization of widget content (no content yet).
- Auth refresh from inside widgets (they will read whatever the app last wrote).
