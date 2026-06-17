# Windows Store screenshots — Mac-only capture via platform emulation

**Date:** 2026-06-16
**Status:** Design (approved approach, pending spec review)

## Problem

The store-screenshot framework (`apps/plot/screenshots/`) generates App Store and
Play screenshots for iPhone, iPad, macOS, and Android, but not for the Microsoft
Store (Windows). The Windows app is published to the MS Store (product
`9PKTCSN8SNZF`), but `msstore publish` uploads the build only — listing
screenshots are managed by hand in Partner Center and currently have no
generated source.

We want to generate Windows store screenshots **entirely on the Mac**, with no
UTM VM or Visual Studio toolchain, and have them be visually faithful to a real
Windows render.

## Key insight: the app is identical on Windows except window chrome

The app's interior renders pixel-identically across macOS and Windows:

- The UI font is pinned to **Figtree** (`lib/style/typography.dart:33`,
  via forui `typography`), and color emoji is bundled (NotoColorEmoji) "so
  reactions render identically on every OS". Nothing user-visible falls back to
  an OS default font.

The **only** platform differences are:

1. **Window chrome.** macOS shows native traffic-light buttons (top-left,
   OS-drawn, header content inset on the left). Windows draws its **own**
   caption buttons via Flutter — `_WindowControls` (minimize/maximize/close,
   top-right) rendered **only** in the `windowsBuilder` branch of the `Window`
   widget (`lib/widget/window.dart:429`), with the header inset on the right
   (138px). The caption buttons are `window_manager`'s `WindowCaptionButton`,
   which paints Fluent-style glyphs in pure Flutter on any host OS.
2. **The OS-drawn window frame** (rounded corners, 1px border, drop shadow),
   drawn by the Windows DWM. This is the only element we can't render from the
   app; we synthesize it in compose.

### The clean seam: two `Platform` types

The codebase uses two distinct platform abstractions, and they split exactly
along the line we need:

- **In-app chrome** is gated on `platform_builder`'s `Platform.instance.*`:
  the `windowsBuilder` branch (`window.dart`), the header selection
  (`scaffold.dart:85`), and the `DragToMoveArea` wraps
  (`header.dart:368`, `unified_header.dart:471`).
- **Native/host code** is gated on `dart:io`'s bare `Platform.isWindows` /
  `isMacOS`: window setup in `main.dart`, notifications, the `auth_button`
  loopback, `window_title`, `tracker`.

`platform_builder` supports a first-class override:
`Platform.init(override: Platforms.windows)` makes `Platform.instance.current`
report Windows everywhere (a simple field check at
`platform_builder/platform.dart:119`). Crucially it affects **only**
`Platform.instance.*`, **not** `dart:io`'s `Platform.*`. So the override flips
exactly the rendered chrome to Windows while every real native call keeps
running as macOS — no Windows-only plugin can fire on the Mac and break startup.

## Approach

Add a screenshot-only "emulate Windows" mode to the macOS build. A macOS capture
in this mode is an authentic Windows render of the app content; compose adds the
Windows frame. This reuses the existing capture/compose pipeline almost verbatim.

## Components

### 1. App: Windows-emulation mode (Dart)

- A new dart-entrypoint flag, `--emulate-windows`, honored **only** in
  debug/screenshot mode (alongside the existing `--scene` plumbing).
- In bootstrap, **before** the app builds and before `Window.init()`, call
  `Platform.init(override: Platforms.windows)` when the flag is set. The app
  then renders the Windows `windowsBuilder` (Flutter-drawn caption cluster
  top-right, Windows header inset).
- **Hide the real macOS traffic lights.** With the override active,
  `Window.init()` takes its Windows branch
  (`window.dart:108`), which calls
  `windowManager.setTitleBarStyle(TitleBarStyle.hidden, …)`. In emulation mode
  pass `windowButtonVisibility: false` so the native macOS traffic lights are
  suppressed. (Detection of the real host uses `dart:io` `Platform.isMacOS` or
  `Platform.instance.currentHost`, which the `override` does not affect.)
- Net result on the Mac: a frameless window painting the app's own
  `frameBackgroundGradient` plus the Windows caption buttons — no macOS chrome.

The scene already pins the window to 1440×900 (`scenes.dart:83`); unchanged.

### 2. `launch-args.ts`

For platform `windows`, append `--emulate-windows` to the dart args (the
existing `dartArgs()` already sets `--profile=screenshots-windows`,
`--scene`, mode, frozen time, user).

### 3. `manifest.ts` — a `windows` PlatformPlan

- `platform: 'windows'`, new `store: 'ms-store'` (output dir
  `store/ms-store/windows/`, parallel to `store/app-store/…` and
  `store/play/…`).
