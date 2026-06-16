# App Store Screenshots Framework — Design

**Date:** 2026-06-15
**Status:** Approved (design); vertical slice pending implementation plan
**Spec source:** [`docs/store-listings.md`](../../store-listings.md) — the "Store
imagery" section (catalog S1–S12, per-platform slot plans, conventions) is the
authoritative description of *what* to produce. This doc designs *how* to
produce it.

## Goal

A fast, reliable, re-runnable framework that generates store-ready screenshots
for the Apple App Store (iPhone, iPad, macOS), Google Play (phone, tablet), and
the Microsoft Store (Windows), from one synthetic data set (`margot.yaml`) and
one visual system. "Reliable" means each shot reaches its exact state
deterministically — no hand-driving the UI per run — and re-running reproduces
pixel-identical raw captures.

## What already exists (the foundation we build on)

- **App launch hooks** (`apps/plot/lib/cli_args.dart`): `--user`, `--password`,
  `--url`, `--dark-mode`/`--light-mode`, `--frozen-time=ISO8601`, `--profile`,
  `--enable-driver-extension`.
- **Frozen clock** (`apps/plot/lib/util/time_service.dart`): `Time.now()` honors
  `--frozen-time` and runtime `Time.setFrozenTime`.
- **flutter_driver binding** (`apps/plot/lib/driver_binding.dart`): driver
  extension with frame-sync disabled (works despite Plot's constant animations).
- **Seed → DB**: `pnpm gen-seed --apply libs/db/seeds/margot.yaml`; locally the
  user signs in with password = their email.
- **Sims wired** in `apps/plot/package.json`: `sim:ios`
  (`05E59DE7-DEEA-437B-955A-DECB91443E4A`), `sim:ipad`
  (`9EC93BEB-903E-4B86-934C-2AFB4CFA4C26`), `sim:android` (`android_medium`,
  port 5554), `sim:tablet` (`Galaxy_Tab_S8_Ultra`, port 5556).
- **Android capture** (`apps/plot/scripts/take-screenshot.sh`) and an empty
  `apps/plot/screenshots/` output dir; iOS fastlane `Snapfile` exists but its
  `snapshot` lane needs XCUITest targets Flutter lacks — effectively unused, and
  this framework replaces that path.
- **Playwright** binary present in `apps/plot/node_modules`; **sharp** already in
  the workspace `onlyBuiltDependencies`.

## What's missing (what this framework adds)

1. Deterministic **per-scene state setup** (the spec's states — reply
   half-typed with caret, "typing Po", scrolled-to-top, a specific right panel
   open — are not URL-expressible).
2. Clean **capture per platform** with correct chrome (8:32 status-bar clock,
   full bars/battery, no scrollbars).
3. **Composition** — device frames, the caption system, the angled hero
   spanning slots 1→2 with a continuous gradient, flat multi-panel for
   tablet/desktop.
4. A **manifest** that encodes the catalog + per-platform slot plans so capture
   and composition are data-driven from the spec.

## Architecture — five layers + one manifest

### The crux: scene state setup — in-app scene hooks (hybrid)

Each scene reaches its exact state via a new debug-only launch arg
`--scene=<id>` that runs a **Dart scene registry**, not by external driving.
Rationale (see design discussion): external flutter_driver driving is fragile
against Plot's animations, slow, and not reproducible; in-app hooks are
reliable, fast, reproducible, and versioned alongside the UI they depend on.
flutter_driver stays available as a last-mile escape hatch but is unused by
default.

**Registry** (`apps/plot/lib/screenshot/scenes.dart`, debug-only, tree-shaken
from release): a map from `sceneId` → an async `setup` that, after sign-in and
initial sync:

1. **Waits for data** — awaits a scene-specific readiness condition (e.g. the
   "Founding-season scarf design" thread exists in the local store), rather than
   a fixed sleep.
2. **Navigates** — via the existing router/blocs (open a focus, open a thread,
   open the New/Search/Agenda tab, open the ⌘K palette).
3. **Sets UI state** — scroll offset to top, multiselect off, inject composer
   text and place the caret (S2), prefill + run the search query (S6), filter
   the people picker by typed text (S5).
4. **Enables screenshot chrome** — hide scrollbars, suppress any debug
   affordances.
5. **Signals readiness** — prints `SCENE_READY:<id>` to stdout (surfaced by
   `flutter run --machine`). The capture orchestrator waits for this marker
   before snapping. This readiness handshake is the core of "reliable" — no
   guessing with sleeps.

A scene that cannot fully self-set (rare) may declare a small list of
driver follow-up steps the orchestrator runs before capture.

### Layer 1 — Manifest (single source of truth)

`apps/plot/screenshots/manifest.ts` transcribes `store-listings.md`:

```ts
type Mode = 'light' | 'dark';
type Framing = 'phone' | 'phone-hero-span' | 'multipanel-flat';

interface Scene { id: string; route: string; defaultMode: Mode; }      // S1..S12
interface Slot {
  slot: number | [number, number];   // [1,2] = spanning hero across two slots
  scene: string; mode: Mode;
  headline: string; subhead?: string;
  framing: Framing;
}
interface PlatformPlan {
  store: 'app-store' | 'play' | 'ms-store';
  device: string;                     // 'iphone-6.9' | 'ipad-13' | 'macos' | ...
  resolution: [number, number];       // exact required output px
  slots: Slot[];
}
```

The catalog and every per-platform table in `store-listings.md` map 1:1 onto
`Scene[]` and `PlatformPlan[]`. Editing the spec means editing this file; capture
and composition both consume it.

### Layer 2 — Data + launch

`pnpm gen-seed --apply libs/db/seeds/margot.yaml` seeds the dev DB once per run.
Each capture launches the app with:

```
--user=margot.whitcombe@afcmarlow.com --password=<her email>
--frozen-time=2026-05-01T08:32:00
--light-mode|--dark-mode --scene=<id>
--profile=screenshots-<platform>
```

A dedicated `screenshots-<platform>` profile isolates capture state from the
agent/dev profiles.

### Layer 3 — Capture

`apps/plot/screenshots/capture/{ios,macos,android}.sh`, orchestrated by Node:

- **iOS / iPad** — boot the sim (known UDIDs), `xcrun simctl status_bar <udid>
  override --time "8:32" --batteryState charged --batteryLevel 100 --cellularBars
  4 --wifiBars 3 --dataNetwork wifi`, launch, wait for `SCENE_READY`, then
  `xcrun simctl io <udid> screenshot`. Capture on a sim whose native render
  matches the App Store slot so the screen content needs no upscaling: **iPhone
  16 Pro Max** for the 6.9" iPhone set, **iPad Pro 12.9" (6th gen)** (the device
  already in the `Snapfile`) for the iPad set. The manifest's `resolution` is the
  authoritative final export size (per `store-listings.md`: 6.9" iPhone →
  1290×2796 portrait; 12.9"/13" iPad → 2732×2048 landscape); composition scales
  the framed result to it.
- **macOS** — launch via the existing `agent-app-launch.sh` flow (DTD + retry),
  wait for `SCENE_READY`, capture just the app window with `screencapture -l
  <windowid> -o` (no shadow, no macOS menu bar). Resize the window first to a
  fixed capture size so output is deterministic.
- **Android** — boot the AVD, set demo-mode status bar (8:32, full bars), launch,
  wait for `SCENE_READY`, `adb exec-out screencap -p` (reusing
  `take-screenshot.sh`'s approach).

Output → `apps/plot/screenshots/raw/<platform>/<sceneId>-<mode>.png` at native
resolution. Raw captures are deterministic given the same seed + frozen clock.

### Layer 4 — Composition

`apps/plot/screenshots/compose/` (Playwright + HTML/CSS, sharp for slicing):

- Renders an HTML page per output slot/group, screenshots it with Playwright,
  exports at the manifest's exact target resolution.
- **Device frames** — current-device PNGs (iPhone 16 Pro, Pixel) overlaid via
  CSS; the raw capture sits in the frame's screen rect.
- **Caption system** — headline (≤~6 words) + optional one-line subhead, top
  third, brand gradient, one shared typeface/size/placement per platform set;
  legible at thumbnail size.
- **Brand gradient** — green `#01845E` → magenta `#944390` (from
  `apps/site/app/routes/home.module.css`; lighter-green dark variant `#4AB088`).
- **Angled spanning hero** — render the framed, tilted device + the headline on
  **one wide canvas** with a **single** background gradient, then slice into slot
  1 and slot 2 with sharp. Because both slots come from one gradient, continuity
  across the seam is exact. Tilt via CSS `transform: perspective() rotateY()`.
- **Flat multi-panel** — desktop/tablet shots framed full-bleed or in a subtle
  frame, no tilt.

Output → `apps/plot/screenshots/store/<store>/<device>/NN-<slot>.png`.

### Orchestrator CLI

`apps/plot/screenshots/orchestrate.ts`, exposed as `pnpm --filter @plotday/plot
screenshots <platform> [sceneId…]`. Steps, each skippable/idempotent: ensure
seed → for each (scene, mode) in the platform plan: launch + capture → compose
the platform's slots. Re-running recomposes from existing raw captures unless
`--recapture` is passed.

## Repo layout (finalized — all under `apps/plot`, part of `@plotday/plot`)

```
apps/plot/lib/cli_args.dart                 # + --scene=<id>
apps/plot/lib/screenshot/scenes.dart        # scene registry (Dart, debug-only)
apps/plot/lib/screenshot/screenshot_chrome.dart  # hide scrollbars etc.
apps/plot/screenshots/
  manifest.ts                               # catalog + per-platform slot plans
  orchestrate.ts                            # pnpm screenshots <platform>
  capture/{ios,macos,android}.sh
  compose/{compose.ts, templates/*.html, frames/*.png}
  raw/      # gitignored (regenerable)
  store/    # committed (final assets)
apps/plot/package.json                      # + "screenshots" script, devDeps: playwright, sharp
```

## First deliverable — the vertical slice

**Scope:** S1 + S2, captured on **iPhone 16 Pro sim + Mac**, composed to
store-ready PNGs.

Concretely:
- Scene hooks for **S1** (focus feed — Launch women's team; single-panel on
  phone, multi-panel with scarf-design thread open on Mac) and **S2** (thread +
  half-typed reply with caret).
- Capture on iPhone 16 Pro Max sim (native 6.9", exported at 1290×2796) and Mac
  (multi-panel window).
- Compose: the iPhone **S1 angled panorama hero spanning slots 1→2** with a
  continuous green→magenta gradient + caption "All your work, ready for action";
  the iPhone **S2** phone shot with caption; the Mac **flat multi-panel** S1 + S2
  with captions.

**Acceptance criteria:**
1. `pnpm --filter @plotday/plot screenshots ios S1 S2` and `… macos S1 S2`
   produce the raw + store PNGs with zero manual UI interaction.
2. Re-running reproduces byte-identical raw captures.
3. The spanning hero's gradient is continuous across the slot 1/2 seam.
4. Status-bar clock reads 8:32; chrome is clean (no scrollbars/debug banners).
5. Captions are legible at thumbnail scale.

Proving this locks the quality bar and the hardest mechanics (scene hooks,
readiness handshake, status-bar clock, gradient continuity, both framing modes)
before scaling to all scenes, platforms, and stores.

## Out of scope (deferred, not designed here)

- **Windows capture** — needs a Windows VM/machine; the framework's manifest +
  composition can frame Windows shots once raw captures are supplied, but
  capturing them is out of this slice.
- **Remaining scenes/platforms** — S3–S12, iPad, Android phone/tablet, Play
  feature graphic, all store assemblies. Added after the slice validates.
- **Store upload** — fastlane metadata/screenshot upload lanes; this framework
  only produces files on disk.
- **Motion** — the optional iOS App Preview / Play promo video.

## Risks / open questions

- **Scene drift** — scene hooks depend on the live UI; a router/bloc change can
  break a scene. Mitigation: keep scenes thin (lean on `--url` deep links where
  possible) and run the slice in CI-adjacent fashion when the UI changes near a
  captured surface. Not automated in the slice.
- **macOS window capture determinism** — window size/position and Retina scaling
  must be pinned; the capture script fixes the window rect before snapping.
- **Frame asset sourcing** — device-frame PNGs (current iPhone Pro, Pixel) must
  be sourced; for the slice we need one current iPhone Pro frame only.
- **Playwright/sharp as `@plotday/plot` devDeps** — add explicitly rather than
  relying on the hoisted Playwright; run `pnpm install` after.
```
