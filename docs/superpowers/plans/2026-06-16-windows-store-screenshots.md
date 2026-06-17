# Windows Store Screenshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate Microsoft Store (Windows desktop) screenshots entirely on macOS by rendering the app's Windows chrome on a macOS capture, then synthesizing the Windows 11 window frame in compose.

**Architecture:** A screenshot-only `--emulate-windows` flag calls `platform_builder`'s `Platform.init(override: Platforms.windows)` before the app builds. This flips only the in-app chrome (`windowsBuilder`, header insets, Flutter-drawn caption buttons) to Windows while every `dart:io`-gated native/host call stays macOS — so nothing Windows-only fires on the Mac. The native macOS traffic lights are hidden, the existing macOS capture script grabs the 1440×900 window, and a new `multipanel-windows` compose template wraps it with a Windows 11 frame. Output lands in `store/ms-store/windows/` for manual upload to Partner Center.

**Tech Stack:** Flutter/Dart (app), `platform_builder` package, TypeScript + `tsx` + Playwright (compose), bash + `screencapture` (capture), `node:test` (TS tests), `flutter_test` (Dart tests).

## Global Constraints

- **Resolution:** `[3840, 2160]` (4K, 16:9). MS Store desktop guidance: PNG, landscape, 1366×768 minimum, "Supports 4K images (3840 × 2160)."
- **Captions (locked):** mirror the five macOS headlines exactly — S1 "All your work, ready for action", S2 "Reply to anything without opening another app", S11 "Drive it from the keyboard", S7 (dark) "AI alongside your work — or off entirely", S8 "Works with the tools you already use".
- **Emulation is debug-only:** the platform override must be gated on `kDebugMode && CliArgs.emulateWindows` — a release build can never override the platform.
- **Capture window size:** the scene pins the window to 1440×900 (`scenes.dart:83`); on a Retina Mac this captures at 2× = 2880×1800 px. Do not change it.
- **No native/host behavior change on real Windows:** the override touches only `platform_builder`'s `Platform.instance.*`; leave all `dart:io` `Platform.*` branches alone.
- **Output dir:** `apps/plot/screenshots/store/ms-store/windows/` (parallel to `store/app-store/…`, `store/play/…`).
- **UI text:** sentence case (already satisfied by the locked captions).

All paths below are relative to the repo root `/Users/kris.braun/code/plot` unless absolute.

---

### Task 1: `--emulate-windows` CLI flag (Dart)

Add a parsed, debug-only flag the bootstrap and capture pipeline key off.

**Files:**
- Modify: `apps/plot/lib/cli_args.dart`
- Test: `apps/plot/test/screenshot/scenes_test.dart`

**Interfaces:**
- Produces: `CliArgs.emulateWindows` → `bool` (static getter); flag string `--emulate-windows`.

- [ ] **Step 1: Write the failing tests**

Add these two tests inside `main()` in `apps/plot/test/screenshot/scenes_test.dart` (after the existing `--scene` tests):

```dart
  test('parses --emulate-windows', () {
    CliArgs.resetForTest();
    CliArgs.init(['--emulate-windows']);
    expect(CliArgs.emulateWindows, isTrue);
  });

  test('emulateWindows defaults to false', () {
    CliArgs.resetForTest();
    CliArgs.init(['--scene=S1']);
    expect(CliArgs.emulateWindows, isFalse);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apps/plot && flutter test test/screenshot/scenes_test.dart`
Expected: FAIL — `CliArgs.emulateWindows` is undefined (compile error).

- [ ] **Step 3: Implement the flag in `cli_args.dart`**

Add the field next to the other static fields (after `static String? _scene;` at line 35):

```dart
  static bool _emulateWindows = false;
```

Add the parse branch inside the `for (final arg in args)` loop, after the `--scene=` branch (line 92-95):

```dart
      } else if (arg == '--emulate-windows') {
        _emulateWindows = true;
        _log.info('--emulate-windows: rendering Windows chrome');
```