- `captureDevice: 'macos'` (it is a macOS capture).
- `resolution: [2880, 1800]` — the capturable ceiling, matching the macOS/iPad
  plans. A 1440×900 scene window captured at 2× on a Retina display yields
  2880×1800; used 1:1 with no upscaling. (MS Store desktop accepts 1366×768–4K,
  but true 4K isn't crisply producible here: the built-in Retina can't fit a
  window wider than ~1512pt, and a 1× external display would only yield
  1440×900. **Revised from an initial [3840, 2160]** once the capture path was
  validated — a 2880-wide source upscaled into a 4K canvas would only soften it.)
- `framing: 'multipanel-windows'` (see compose) for each slot.
- Slots mirror the macOS plan's five scenes/headlines (S1, S2, S11, S7, S8).
  Captions are compose-only and trivially re-editable later.

### 4. `compose/` — a Windows 11 frame

- Add a `multipanel-windows` framing (a thin variant of `multipanelFlat`, or a
  `frameStyle` parameter). Difference from the macOS/iPad flat frame: render the
  captured window with a **Windows 11 frame** — ~8–10px corner radius (scaled to
  canvas), a subtle 1px border (light: `rgba(0,0,0,.12)`; dark mode lighter),
  and a soft drop shadow. The capture already carries macOS's transparent
  rounded corners (~10px), which read as Windows 11 corners, so the radius is
  chosen ≥ that to avoid a gradient sliver.
- Add `windows` to the `SCREEN` map in `compose.ts` (`{ w: 1440, h: 900 }`).
- Wire the `windows` platform / `multipanel-windows` framing through
  `composePlatform()`.

### 5. `capture/windows.sh`

Effectively `capture/macos.sh`: launches `flutter run -d macos` with the dart
args (now including `--emulate-windows`), waits for `SCENE_READY:<scene>`, and
captures the pinned 1440×900 Plot window by CGWindowID with
`screencapture -x -o -l`. The capture mechanics are identical because it is a
macOS window. (Implementation may parametrize `macos.sh` rather than fork it.)

### 6. `orchestrate.ts`

Register `'windows' → capture/windows.sh` in the `CAPTURE` map so
`npx tsx orchestrate.ts windows` runs seed → capture → compose for Windows.

## Data flow

```
orchestrate.ts windows
  → seed margot data
  → for each (scene, mode): capture/windows.sh
        flutter run -d macos --dart-entrypoint-args=--emulate-windows --scene=…
        → Platform.init(override: windows) → app renders Windows chrome
        → SCENE_READY → screencapture → raw/windows/<scene>-<mode>.png
  → composePlatform(windows)
        multipanel-windows template (Win11 frame) → Playwright
        → store/ms-store/windows/<NN>-<scene>.png
```

Final PNGs are uploaded by hand to Partner Center (consistent with
`docs/windows-store-publishing.md`: the pipeline uploads builds only).

## Error handling

- Capture failures surface the same way as `macos.sh` today (early
  `flutter run` exit → tail log + non-zero exit; `SCENE_READY` timeout → tail
  log + exit; no matching 1440×900 window → exit). No new failure modes.
- The `--emulate-windows` flag is strictly gated to debug/screenshot mode so a
  release build can never override the platform.

## Testing / verification

- `compose/geometry` unit tests unaffected; if the Windows frame introduces any
  computed geometry, add a focused unit test mirroring `geometry.test.ts`.
- Manual verification: run `npx tsx orchestrate.ts windows`, then eyeball
  `store/ms-store/windows/*.png` — confirm (a) Windows caption buttons appear
  top-right, (b) no macOS traffic lights, (c) Figtree text, (d) the Windows 11
  frame (corners/border/shadow) reads correctly in both light and dark slots.
- `flutter analyze` clean for the Dart changes; `npx tsc`/lint clean for the TS.

## Out of scope / non-goals

- No UTM/VM capture, no Visual Studio toolchain.
- No automated upload to Partner Center (manual, as today).
- No changes to the other platforms' plans.

## Risks & mitigations

- **A Windows-gated `Platform.instance.*` branch makes a call that misbehaves on
  the macOS host.** Audited: the only `Platform.instance.isWindows` branches are
  the chrome ones above; the `Window.init` Windows branch calls
  `window_manager.setTitleBarStyle`, which is supported on macOS. Native plugin
  calls are all behind `dart:io` `Platform.*`, untouched by the override.
- **Corner-radius mismatch** (macOS ~10px vs Windows 8px): negligible at store
  scale; compose radius chosen ≥ the captured corner so no gradient sliver
  shows.
- **Font fidelity:** none — Figtree is bundled and pinned app-wide.
```