Add the getter (after the `scene` getter, ~line 176):

```dart
  /// Returns true if --emulate-windows was specified (screenshot-only:
  /// renders the app's Windows chrome on a macOS capture).
  static bool get emulateWindows => _emulateWindows;
```

Reset it in `resetForTest()` — change the existing reset line (line 182) to include the new field:

```dart
    _darkMode = _lightMode = _noProfile = _enableDriverExtension =
        _emulateWindows = false;
```

Add a line to the class doc comment (after the `--enable-driver-extension` bullet, line 19):

```dart
/// - --emulate-windows: Render the app's Windows window chrome (caption
///   buttons, header insets) on a macOS build. Screenshot/debug only.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd apps/plot && flutter test test/screenshot/scenes_test.dart`
Expected: PASS (all tests, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/cli_args.dart apps/plot/test/screenshot/scenes_test.dart
git commit -m "feat(screenshots): add --emulate-windows CLI flag"
```

---

### Task 2: Render Windows chrome on a macOS screenshot build (Dart)

Apply the platform override in the bootstrap and hide the native macOS traffic lights so the Windows `windowsBuilder` chrome is what gets captured.

**Files:**
- Modify: `apps/plot/lib/main.dart` (add import; insert override after `CliArgs.init(args)` at line 96)
- Modify: `apps/plot/lib/widget/window.dart` (Windows branch of `Window.init`, lines 108-115)

**Interfaces:**
- Consumes: `CliArgs.emulateWindows` (Task 1); `platform_builder`'s `Platform.init`, `Platforms`, `Platform.instance.currentHost`.
- Produces: no new symbols; behavioral — when `--emulate-windows` is set on a macOS debug build, `Platform.instance.current == Platforms.windows` and the native traffic lights are hidden.

- [ ] **Step 1: Add the prefixed import to `main.dart`**

`main.dart` already imports `dart:io` unprefixed (line 2), so its bare `Platform` is `dart:io`'s. Import `platform_builder` with a prefix to avoid the clash. Add near the other package imports (e.g. after line 2):

```dart
import 'package:platform_builder/platform_builder.dart' as pb;
```

- [ ] **Step 2: Insert the override right after `CliArgs.init(args)`**

In `apps/plot/lib/main.dart`, immediately after line 96 (`CliArgs.init(args);`) and before the driver-extension block, insert:

```dart
  // Screenshot-only: render the app's Windows chrome on a macOS capture by
  // overriding the reported platform. This affects ONLY platform_builder's
  // Platform.instance.* (the in-app chrome — windowsBuilder, header insets,
  // Flutter-drawn caption buttons). dart:io Platform.* — and thus every
  // native/host call — stays macOS, so no Windows-only plugin fires here.
  // Must run before any Platform.instance access and before Window.init().
  if (kDebugMode && CliArgs.emulateWindows) {
    pb.Platform.init(override: pb.Platforms.windows);
  }
```

(`kDebugMode` is already imported via `package:flutter/foundation.dart` in this file — it is used at line 97 and 144.)

- [ ] **Step 3: Hide the native macOS traffic lights in the Windows branch of `Window.init`**

In `apps/plot/lib/widget/window.dart`, replace the Windows branch (lines 108-115):

```dart
    } else if (Platform.instance.isWindows) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: true,
      );
      toolbarHeight = 32.0;
      // ~138px for 3 native buttons (46px each)
      toolbarPadding = const EdgeInsets.only(right: 138);
    } else {
```

with:

```dart
    } else if (Platform.instance.isWindows) {
      // When emulating Windows on a macOS host (screenshot mode), the host is
      // still macOS, so hide the native traffic lights — only the Flutter-drawn
      // caption buttons (_WindowControls, top-right) should appear. On real
      // Windows currentHost is windows, so the buttons stay visible (unchanged).
      final emulatedOnMac = Platform.instance.currentHost == Platforms.macOS;
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: !emulatedOnMac,
      );
      toolbarHeight = 32.0;
      // ~138px for 3 native buttons (46px each)
      toolbarPadding = const EdgeInsets.only(right: 138);
    } else {
```

(`Platforms` is already in scope — `window.dart:11` imports `package:platform_builder/platform_builder.dart` unprefixed, which exports `Platforms` and the `currentHost` getter.)

- [ ] **Step 4: Verify it compiles cleanly**

Run: `cd apps/plot && flutter analyze lib/main.dart lib/widget/window.dart lib/cli_args.dart`
Expected: "No issues found!" (no new analyzer errors).

> Visual confirmation (caption buttons top-right, no traffic lights, Figtree text) happens end-to-end in **Task 6**, once the capture pipeline is wired. There is no isolated unit test for this native window behavior.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/main.dart apps/plot/lib/widget/window.dart
git commit -m "feat(screenshots): emulate Windows chrome on macOS in screenshot mode"
```

---

### Task 3: Windows compose machinery — types, template, wiring (TypeScript)

Extend the plan type unions and add the Windows 11 frame template plus the compose branch. This task adds the machinery but no plan yet, so nothing renders for Windows until Task 4.

**Files:**
- Modify: `apps/plot/screenshots/manifest.ts` (the `Framing`, `platform`, and `store` type unions only)
- Modify: `apps/plot/screenshots/compose/templates.ts` (add `multipanelWindows`)
- Modify: `apps/plot/screenshots/compose/compose.ts` (`SCREEN` map + framing branch + import)
- Test: `apps/plot/screenshots/compose/templates.test.ts` (new)

**Interfaces:**
- Produces: `multipanelWindows(o: { src: string; w: number; h: number; headline: string }): string`; `Framing` now includes `'multipanel-windows'`; `PlatformPlan.platform` includes `'windows'`; `PlatformPlan.store` includes `'ms-store'`.
- Consumes: `gradient()`, `FONT`, `BRAND` (existing in `templates.ts`).

- [ ] **Step 1: Write the failing test**

Create `apps/plot/screenshots/compose/templates.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { multipanelWindows } from './templates.ts';

test('multipanelWindows renders the headline inside a Windows-style framed image', () => {
  const html = multipanelWindows({
    src: 'data:image/png;base64,AAAA',
    w: 3840,
    h: 2160,
    headline: 'Drive it from the keyboard',
  });
  assert.match(html, /Drive it from the keyboard/);
  assert.match(html, /border-radius:\d+px/);    // Windows 11 rounded corners
  assert.match(html, /border:1px solid/);        // subtle window border
  assert.match(html, /box-shadow:/);             // drop shadow
  assert.match(html, /data:image\/png;base64,AAAA/);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot/screenshots && npx tsx --test compose/templates.test.ts`
Expected: FAIL — `multipanelWindows` is not exported from `./templates.ts`.

- [ ] **Step 3: Add the `multipanelWindows` template**

In `apps/plot/screenshots/compose/templates.ts`, append after `multipanelFlat` (end of file):

```ts
/** Flat multi-panel with a synthesized Windows 11 window frame: a subtle 1px
 *  border, rounded corners, and a soft drop shadow. Used for Microsoft Store
 *  desktop screenshots captured on macOS in Windows-emulation mode. Mirrors
 *  multipanelFlat's caption band + fit-to-area layout; only the image frame
 *  differs. The radius/border are tunable — calibrated to read as Windows 11
 *  at store scale. */
export function multipanelWindows(o: {
  src: string; w: number; h: number; headline: string;
}): string {
  const bandH = Math.round(o.h * 0.105);
  const pad = Math.round(o.h * 0.03);
  const radius = Math.round(o.w * 0.005); // ~19px @ 3840w — Windows 11 corner
  return `<!doctype html><html><body style="margin:0">
    <div style="width:${o.w}px;height:${o.h}px;background:${gradient(120)};
      box-sizing:border-box;display:flex;flex-direction:column;
      align-items:center">
      <div style="flex:0 0 ${bandH}px;display:flex;align-items:center;
        font-family:${FONT};color:#fff;font-weight:700;
        font-size:${Math.round(o.w * 0.024)}px">${o.headline}</div>
      <div style="flex:1 1 auto;min-height:0;width:100%;display:flex;
        align-items:flex-start;justify-content:center;padding:0 0 ${pad}px">
        <img src="${o.src}" style="max-width:95%;max-height:100%;
          border-radius:${radius}px;border:1px solid rgba(255,255,255,.10);
          box-shadow:0 30px 90px rgba(0,0,0,.45)"/>
      </div>
    </div></body></html>`;
}
```

- [ ] **Step 4: Extend the type unions in `manifest.ts`**

In `apps/plot/screenshots/manifest.ts`, change the `Framing` type (line 2):

```ts
export type Framing = 'phone' | 'phone-hero-span' | 'multipanel-flat' | 'multipanel-windows';
```

Change `PlatformPlan.platform` (line 13) and `store` (line 14):

```ts
  platform: 'iphone-6.9' | 'ipad-13' | 'macos' | 'android-phone' | 'android-tablet' | 'windows';
  store: 'app-store' | 'play' | 'ms-store';
```

- [ ] **Step 5: Wire `compose.ts` — import, SCREEN entry, framing branch**

In `apps/plot/screenshots/compose/compose.ts`:

Add `multipanelWindows` to the templates import (line 6):

```ts
import { phoneSlot, heroSpan, multipanelFlat, multipanelWindows } from './templates.ts';
```

Add a `windows` entry to the `SCREEN` map (inside the `const SCREEN = { … } as const;` block, ~line 35-41) — keeps `SCREEN[p.platform]` type-safe for the new platform:

```ts
  'windows': { w: 1440, h: 900 },          // macOS capture window (emulated)
```

Replace the final `else` (multipanel-flat) branch (lines 66-70) with an explicit Windows branch before it:

```ts
    } else if (slot.framing === 'multipanel-windows') {
      const html = multipanelWindows({ src, w: W, h: H, headline: slot.headline });
      const png = await renderPng(html, W, H);
      await save(`${dir}/${String(slot.slots[0]).padStart(2, '0')}-${slot.scene}.png`, png);
    } else { // multipanel-flat
      const html = multipanelFlat({ src, w: W, h: H, headline: slot.headline });
      const png = await renderPng(html, W, H);
      await save(`${dir}/${String(slot.slots[0]).padStart(2, '0')}-${slot.scene}.png`, png);
    }
```

- [ ] **Step 6: Run the template test**

Run: `cd apps/plot/screenshots && npx tsx --test compose/templates.test.ts`
Expected: template test PASS (`# pass 1`, `# fail 0`).

> Note: this package is verified with `tsx` (type-stripping), not `tsc` — there is no `tsc` gate here (`@types/node` isn't resolvable from this dir's tsconfig, and the package is run/tested entirely through `tsx`). The unit tests import `templates.ts`/`manifest.ts` directly, so a broken import or reference surfaces at runtime; the end-to-end `tsx` run in Task 6 is the final wiring check. Do not add a `tsc` step.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/screenshots/manifest.ts apps/plot/screenshots/compose/templates.ts apps/plot/screenshots/compose/compose.ts apps/plot/screenshots/compose/templates.test.ts
git commit -m "feat(screenshots): add multipanel-windows compose template + types"
```

---

### Task 4: Add the Windows PlatformPlan (TypeScript)

Register the five-slot Windows plan so `composePlatform` and `orchestrate` produce Windows output.

**Files:**
- Modify: `apps/plot/screenshots/manifest.ts` (append to the `PLANS` array)
- Test: `apps/plot/screenshots/manifest.test.ts` (new)

**Interfaces:**
- Consumes: `Framing`/`platform`/`store` unions (Task 3), `PlatformPlan`, `capturesFor`.
- Produces: a `PlatformPlan` with `platform: 'windows'` in `PLANS`.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/screenshots/manifest.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PLANS, capturesFor } from './manifest.ts';

test('windows plan targets MS Store at 4K with multipanel-windows framing', () => {
  const win = PLANS.find((p) => p.platform === 'windows');
  assert.ok(win, 'windows plan exists');
  assert.equal(win!.store, 'ms-store');
  assert.equal(win!.captureDevice, 'macos');
  assert.deepEqual(win!.resolution, [3840, 2160]);
  assert.ok(
    win!.slots.every((s) => s.framing === 'multipanel-windows'),
    'every slot uses multipanel-windows framing',
  );
});

test('windows plan captures five distinct scenes', () => {
  const win = PLANS.find((p) => p.platform === 'windows')!;
  assert.equal(capturesFor(win).length, 5);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot/screenshots && npx tsx --test manifest.test.ts`
Expected: FAIL — no `windows` plan in `PLANS` (`assert.ok(win)` throws).

- [ ] **Step 3: Append the Windows plan to `PLANS`**

In `apps/plot/screenshots/manifest.ts`, add this object as the last element of the `PLANS` array (after the `android-tablet` plan, before the closing `];` at line 107). Captions are the locked Global Constraint set and mirror the macOS plan:

```ts
  {
    platform: 'windows', store: 'ms-store',
    captureDevice: 'macos', resolution: [3840, 2160],
    slots: [
      { slots: [1], scene: 'S1', mode: 'light', framing: 'multipanel-windows',
        headline: 'All your work, ready for action' },
      { slots: [2], scene: 'S2', mode: 'light', framing: 'multipanel-windows',
        headline: 'Reply to anything without opening another app' },
      { slots: [3], scene: 'S11', mode: 'light', framing: 'multipanel-windows',
        headline: 'Drive it from the keyboard' },
      { slots: [4], scene: 'S7', mode: 'dark', framing: 'multipanel-windows',
        headline: 'AI alongside your work — or off entirely' },
      { slots: [5], scene: 'S8', mode: 'light', framing: 'multipanel-windows',
        headline: 'Works with the tools you already use' },
    ],
  },
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot/screenshots && npx tsx --test manifest.test.ts`
Expected: both tests PASS (`# pass 2`, `# fail 0`).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/screenshots/manifest.ts apps/plot/screenshots/manifest.test.ts
git commit -m "feat(screenshots): add Windows MS Store plan (4K, 5 scenes)"
```

---

### Task 5: Capture wiring — launch args, capture script, orchestrate (TypeScript + bash)

Make the capture pipeline launch the emulation build and reuse the macOS capture script for the `windows` platform.

**Files:**
- Modify: `apps/plot/screenshots/launch-args.ts` (append `--emulate-windows` for `windows`)
- Modify: `apps/plot/screenshots/capture/macos.sh` (derive the kill-pattern profile from args, so the same script serves macOS and Windows)
- Modify: `apps/plot/screenshots/orchestrate.ts` (register `windows` in the `CAPTURE` map)

**Interfaces:**
- Consumes: `dartArgs` is called by `orchestrate.ts`; the `windows` plan (Task 4).
- Produces: `npx tsx orchestrate.ts windows` runs seed → capture (`capture/macos.sh` with `--emulate-windows`) → compose for Windows.

- [ ] **Step 1: Write the failing test for `dartArgs`**

Create `apps/plot/screenshots/launch-args.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dartArgs } from './launch-args.ts';

test('windows platform gets --emulate-windows', () => {
  const args = dartArgs('S1', 'light', 'windows');
  assert.ok(args.includes('--emulate-windows'));
  assert.ok(args.includes('--profile=screenshots-windows'));
  assert.ok(args.includes('--scene=S1'));
});

test('non-windows platforms do not get --emulate-windows', () => {
  assert.ok(!dartArgs('S1', 'light', 'macos').includes('--emulate-windows'));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot/screenshots && npx tsx --test launch-args.test.ts`
Expected: FAIL — current `dartArgs` never emits `--emulate-windows`.

- [ ] **Step 3: Append `--emulate-windows` for the windows platform in `launch-args.ts`**

In `apps/plot/screenshots/launch-args.ts`, replace the `return [...]` in `dartArgs` (lines 8-15) with:

```ts
  return [
    `--user=${USER}`,
    `--password=${USER}`,
    `--frozen-time=${FROZEN}`,
    mode === 'dark' ? '--dark-mode' : '--light-mode',
    `--profile=screenshots-${platform}`,
    ...(platform === 'windows' ? ['--emulate-windows'] : []),
    `--scene=${scene}`,
  ];
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot/screenshots && npx tsx --test launch-args.test.ts`
Expected: both tests PASS (`# pass 2`, `# fail 0`).

- [ ] **Step 5: Generalize the cleanup pattern in `macos.sh`**

In `apps/plot/screenshots/capture/macos.sh`, after `DART_ARGS=("$@")` (line 24) add a line that extracts the profile from the args:

```bash
PROFILE="$(printf '%s\n' "${DART_ARGS[@]}" | sed -n 's/^--profile=//p' | head -1)"
```

Then replace the hard-coded cleanup line (line 36):

```bash
cleanup() { kill "$RUN_PID" 2>/dev/null || true; pkill -f "profile=screenshots-macos" 2>/dev/null || true; }
```

with:

```bash
cleanup() { kill "$RUN_PID" 2>/dev/null || true; [ -n "$PROFILE" ] && pkill -f "profile=$PROFILE" 2>/dev/null || true; }
```

This is behavior-preserving for macOS (`PROFILE` resolves to `screenshots-macos`) and correct for Windows (`screenshots-windows`). The window finder is unchanged — the emulated window is still pinned to 1440×900.

- [ ] **Step 6: Register `windows` in the orchestrate CAPTURE map**

In `apps/plot/screenshots/orchestrate.ts`, replace the `CAPTURE` map (lines 6-9):

```ts
const CAPTURE: Record<string, string> = {
  'iphone-6.9': new URL('./capture/ios.sh', import.meta.url).pathname,
  'macos': new URL('./capture/macos.sh', import.meta.url).pathname,
};
```

with (Windows emulates on macOS, so it reuses `macos.sh`):

```ts
const CAPTURE: Record<string, string> = {
  'iphone-6.9': new URL('./capture/ios.sh', import.meta.url).pathname,
  'macos': new URL('./capture/macos.sh', import.meta.url).pathname,
  'windows': new URL('./capture/macos.sh', import.meta.url).pathname,
};
```

- [ ] **Step 7: Shell sanity**

Run: `cd apps/plot/screenshots && bash -n capture/macos.sh && echo "macos.sh OK"`
Expected: no syntax errors; prints `macos.sh OK`. (The `macos.sh` and `orchestrate.ts` edits aren't unit-testable; they're exercised end-to-end in Task 6, where the capture invocation passes `--emulate-windows` and the Windows chrome appearing confirms the full arg path.)

- [ ] **Step 8: Commit**

```bash
git add apps/plot/screenshots/launch-args.ts apps/plot/screenshots/launch-args.test.ts apps/plot/screenshots/capture/macos.sh apps/plot/screenshots/orchestrate.ts
git commit -m "feat(screenshots): wire windows capture (emulate flag, reuse macos.sh)"
```

---

### Task 6: End-to-end run + visual verification (integration)

Produce the actual Windows screenshots and confirm the chrome/frame are correct. This is the visual gate for Task 2.

**Files:**
- Output (gitignored raw, committed store): `apps/plot/screenshots/store/ms-store/windows/*.png`

**Prerequisites** (same as the macOS capture):
- Local API worker running on `:8787` and the `api-kris.plot.day` tunnel up (`pnpm --filter @plotday/api dev`, `pnpm tunnel:start`).
- Margot seed data present in the local DB (orchestrate reseeds `libs/db/seeds/margot.yaml`; the existing macOS shots already rely on this).
- Playwright Chromium installed (used by the existing compose step).

- [ ] **Step 1: Run the Windows pipeline**

From the repo root:
```bash
cd apps/plot/screenshots && npx tsx orchestrate.ts windows
```
Expected: seeds margot, captures S1/S2/S11/S7/S8 (each prints `Saved …/raw/windows/<scene>-<mode>.png`), then `done windows`. Five PNGs appear in `store/ms-store/windows/`.

> Iterating on just one scene without reseeding (faster, avoids touching the shared DB): run the capture script directly, then compose:
> ```bash
> cd apps/plot/screenshots
> bash capture/macos.sh S11 light raw/windows/S11-light.png \
>   --user=margot.whitcombe@afcmarlow.com --password=margot.whitcombe@afcmarlow.com \
>   --frozen-time=2026-05-01T08:32:00 --light-mode --profile=screenshots-windows \
>   --emulate-windows --scene=S11
> npx tsx compose/compose.ts windows
> ```

- [ ] **Step 2: Verify the output dimensions**

Run:
```bash
cd apps/plot/screenshots && for f in store/ms-store/windows/*.png; do echo -n "$f: "; sips -g pixelWidth -g pixelHeight "$f" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}'; done
```
Expected: each file `3840x2160`.

- [ ] **Step 3: Eyeball the screenshots (the Task 2 visual gate)**

Open `store/ms-store/windows/01-S1.png` … `05-S8.png` and confirm:
- **Windows caption buttons** (minimize / maximize / close) appear in the **top-right** of the app window.
- **No macOS traffic lights** anywhere (top-left is clean).
- Header content is laid out Windows-style (right-inset for the caption buttons), not macOS-style (left-inset).
- Body text renders in **Figtree** (identical to the macOS shots).
- The image carries a **Windows 11 frame** — rounded corners, a subtle border, and a soft shadow — over the brand gradient.
- The dark slot (`04-S7.png`) reads correctly in dark mode.

If the corner radius/border needs tuning, adjust `radius` / the `border` in `multipanelWindows` (`templates.ts`) and re-run `npx tsx compose/compose.ts windows` (compose-only, seconds — no recapture).

- [ ] **Step 4: Finalize**

Run the finalize checks for the touched packages:
```bash
cd apps/plot && flutter analyze
cd apps/plot/screenshots && npx tsx --test compose/templates.test.ts manifest.test.ts launch-args.test.ts geometry.test.ts
```
Expected: analyze clean; all TS tests pass (`# fail 0`). (No `tsc` gate — see Task 3 Step 6.)

- [ ] **Step 5: Commit the generated store screenshots**

```bash
git add apps/plot/screenshots/store/ms-store/windows
git commit -m "feat(screenshots): generate Windows MS Store screenshots"
```

---

## Notes for the executor

- **Worktree:** this touches the Flutter app and requires running it, so prefer an isolated worktree (see `superpowers:using-git-worktrees`). The capture needs the local API worker + tunnel and reuses the main DB's margot seed.
- **No `docs/updates.md` entry:** this is internal tooling, not a user-facing app change.
- **Manual upload:** generated PNGs are uploaded by hand to Partner Center (product `9PKTCSN8SNZF`); the release pipeline uploads builds only (`docs/windows-store-publishing.md`).
- **Spec:** `docs/superpowers/specs/2026-06-16-windows-store-screenshots-design.md`.
