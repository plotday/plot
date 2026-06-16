# App Store Screenshots Framework — Implementation Plan (Vertical Slice)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate store-ready App Store screenshots for **S1 + S2 on iPhone + Mac** end-to-end, with deterministic in-app scene setup, clean capture, and a Playwright compositor (device frame, caption, angled gradient-spanning hero).

**Architecture:** A debug-only `--scene=<id>` launch arg runs a Dart **scene registry** that, after sign-in + sync, navigates the UI and (for S2) pre-seeds the reply composer, then prints `SCENE_READY:<id>`. Per-platform capture scripts boot the device, set the 8:32 status-bar clock, wait for that marker, and snap a raw PNG. A Playwright/HTML compositor reads a `manifest.ts` and renders raw shots into framed, captioned store assets — the phone hero rendered on one wide canvas with a single brand gradient and sliced into slots 1→2 for seam continuity.

**Tech Stack:** Flutter (Dart) for the app + scene hooks; `auto_route` for navigation; `super_editor`-backed composer (pre-seeded via the `Note` draft); `tsx` + Playwright (already in `apps/plot/node_modules`) + HTML/CSS for capture orchestration and composition; `xcrun simctl` + `screencapture` for capture.

---

## Reference facts (verified, use verbatim)

- **Seed:** `libs/db/seeds/margot.yaml` — `baseDate: 2026-05-01`, user `margot.whitcombe@afcmarlow.com` (local password = email), name "Margot Whitcombe". Apply with `pnpm gen-seed --apply libs/db/seeds/margot.yaml`.
- **Exact titles:** focus **"Launch women's team"**; threads **"Founding-season scarf design"** (S1 right panel) and **"Chelsea (A) — coaching staff plan"** (S2).
- **Frozen clock:** `--frozen-time=2026-05-01T08:32:00`.
- **Existing CLI args** (`apps/plot/lib/cli_args.dart`): `--user`, `--password`, `--frozen-time`, `--light-mode`/`--dark-mode`, `--profile`, `--enable-driver-extension`.
- **Navigation** (`auto_route`): `appRouter.replaceAll([PriorityRoute(priorityIdString: <b58>, children: [ThreadRoute(threadIdString: <b58>)])])`. IDs via `id.toShortString()`.
- **Store lookup:** `Store.get.select(Store.get.priorities)..where((p) => p.title.equals('…'))..limit(1)).getSingleOrNull()` (same for `threads`).
- **Global navigator:** `navigatorKey` (main.dart:79-87), set from `router.navigatorKey`.
- **Scene entry point:** `apps/plot/lib/state/root_provider.dart` `UserReady` case (line ~170), after `await Future.wait([prioritiesBloc.start(), TwistInstance.start(), nowBloc.start()])`.
- **Draft load (S2 hook):** `apps/plot/lib/state/thread.dart` `_loadDraftNote()` (line ~425); drafts are `Note`, set content with `state.draft.copyWith(content: Value('…'))`; `ThreadBloc.updateDraft(Note)` exists.
- **Composer focus:** `NoteEditorState.focus()` (note_editor.dart:207).
- **Layout:** `LayoutState.isMultiPanel(width)` / `context.read<LayoutBloc>().state.multiPanel`.
- **Window sizing:** `window_manager: ^0.5.1` (pubspec.yaml:64).
- **No `sharp`** installed → slice the hero with Playwright `clip`.

## File structure

```
apps/plot/lib/cli_args.dart                       # MODIFY: + --scene=<id>
apps/plot/lib/screenshot/scenes.dart              # CREATE: scene registry + run() + draft/state holders
apps/plot/lib/state/root_provider.dart            # MODIFY: invoke Scenes.run on UserReady
apps/plot/lib/state/thread.dart                   # MODIFY: pre-seed draft from Scenes (S2)
apps/plot/lib/widget/note_editor.dart             # MODIFY: focus composer in scene mode (S2)
apps/plot/test/screenshot/scenes_test.dart        # CREATE: Dart unit tests for arg + registry

apps/plot/screenshots/manifest.ts                 # CREATE: S1/S2 catalog + iphone/macos plans
apps/plot/screenshots/geometry.ts                 # CREATE: pure hero-slice math (unit-tested)
apps/plot/screenshots/geometry.test.ts            # CREATE: node:test for geometry
apps/plot/screenshots/launch-args.ts              # CREATE: build dart-entrypoint args per (scene,mode,platform)
apps/plot/screenshots/capture/ios.sh              # CREATE: boot sim, status bar, launch, wait, snap
apps/plot/screenshots/capture/macos.sh            # CREATE: launch, wait, window-region capture
apps/plot/screenshots/compose/templates.ts        # CREATE: HTML/CSS builders (frame, caption, gradient)
apps/plot/screenshots/compose/compose.ts          # CREATE: Playwright render + hero slice → store PNGs
apps/plot/screenshots/orchestrate.ts              # CREATE: ensure-seed → capture → compose
apps/plot/screenshots/tsconfig.json               # CREATE: minimal TS config
apps/plot/screenshots/.gitignore                  # CREATE: ignore raw/, node debris
apps/plot/screenshots/raw/                         # OUTPUT (gitignored)
apps/plot/screenshots/store/                        # OUTPUT (committed)
apps/plot/package.json                            # MODIFY: + devDeps (playwright, tsx) + "screenshots" script
```

---

## Task 1: Add `--scene=<id>` CLI arg

**Files:**
- Modify: `apps/plot/lib/cli_args.dart`
- Test: `apps/plot/test/screenshot/scenes_test.dart`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/screenshot/scenes_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/cli_args.dart';

void main() {
  test('parses --scene=<id>', () {
    CliArgs.resetForTest();
    CliArgs.init(['--scene=S1']);
    expect(CliArgs.scene, 'S1');
  });

  test('scene is null when absent', () {
    CliArgs.resetForTest();
    CliArgs.init(['--user=a@b.c']);
    expect(CliArgs.scene, isNull);
  });
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd apps/plot && flutter test test/screenshot/scenes_test.dart`
Expected: FAIL — `CliArgs.scene` / `CliArgs.resetForTest` not defined.

- [ ] **Step 3: Implement the arg**

In `apps/plot/lib/cli_args.dart`: add field `static String? _scene;`, parse it in the loop (mirror `--user=`):

```dart
      } else if (arg.startsWith('--scene=')) {
        _scene = arg.substring('--scene='.length);
        _log.info('Screenshot scene: $_scene');
```

Add getter and a test reset (place near the other getters):

```dart
  /// Returns the screenshot scene id if --scene was provided.
  static String? get scene => _scene;

  @visibleForTesting
  static void resetForTest() {
    _initialized = false;
    _user = _password = _url = _profile = _scene = null;
    _darkMode = _lightMode = _noProfile = _enableDriverExtension = false;
    _frozenTime = null;
  }
```

Add `import 'package:flutter/foundation.dart';` already present (file uses `kDebugMode`); ensure `@visibleForTesting` resolves (it's in `foundation.dart`).

- [ ] **Step 4: Run the test to confirm it passes**

Run: `cd apps/plot && flutter test test/screenshot/scenes_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/cli_args.dart apps/plot/test/screenshot/scenes_test.dart
git commit -m "feat(screenshots): add --scene CLI arg"
```

---

## Task 2: Scene registry scaffold (`scenes.dart`)

**Files:**
- Create: `apps/plot/lib/screenshot/scenes.dart`
- Test: `apps/plot/test/screenshot/scenes_test.dart` (extend)

The registry holds the current scene, exposes per-thread draft text for S2, awaits router readiness, dispatches to a scene function, and prints the readiness marker.

- [ ] **Step 1: Add a failing test for the draft holder**

Append to `apps/plot/test/screenshot/scenes_test.dart`:

```dart
import 'package:plot/screenshot/scenes.dart';
// ...inside main():
  test('draftFor returns text only for the active scene target thread', () {
    Scenes.activate('S2', draftThreadTitle: 'Chelsea (A) — coaching staff plan',
        draftContent: 'Great work, all.');
    expect(Scenes.draftContentFor('Chelsea (A) — coaching staff plan'),
        'Great work, all.');
    expect(Scenes.draftContentFor('Some other thread'), isNull);
    Scenes.clear();
    expect(Scenes.draftContentFor('Chelsea (A) — coaching staff plan'), isNull);
  });
```

- [ ] **Step 2: Run to confirm it fails**

Run: `cd apps/plot && flutter test test/screenshot/scenes_test.dart`
Expected: FAIL — `Scenes` undefined.

- [ ] **Step 3: Create `apps/plot/lib/screenshot/scenes.dart`**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:plot/main.dart' show navigatorKey;

/// Debug-only screenshot scene runner. Sets up deterministic UI states for the
/// store-listing screenshots (see docs/store-listings.md) and prints
/// `SCENE_READY:<id>` to stdout once the target screen is composed, which the
/// capture orchestrator waits on. No-op in release builds.
class Scenes {
  Scenes._();

  static final Logger _log = Logger('Scenes');

  static String? _activeId;
  static String? _draftThreadTitle;
  static String? _draftContent;

  /// Activates a scene's auxiliary state (used by widget hooks). Called by
  /// [run]; exposed for tests.
  @visibleForTesting
  static void activate(String id,
      {String? draftThreadTitle, String? draftContent}) {
    _activeId = id;
    _draftThreadTitle = draftThreadTitle;
    _draftContent = draftContent;
  }

  @visibleForTesting
  static void clear() {
    _activeId = _draftThreadTitle = _draftContent = null;
  }

  /// True while a screenshot scene is active.
  static bool get active => _activeId != null;

  /// The reply text to pre-seed for [threadTitle], or null. Consumed by the
  /// thread bloc + composer so S2 shows a half-typed reply with a live caret.
  static String? draftContentFor(String threadTitle) =>
      (_draftThreadTitle == threadTitle) ? _draftContent : null;

  /// Entry point invoked from RootProvider's UserReady handler. Awaits the
  /// router, runs the scene's setup, settles a few frames, then emits the
  /// readiness marker.
  static Future<void> run(String id) async {
    if (!kDebugMode) return;
    _log.info('Scene starting: $id');
    final context = await _awaitContext();
    if (context == null) {
      _log.warning('Scene $id: navigator never became ready');
      return;
    }
    try {
      final setup = _registry[id];
      if (setup == null) {
        _log.warning('Unknown scene: $id');
        return;
      }
      await setup(context);
      await _settle();
      // ignore: avoid_print  (the capture orchestrator greps stdout for this)
      print('SCENE_READY:$id');
    } catch (e, s) {
      _log.warning('Scene $id failed', e, s);
    }
  }

  /// Registry filled in Tasks 4 (S1) and 5 (S2).
  static final Map<String, Future<void> Function(BuildContext)> _registry = {};

  static Future<BuildContext?> _awaitContext() async {
    for (var i = 0; i < 120; i++) {
      final c = navigatorKey?.currentContext;
      if (c != null && c.mounted) return c;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  /// Wait for layout + paint to settle after navigation.
  static Future<void> _settle() async {
    for (var i = 0; i < 5; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `cd apps/plot && flutter test test/screenshot/scenes_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

```bash
cd apps/plot && flutter analyze lib/screenshot/scenes.dart
git add apps/plot/lib/screenshot/scenes.dart apps/plot/test/screenshot/scenes_test.dart
git commit -m "feat(screenshots): scene registry scaffold with readiness marker"
```

---

## Task 3: Invoke the scene runner on UserReady

**Files:**
- Modify: `apps/plot/lib/state/root_provider.dart`

- [ ] **Step 1: Read the insertion region**

Run: `sed -n '178,205p' apps/plot/lib/state/root_provider.dart` — confirm the `await Future.wait([prioritiesBloc.start(), TwistInstance.start(), nowBloc.start()]);` block inside `case UserReady _:`.

- [ ] **Step 2: Add the import**

At the top of `root_provider.dart` add: `import 'package:plot/screenshot/scenes.dart';` and ensure `import 'package:plot/cli_args.dart';` is present (add if missing).

- [ ] **Step 3: Invoke the runner**

Immediately after the `await Future.wait([...]);` line in the `UserReady` case, add:

```dart
                if (kDebugMode && CliArgs.scene != null) {
                  unawaited(Scenes.run(CliArgs.scene!));
                }
```

`unawaited` and `kDebugMode` are already imported in this file (it uses both); if not, add `import 'package:flutter/foundation.dart';` and `import 'dart:async';`.

- [ ] **Step 4: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/state/root_provider.dart`
Expected: No new errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/root_provider.dart
git commit -m "feat(screenshots): run scene after UserReady"
```

---

## Task 4: Scene S1 — focus feed (single + multi panel)

**Files:**
- Modify: `apps/plot/lib/screenshot/scenes.dart` (register S1)

S1 navigates to the "Launch women's team" focus. Multi-panel (Mac) additionally opens the "Founding-season scarf design" thread in the right panel; single-panel (phone) shows the list only.

- [ ] **Step 1: Add a private helper to look up entities by title**

Add to `scenes.dart` (import the store):

```dart
import 'package:plot/store/store.dart';
import 'package:plot/store/priority.dart' as store_priority;
import 'package:plot/store/thread.dart' as store_thread;

// inside class Scenes:
  static Future<String?> _priorityIdByTitle(String title) async {
    final row = await (Store.get.select(Store.get.priorities)
          ..where((p) => p.title.equals(title))
          ..limit(1))
        .getSingleOrNull();
    return row?.id.toShortString();
  }

  static Future<String?> _threadIdByTitle(String title) async {
    final row = await (Store.get.select(Store.get.threads)
          ..where((t) => t.title.equals(title) & t.archivedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    return row?.id.toShortString();
  }
```

> If the generated table accessors are not named `priorities`/`threads`, confirm with `grep -nE "select\(Store.get\.(priorities|threads)\)" apps/plot/lib` (Task 0-style check) — the lookup pattern at `apps/plot/lib/store/group.dart:131` and `onboarding_overlay.dart:372` is the source of truth; copy its exact accessor + `id.toShortString()` usage.

- [ ] **Step 2: Register S1**

In the `_registry` map literal in `scenes.dart`, add:

```dart
    'S1': (context) async {
      final focusId = await _priorityIdByTitle("Launch women's team");
      if (focusId == null) throw StateError('S1: focus not found');
      final router = context.router; // from auto_route's BuildContext ext
      final multi = context.read<LayoutBloc>().state.multiPanel;
      if (multi) {
        final scarfId =
            await _threadIdByTitle('Founding-season scarf design');
        router.replaceAll([
          PriorityRoute(
            priorityIdString: focusId,
            children: [
              if (scarfId != null) ThreadRoute(threadIdString: scarfId),
            ],
          ),
        ]);
      } else {
        router.replaceAll([PriorityRoute(priorityIdString: focusId)]);
      }
    },
```

Add imports: `import 'package:plot/router.dart';`, `import 'package:plot/router.gr.dart';`, `import 'package:plot/state/layout.dart';`, `import 'package:flutter_bloc/flutter_bloc.dart';` (for `context.read`).

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/screenshot/scenes.dart`
Expected: No errors. (Fix any accessor/name mismatches surfaced here against the real `router.gr.dart` route classes.)

- [ ] **Step 4: Smoke-verify S1 on Mac via the run-app flow**

Apply the seed once, then launch with the S1 args and confirm the marker:
```bash
pnpm gen-seed --apply libs/db/seeds/margot.yaml
cd apps/plot && flutter run -d macos \
  --dart-entrypoint-args=--user=margot.whitcombe@afcmarlow.com \
  --dart-entrypoint-args=--password=margot.whitcombe@afcmarlow.com \
  --dart-entrypoint-args=--frozen-time=2026-05-01T08:32:00 \
  --dart-entrypoint-args=--light-mode \
  --dart-entrypoint-args=--profile=screenshots-macos \
  --dart-entrypoint-args=--scene=S1
```
Expected: the app opens on the "Launch women's team" focus with the scarf-design thread in the right panel, and the run log prints `SCENE_READY:S1`. Quit with `q`.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/screenshot/scenes.dart
git commit -m "feat(screenshots): scene S1 focus feed (single + multi panel)"
```

---

## Task 5: Scene S2 — thread with half-typed reply

**Files:**
- Modify: `apps/plot/lib/screenshot/scenes.dart` (register S2 + activate draft)
- Modify: `apps/plot/lib/state/thread.dart` (pre-seed draft content)
- Modify: `apps/plot/lib/widget/note_editor.dart` (focus composer in scene mode)

- [ ] **Step 1: Register S2 and activate the draft holder**

In `scenes.dart` `run()`, set the draft state when dispatching S2 — add at the top of `run()` after `_log.info`:

```dart
    if (id == 'S2') {
      Scenes.activate('S2',
          draftThreadTitle: 'Chelsea (A) — coaching staff plan',
          draftContent:
              "Great work, all. Let's go high press from the first whistle");
    } else {
      Scenes.activate(id);
    }
```

Add S2 to `_registry` — one query yields both the thread id and its parent focus id (no double lookup):

```dart
    'S2': (context) async {
      final row = await (Store.get.select(Store.get.threads)
            ..where((t) =>
                t.title.equals('Chelsea (A) — coaching staff plan') &
                t.archivedAt.isNull())
            ..limit(1))
          .getSingleOrNull();
      if (row == null) throw StateError('S2: thread not found');
      context.router.replaceAll([
        PriorityRoute(
          priorityIdString: row.priorityId.toShortString(),
          children: [ThreadRoute(threadIdString: row.id.toShortString())],
        ),
      ]);
    },
```

- [ ] **Step 2: Pre-seed the draft in `thread.dart`**

Read the region: `sed -n '424,432p' apps/plot/lib/state/thread.dart`. At the very top of `_loadDraftNote()` (before the `Note.getDraftByActivity` call), insert:

```dart
    final sceneDraft = Scenes.draftContentFor(state.thread.title ?? '');
    if (sceneDraft != null) {
      emit(state.copyWith(
        draft: state.draft.copyWith(content: Value(sceneDraft)),
      ));
      return;
    }
```

Add `import 'package:plot/screenshot/scenes.dart';` to `thread.dart`. (`Value` is already imported there — it's used at line ~443.)

- [ ] **Step 3: Focus the composer in scene mode**

In `apps/plot/lib/widget/note_editor.dart`, in `NoteEditorState`, add a post-frame focus when a scene draft is active for this thread. Locate `initState()` (or add one) and append:

```dart
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final title = widget.thread?.title; // null in note mode
      // In note mode the draft belongs to the currently-open thread; focus
      // whenever a screenshot scene seeded a draft so the caret renders.
      if (Scenes.active && (widget.draft.content?.isNotEmpty ?? false)) {
        focus();
      }
    });
```

Add `import 'package:plot/screenshot/scenes.dart';` and `import 'package:flutter/widgets.dart';` (if not already importing `WidgetsBinding`). If `NoteEditorState` already has an `initState`, merge the callback rather than duplicating.

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/screenshot/scenes.dart lib/state/thread.dart lib/widget/note_editor.dart`
Expected: No errors.

- [ ] **Step 5: Smoke-verify S2 on Mac**

```bash
cd apps/plot && flutter run -d macos \
  --dart-entrypoint-args=--user=margot.whitcombe@afcmarlow.com \
  --dart-entrypoint-args=--password=margot.whitcombe@afcmarlow.com \
  --dart-entrypoint-args=--frozen-time=2026-05-01T08:32:00 \
  --dart-entrypoint-args=--light-mode \
  --dart-entrypoint-args=--profile=screenshots-macos \
  --dart-entrypoint-args=--scene=S2
```
Expected: the Chelsea thread opens with the composer showing "Great work, all. Let's go high press from the first whistle" and a visible caret; log prints `SCENE_READY:S2`.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/screenshot/scenes.dart apps/plot/lib/state/thread.dart apps/plot/lib/widget/note_editor.dart
git commit -m "feat(screenshots): scene S2 thread with half-typed reply"
```

---

## Task 6: Deterministic macOS window size

**Files:**
- Modify: `apps/plot/lib/screenshot/scenes.dart`

For reproducible Mac captures, size the window to 1440×900 logical (→ 2880×1800 Retina pixels) whenever a scene runs on desktop.

- [ ] **Step 1: Add window sizing to `Scenes.run`**

In `scenes.dart`, before `_awaitContext()`, add (guarded so it only runs on desktop platforms, never web/mobile):

```dart
import 'dart:io' show Platform;
import 'package:window_manager/window_manager.dart';

// inside run(), first line after the kDebugMode guard:
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows)) {
      try {
        await windowManager.ensureInitialized();
        await windowManager.setSize(const Size(1440, 900));
        await windowManager.setAlignment(Alignment.center);
      } catch (e) {
        _log.warning('window sizing failed', e);
      }
    }
```

Add `import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;` (kDebugMode already used). Guard `Platform` behind `!kIsWeb` per the project hint (dart:io Platform throws on web).

- [ ] **Step 2: Analyze + smoke check**

Run: `cd apps/plot && flutter analyze lib/screenshot/scenes.dart`
Re-run the Task 4 Step 4 macOS launch; confirm the window opens at a fixed centered 1440×900 size.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/screenshot/scenes.dart
git commit -m "feat(screenshots): pin macOS window to 1440x900 for capture"
```

---

## Task 7: Manifest + launch-args + geometry (TS)

**Files:**
- Create: `apps/plot/screenshots/manifest.ts`, `launch-args.ts`, `geometry.ts`, `geometry.test.ts`, `tsconfig.json`, `.gitignore`

- [ ] **Step 1: tsconfig + gitignore**

`apps/plot/screenshots/tsconfig.json`:
```json
{ "compilerOptions": { "target": "ES2022", "module": "ESNext", "moduleResolution": "Bundler", "strict": true, "skipLibCheck": true, "types": ["node"] } }
```
`apps/plot/screenshots/.gitignore`:
```
raw/
*.log
```

- [ ] **Step 2: manifest.ts**

```ts
export type Mode = 'light' | 'dark';
export type Framing = 'phone' | 'phone-hero-span' | 'multipanel-flat';

export interface SlotPlan {
  slots: number[];          // [3] = one slot; [1,2] = spanning hero
  scene: string;
  mode: Mode;
  framing: Framing;
  headline: string;
  subhead?: string;
}
export interface PlatformPlan {
  platform: 'iphone-6.9' | 'macos';
  store: 'app-store';
  captureDevice: string;    // sim name or 'macos'
  resolution: [number, number]; // exact px per slot
  slots: SlotPlan[];
}

export const PLANS: PlatformPlan[] = [
  {
    platform: 'iphone-6.9', store: 'app-store',
    captureDevice: 'iPhone 16 Pro Max', resolution: [1290, 2796],
    slots: [
      { slots: [1, 2], scene: 'S1', mode: 'light', framing: 'phone-hero-span',
        headline: 'All your work, ready for action',
        subhead: 'Team chat, email, and app threads in one place' },
      { slots: [3], scene: 'S2', mode: 'light', framing: 'phone',
        headline: 'Reply right where it lands', subhead: 'In Slack, Gmail, or Linear' },
    ],
  },
  {
    platform: 'macos', store: 'app-store',
    captureDevice: 'macos', resolution: [2880, 1800],
    slots: [
      { slots: [1], scene: 'S1', mode: 'light', framing: 'multipanel-flat',
        headline: 'All your work, ready for action' },
      { slots: [2], scene: 'S2', mode: 'light', framing: 'multipanel-flat',
        headline: 'Reply right where it lands, in Slack, Gmail, or Linear' },
    ],
  },
];

export const BRAND = { green: '#01845E', magenta: '#944390', greenDark: '#4AB088' };

/** Distinct (scene, mode) pairs to capture for a platform. */
export function capturesFor(p: PlatformPlan): { scene: string; mode: Mode }[] {
  const seen = new Set<string>();
  const out: { scene: string; mode: Mode }[] = [];
  for (const s of p.slots) {
    const k = `${s.scene}-${s.mode}`;
    if (!seen.has(k)) { seen.add(k); out.push({ scene: s.scene, mode: s.mode }); }
  }
  return out;
}
```

- [ ] **Step 3: launch-args.ts**

```ts
import type { Mode } from './manifest.ts';

const USER = 'margot.whitcombe@afcmarlow.com';
const FROZEN = '2026-05-01T08:32:00';

/** dart-entrypoint args (without the `--dart-entrypoint-args=` prefix). */
export function dartArgs(scene: string, mode: Mode, platform: string): string[] {
  return [
    `--user=${USER}`,
    `--password=${USER}`,
    `--frozen-time=${FROZEN}`,
    mode === 'dark' ? '--dark-mode' : '--light-mode',
    `--profile=screenshots-${platform}`,
    `--scene=${scene}`,
  ];
}
```

- [ ] **Step 4: Write the geometry test (TDD)**

`apps/plot/screenshots/geometry.test.ts`:
```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heroClips } from './geometry.ts';

test('heroClips splits a double-wide canvas into two equal slots', () => {
  const clips = heroClips([1290, 2796]);
  assert.equal(clips.length, 2);
  assert.deepEqual(clips[0], { x: 0, y: 0, width: 1290, height: 2796 });
  assert.deepEqual(clips[1], { x: 1290, y: 0, width: 1290, height: 2796 });
});
```

- [ ] **Step 5: Run it to confirm it fails**

Run: `cd apps/plot/screenshots && node --test --experimental-strip-types geometry.test.ts`
Expected: FAIL — `heroClips` not found. (If `--experimental-strip-types` is unavailable on the local Node, use `npx tsx --test geometry.test.ts`.)

- [ ] **Step 6: Implement geometry.ts**

```ts
export interface Clip { x: number; y: number; width: number; height: number; }

/** The full canvas size for a spanning hero = two slots side by side. */
export function heroCanvas([w, h]: [number, number]): [number, number] {
  return [w * 2, h];
}

/** Clip rects to slice the rendered hero canvas back into two slot PNGs. */
export function heroClips([w, h]: [number, number]): Clip[] {
  return [
    { x: 0, y: 0, width: w, height: h },
    { x: w, y: 0, width: w, height: h },
  ];
}
```

- [ ] **Step 7: Run the test to confirm it passes**

Run: `cd apps/plot/screenshots && npx tsx --test geometry.test.ts`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/screenshots/{manifest.ts,launch-args.ts,geometry.ts,geometry.test.ts,tsconfig.json,.gitignore}
git commit -m "feat(screenshots): manifest, launch-args, hero-slice geometry"
```

---

## Task 8: iOS capture script

**Files:**
- Create: `apps/plot/screenshots/capture/ios.sh`

Resolves/boots an "iPhone 16 Pro Max" sim, sets the 8:32 status bar, launches the app with scene args, waits for `SCENE_READY`, snaps a raw PNG, then tears down the run.

- [ ] **Step 1: Write the script**

`apps/plot/screenshots/capture/ios.sh`:
```bash
#!/usr/bin/env bash
# Usage: ios.sh <scene> <mode> <out.png> <dart-arg>...
set -euo pipefail
SCENE="$1"; MODE="$2"; OUT="$3"; shift 3
DART_ARGS=("$@")
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="iPhone 16 Pro Max"

UDID=$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}') || true
if [[ -z "${UDID:-}" ]]; then
  RUNTIME=$(xcrun simctl list runtimes | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS[^ ]*' | tail -1)
  UDID=$(xcrun simctl create "$DEVICE" "$DEVICE" "$RUNTIME")
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override \
  --time "8:32" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --dataNetwork wifi --operatorName ' '

LOG=$(mktemp)
RUN_ARGS=()
for a in "${DART_ARGS[@]}"; do RUN_ARGS+=(--dart-entrypoint-args="$a"); done
( cd "$APP_DIR" && flutter run -d "$UDID" "${RUN_ARGS[@]}" >"$LOG" 2>&1 ) &
RUN_PID=$!

for _ in $(seq 1 240); do
  grep -q "SCENE_READY:$SCENE" "$LOG" && break
  kill -0 "$RUN_PID" 2>/dev/null || { echo "flutter run died"; cat "$LOG"; exit 1; }
  sleep 1
done
grep -q "SCENE_READY:$SCENE" "$LOG" || { echo "timeout waiting for SCENE_READY:$SCENE"; cat "$LOG"; exit 1; }
sleep 1
mkdir -p "$(dirname "$OUT")"
xcrun simctl io "$UDID" screenshot "$OUT"
echo "Saved $OUT"
kill "$RUN_PID" 2>/dev/null || true
```

- [ ] **Step 2: Make executable + verify S1 capture**

```bash
chmod +x apps/plot/screenshots/capture/ios.sh
pnpm gen-seed --apply libs/db/seeds/margot.yaml
apps/plot/screenshots/capture/ios.sh S1 light /tmp/s1.png \
  --user=margot.whitcombe@afcmarlow.com --password=margot.whitcombe@afcmarlow.com \
  --frozen-time=2026-05-01T08:32:00 --light-mode --profile=screenshots-iphone-6.9 --scene=S1
```
Expected: `/tmp/s1.png` written; `sips -g pixelWidth -g pixelHeight /tmp/s1.png` reports 1290×2796; status-bar clock reads 8:32.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/screenshots/capture/ios.sh
git commit -m "feat(screenshots): iOS sim capture script"
```

---

## Task 9: macOS capture script

**Files:**
- Create: `apps/plot/screenshots/capture/macos.sh`

- [ ] **Step 1: Write the script**

`apps/plot/screenshots/capture/macos.sh`:
```bash
#!/usr/bin/env bash
# Usage: macos.sh <scene> <mode> <out.png> <dart-arg>...
set -euo pipefail
SCENE="$1"; MODE="$2"; OUT="$3"; shift 3
DART_ARGS=("$@")
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

LOG=$(mktemp)
RUN_ARGS=()
for a in "${DART_ARGS[@]}"; do RUN_ARGS+=(--dart-entrypoint-args="$a"); done
( cd "$APP_DIR" && flutter run -d macos "${RUN_ARGS[@]}" >"$LOG" 2>&1 ) &
RUN_PID=$!

for _ in $(seq 1 240); do
  grep -q "SCENE_READY:$SCENE" "$LOG" && break
  kill -0 "$RUN_PID" 2>/dev/null || { echo "flutter run died"; cat "$LOG"; exit 1; }
  sleep 1
done
grep -q "SCENE_READY:$SCENE" "$LOG" || { echo "timeout"; cat "$LOG"; exit 1; }
sleep 1

# Read the Plot window's position+size (points) and capture that region.
BOUNDS=$(osascript -e 'tell application "System Events" to tell process "Plot" to get {position, size} of front window')
# BOUNDS like: 240, 100, 1440, 900
IFS=', ' read -r X Y W H <<<"$BOUNDS"
mkdir -p "$(dirname "$OUT")"
screencapture -x -o -R"${X},${Y},${W},${H}" "$OUT"
echo "Saved $OUT"
kill "$RUN_PID" 2>/dev/null || true
```

- [ ] **Step 2: Make executable + verify S1**

```bash
chmod +x apps/plot/screenshots/capture/macos.sh
apps/plot/screenshots/capture/macos.sh S1 light /tmp/mac-s1.png \
  --user=margot.whitcombe@afcmarlow.com --password=margot.whitcombe@afcmarlow.com \
  --frozen-time=2026-05-01T08:32:00 --light-mode --profile=screenshots-macos --scene=S1
```
Expected: `/tmp/mac-s1.png` written; `sips -g pixelWidth -g pixelHeight /tmp/mac-s1.png` ≈ 2880×1800 (Retina 2× of 1440×900).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/screenshots/capture/macos.sh
git commit -m "feat(screenshots): macOS window capture script"
```

---

## Task 10: Compose templates (HTML/CSS)

**Files:**
- Create: `apps/plot/screenshots/compose/templates.ts`

Pure functions returning HTML strings: a phone shot (CSS-drawn device frame + caption + brand gradient), the spanning hero (one tilted device on a double-wide single-gradient canvas), and a flat multi-panel frame.

- [ ] **Step 1: Write templates.ts**

```ts
import { BRAND } from '../manifest.ts';

const FONT =
  `-apple-system, BlinkMacSystemFont, 'SF Pro Display', Inter, sans-serif`;

function gradient(angleDeg: number): string {
  // One continuous brand gradient; reused so spanning slots align.
  return `linear-gradient(${angleDeg}deg, ${BRAND.green} 0%, ${BRAND.magenta} 100%)`;
}

function caption(headline: string, subhead: string | undefined, w: number): string {
  const size = Math.round(w * 0.052);
  const sub = Math.round(w * 0.030);
  return `
    <div style="position:absolute;top:6%;left:0;right:0;text-align:center;
      font-family:${FONT};color:#fff;padding:0 8%">
      <div style="font-weight:700;font-size:${size}px;line-height:1.1;
        letter-spacing:-0.5px">${headline}</div>
      ${subhead ? `<div style="margin-top:14px;font-weight:400;opacity:.92;
        font-size:${sub}px">${subhead}</div>` : ''}
    </div>`;
}

/** A CSS device frame wrapping a screenshot data URL. */
function frame(src: string, screenW: number, screenH: number): string {
  const bezel = Math.round(screenW * 0.018);
  const radius = Math.round(screenW * 0.11);
  return `
    <div style="background:#0b0b0d;padding:${bezel}px;border-radius:${radius}px;
      box-shadow:0 40px 120px rgba(0,0,0,.45)">
      <img src="${src}" width="${screenW}" height="${screenH}"
        style="display:block;border-radius:${Math.round(radius * 0.82)}px"/>
    </div>`;
}

/** One phone slot: gradient bg, caption top, framed device lower-center. */
export function phoneSlot(o: {
  src: string; w: number; h: number; screenW: number; screenH: number;
  headline: string; subhead?: string;
}): string {
  const scale = (o.w * 0.74) / o.screenW;
  return `<!doctype html><html><body style="margin:0">
    <div style="position:relative;width:${o.w}px;height:${o.h}px;overflow:hidden;
      background:${gradient(155)}">
      ${caption(o.headline, o.subhead, o.w)}
      <div style="position:absolute;left:50%;top:34%;transform:translateX(-50%)
        scale(${scale})">${frame(o.src, o.screenW, o.screenH)}</div>
    </div></body></html>`;
}

/** Spanning hero: double-wide single-gradient canvas, one tilted device. */
export function heroSpan(o: {
  src: string; canvasW: number; canvasH: number; screenW: number; screenH: number;
  headline: string; subhead?: string;
}): string {
  const scale = (o.canvasW * 0.42) / o.screenW;
  return `<!doctype html><html><body style="margin:0">
    <div style="position:relative;width:${o.canvasW}px;height:${o.canvasH}px;
      overflow:hidden;background:${gradient(155)}">
      <div style="position:absolute;top:7%;left:0;width:50%;text-align:center;
        font-family:${FONT};color:#fff;padding:0 6%">
        <div style="font-weight:700;font-size:${Math.round(o.canvasW * 0.030)}px;
          line-height:1.1;letter-spacing:-1px">${o.headline}</div>
        ${o.subhead ? `<div style="margin-top:16px;opacity:.92;
          font-size:${Math.round(o.canvasW * 0.017)}px">${o.subhead}</div>` : ''}
      </div>
      <div style="position:absolute;left:46%;top:30%;
        transform:perspective(2600px) rotateY(-18deg) scale(${scale})">
        ${frame(o.src, o.screenW, o.screenH)}
      </div>
    </div></body></html>`;
}

/** Flat multi-panel (desktop): full-bleed shot with a caption band on top. */
export function multipanelFlat(o: {
  src: string; w: number; h: number; headline: string;
}): string {
  const bandH = Math.round(o.h * 0.16);
  return `<!doctype html><html><body style="margin:0">
    <div style="width:${o.w}px;height:${o.h}px;background:${gradient(120)};
      display:flex;flex-direction:column;align-items:center">
      <div style="height:${bandH}px;display:flex;align-items:center;
        font-family:${FONT};color:#fff;font-weight:700;
        font-size:${Math.round(o.w * 0.026)}px">${o.headline}</div>
      <img src="${o.src}" style="width:${Math.round(o.w * 0.9)}px;
        border-radius:14px;box-shadow:0 30px 90px rgba(0,0,0,.4)"/>
    </div></body></html>`;
}
```

- [ ] **Step 2: Type-check**

Run: `cd apps/plot/screenshots && npx tsc --noEmit -p tsconfig.json`
Expected: no type errors.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/screenshots/compose/templates.ts
git commit -m "feat(screenshots): HTML/CSS compose templates"
```

---

## Task 11: Compositor (`compose.ts`)

**Files:**
- Create: `apps/plot/screenshots/compose/compose.ts`

Loads each raw capture as a data URL, renders the right template with Playwright, and writes store PNGs at the exact manifest resolution — slicing the hero into its two slots.

- [ ] **Step 1: Write compose.ts**

```ts
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { chromium } from 'playwright';
import { PLANS, type PlatformPlan } from '../manifest.ts';
import { heroCanvas, heroClips } from '../geometry.ts';
import { phoneSlot, heroSpan, multipanelFlat } from './templates.ts';

const RAW = new URL('../raw/', import.meta.url).pathname;
const STORE = new URL('../store/', import.meta.url).pathname;

async function dataUrl(path: string): Promise<string> {
  const buf = await readFile(path);
  return `data:image/png;base64,${buf.toString('base64')}`;
}
async function save(path: string, buf: Buffer) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, buf);
}

async function renderPng(html: string, w: number, h: number,
    clip?: { x: number; y: number; width: number; height: number }) {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: w, height: h },
      deviceScaleFactor: 1 });
    await page.setContent(html, { waitUntil: 'networkidle' });
    return await page.screenshot(clip ? { clip } : {});
  } finally {
    await browser.close();
  }
}

// Native screen pixel size of each capture device (for frame aspect).
const SCREEN = {
  'iphone-6.9': { w: 1290, h: 2796 },
  'macos': { w: 2880, h: 1800 },
} as const;

export async function composePlatform(p: PlatformPlan) {
  for (const slot of p.slots) {
    const [W, H] = p.resolution;
    const dir = `${STORE}${p.store}/${p.platform}`;
    const raw = `${RAW}${p.platform}/${slot.scene}-${slot.mode}.png`;
    const src = await dataUrl(raw);
    const sc = SCREEN[p.platform];

    if (slot.framing === 'phone-hero-span') {
      const [cw, ch] = heroCanvas(p.resolution);
      const html = heroSpan({ src, canvasW: cw, canvasH: ch,
        screenW: sc.w, screenH: sc.h, headline: slot.headline, subhead: slot.subhead });
      const clips = heroClips(p.resolution);
      for (let i = 0; i < slot.slots.length; i++) {
        const png = await renderPng(html, cw, ch, clips[i]);
        await save(`${dir}/${String(slot.slots[i]).padStart(2, '0')}-${slot.scene}.png`, png);
      }
    } else if (slot.framing === 'phone') {
      const html = phoneSlot({ src, w: W, h: H, screenW: sc.w, screenH: sc.h,
        headline: slot.headline, subhead: slot.subhead });
      const png = await renderPng(html, W, H);
      await save(`${dir}/${String(slot.slots[0]).padStart(2, '0')}-${slot.scene}.png`, png);
    } else { // multipanel-flat
      const html = multipanelFlat({ src, w: W, h: H, headline: slot.headline });
      const png = await renderPng(html, W, H);
      await save(`${dir}/${String(slot.slots[0]).padStart(2, '0')}-${slot.scene}.png`, png);
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const only = process.argv[2];
  for (const p of PLANS) {
    if (only && p.platform !== only) continue;
    await composePlatform(p);
    console.log(`composed ${p.platform}`);
  }
}
```

- [ ] **Step 2: Type-check**

Run: `cd apps/plot/screenshots && npx tsc --noEmit -p tsconfig.json`
Expected: no type errors (Playwright types resolve from `apps/plot/node_modules`).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/screenshots/compose/compose.ts
git commit -m "feat(screenshots): Playwright compositor with hero slicing"
```

---

## Task 12: Orchestrator + package wiring

**Files:**
- Create: `apps/plot/screenshots/orchestrate.ts`
- Modify: `apps/plot/package.json`

- [ ] **Step 1: Declare devDeps + script**

Edit `apps/plot/package.json` — add:
```json
  "devDependencies": {
    "playwright": "^1.49.0",
    "tsx": "^4.19.2",
    "@types/node": "^22.10.0"
  },
  "scripts": {
    "screenshots": "tsx screenshots/orchestrate.ts"
  }
```
(Merge into the existing `scripts` object; keep the existing entries.)

Run: `pnpm install` (repo root) and `cd apps/plot && npx playwright install chromium`.

- [ ] **Step 2: Write orchestrate.ts**

```ts
import { execFileSync } from 'node:child_process';
import { PLANS, capturesFor } from './manifest.ts';
import { dartArgs } from './launch-args.ts';
import { composePlatform } from './compose/compose.ts';

const CAPTURE: Record<string, string> = {
  'iphone-6.9': new URL('./capture/ios.sh', import.meta.url).pathname,
  'macos': new URL('./capture/macos.sh', import.meta.url).pathname,
};
const RAW = new URL('./raw/', import.meta.url).pathname;
const REPO = new URL('../../../', import.meta.url).pathname;

function seed() {
  execFileSync('pnpm', ['gen-seed', '--apply', 'libs/db/seeds/margot.yaml'],
    { cwd: REPO, stdio: 'inherit' });
}

async function main() {
  const only = process.argv[2];           // optional platform filter
  const recapture = process.argv.includes('--recapture');
  seed();
  for (const p of PLANS) {
    if (only && only !== '--recapture' && p.platform !== only) continue;
    for (const c of capturesFor(p)) {
      const out = `${RAW}${p.platform}/${c.scene}-${c.mode}.png`;
      execFileSync('bash', [CAPTURE[p.platform], c.scene, c.mode, out,
        ...dartArgs(c.scene, c.mode, p.platform)], { stdio: 'inherit' });
    }
    await composePlatform(p);
    console.log(`done ${p.platform}`);
  }
}
await main();
```

- [ ] **Step 3: Commit**

```bash
git add apps/plot/package.json apps/plot/screenshots/orchestrate.ts pnpm-lock.yaml
git commit -m "feat(screenshots): orchestrator + package wiring"
```

---

## Task 13: End-to-end run + acceptance

**Files:** none (verification + output commit)

- [ ] **Step 1: Run the iPhone slice**

Run: `cd apps/plot && pnpm screenshots iphone-6.9`
Expected: `screenshots/raw/iphone-6.9/{S1-light,S2-light}.png` captured; `screenshots/store/app-store/iphone-6.9/{01-S1,02-S1,03-S2}.png` composed.

- [ ] **Step 2: Run the Mac slice**

Run: `cd apps/plot && pnpm screenshots macos`
Expected: `screenshots/store/app-store/macos/{01-S1,02-S2}.png` composed.

- [ ] **Step 3: Verify acceptance criteria**

```bash
cd apps/plot/screenshots/store/app-store
for f in iphone-6.9/*.png; do sips -g pixelWidth -g pixelHeight "$f"; done   # expect 1290x2796
for f in macos/*.png;     do sips -g pixelWidth -g pixelHeight "$f"; done    # expect 2880x1800
```
Open `iphone-6.9/01-S1.png` and `02-S1.png` side by side and confirm:
- the brand gradient is **continuous across the slot 1↔2 seam**;
- the status-bar clock reads **8:32**, chrome is clean (no scrollbars/debug banner);
- captions are legible at thumbnail scale;
- S2 shows the half-typed reply with a visible caret;
- the Mac shots show the real multi-panel layout, flat.

Record results explicitly (per superpowers:verification-before-completion — paste the `sips` output and state pass/fail for each visual check).

- [ ] **Step 4: Commit the store assets**

```bash
git add apps/plot/screenshots/store
git commit -m "feat(screenshots): vertical-slice store assets (S1+S2, iPhone+Mac)"
```

- [ ] **Step 5: Finalize**

Run `/finalize` (lint changed packages, docs). Add a `docs/updates.md` entry only if user-facing (this is tooling — likely skip). Confirm `cd apps/plot && flutter analyze` is clean for the modified Dart files.

---

## Self-review notes (author)

- **Spec coverage:** scene hooks (Tasks 1–6), manifest (7), capture iOS+Mac (8,9), composition incl. spanning hero + captions + frames (10,11), orchestrator/CLI (12), acceptance criteria (13) — all map to the design's five layers + first deliverable.
- **Deferred (per design, intentionally not in this plan):** S3–S12, iPad/Android, Windows, store upload, motion, real photographic device-frame PNG (CSS frame used for the slice).
- **Known follow-ups surfaced during the slice** (handle in a later plan): swap the CSS device frame for a photoreal PNG; source the dark-mode shots for the broader set; CI guard for scene drift.
</content>

---

## Execution learnings (vertical slice — done)

The S1+S2 / iPhone+Mac slice is implemented and verified live. Things that
differed from the original plan and matter for scaling to S3–S12 / Android /
iPad / Windows:

- **iOS can't use `--dart-entrypoint-args`.** They don't reach Dart `main(args)`
  on iOS/Android. `CliArgs` now also reads `--dart-define` (`SS_USER`,
  `SS_PASSWORD`, `SS_FROZEN_TIME`, `SS_MODE`, `SS_PROFILE`, `SS_SCENE`) via
  `String.fromEnvironment`; `ios.sh` translates the config to `--dart-define`.
  Trade-off: a `--dart-define` change forces a rebuild, so mobile re-captures
  are slower than desktop (which stays on entrypoint args).
- **Suppress the OS notification prompt.** It overlays the captured UI. We skip
  Firebase init in scene mode (`main.dart`) and early-return from
  `NotificationService.start` when a scene is active. A prompt left unanswered
  becomes a *SpringBoard* alert that survives app uninstall — clear it with
  `xcrun simctl erase <udid>` if one gets stuck.
- **Fresh install per iOS capture.** Reinstalling over an existing container
  leaves stale Clerk auth state that intermittently breaks sign-in on the next
  scene. `ios.sh` now uninstalls before each run.
- **macOS capture must use the window ID** (`screencapture -l`), not a region —
  region capture grabs terminal/other-display bleed on multi-display setups,
  and there may be a developer's own Plot instance running. We select the
  1440×900 window the scene pins.
- **Multi-panel must be resolved deterministically**, not by reading the live
  `LayoutBloc.multiPanel` once (it lags the launch window resize). Phones =
  single, desktop = multi, waiting for the layout to settle.
- **tsx transforms the `.ts` entrypoints as CJS** → no top-level await; entry
  blocks use an async IIFE.

### Known polish items (deferred)
- **macOS captured at 1×** (1440×900) because the window opened on a non-Retina
  external display. 1440×900 is an accepted App Store size, but for 2880×1800
  pin the window onto the Retina display before capture.
- **Device frame is CSS-drawn**, not a photoreal PNG — fine for the slice;
  swap in a real iPhone Pro frame asset for production polish.
- **S2 shows the iOS keyboard** (a natural result of the focused composer). Keep
  for "active reply" energy, or dismiss the keyboard before capture if a cleaner
  thread view is preferred.

---

## Scale-out learnings (Apple + Google Play complete)

Beyond the vertical slice, the set was scaled to all scenes (S1–S12) and four
device types. Status: **iPhone (8), iPad (5), macOS (5), Android phone (7),
Android tablet (4) = 29 store assets, committed.**

Key additions/fixes:

- **Captions live in `manifest.ts`** (transcribed from `store-listings.md`) and
  are applied at compose time over already-captured raws. Re-running
  `compose.ts <platform>` after a copy change is ~seconds and needs **no
  re-capture**. Seed-data fixes DO need re-capture of the affected scenes.
- **Thread-open is via inner-router push** (`PrioritiesShell.openThread`), not a
  `PriorityRoute` child: navigating to an already-current focus drops the child,
  and the multi-panel inner stack seeds `PriorityOnlyRoute` (transient) then
  `NewThreadRoute` (final). `_pushThreadWhenInnerReady` waits for the PLATFORM's
  *settled* default (`NewThreadRoute` multi / `PriorityOnlyRoute` single) before
  pushing, or the push is clobbered ~2ms later (root-caused via the route log).
- **Modal scenes (S8 Connections, S11 ⌘K) need a context UNDER `ModalProvider`** —
  resolve from `FocusManager.instance.primaryFocus?.context`, not the root
  navigator. `SelectModal.open` additionally **pre-fetches its items and bails
  if that context unmounts during the await**, so S8 must `ManageConnections.prewarm()`
  first and open with `keepCache: true`.
- **Notification prompt suppression:** skip Firebase init in scene mode
  (`main.dart`) and early-return `NotificationService.start` when a scene is
  active. A prompt left unanswered becomes a SpringBoard alert surviving
  uninstall — clear with `xcrun simctl erase`.
- **Multi-panel resolution** uses the real width-driven `LayoutBloc.multiPanel`
  (phone single / iPad+desktop multi), polling on desktop for the post-resize
  settle.
- **Larger layouts** per feedback: phone device 0.86 width bleeding off the
  bottom; multipanel-flat is fit-to-area (handles 16:10 macOS and 4:3 iPad) with
  a slim caption band.
- **iOS sim orientation is non-deterministic via `simctl`** (no rotate; Cmd+Right
  via osascript ACCUMULATES across runs). `ipad.sh` erases the sim first
  (portrait baseline) → Cmd+Right → `sips -r 90` (simctl captures the
  portrait-native framebuffer). **Android rotates cleanly via `adb`
  user_rotation** (screencap follows it) — except the Galaxy Tab's natural
  orientation differs (see deferred).
- **Android:** `android.sh` (boot emulator, demo-mode 8:32 status bar,
  `--dart-define` config, `adb screencap`, fresh install per scene). First-view
  note sync is slow → 8s post-ready wait. Native (Rust `super_native_extensions`)
  builds are slow; a killed build forces a multi-ABI recompile. `android-share.sh`
  captures S12 (OS share sheet listing Plot) — an OS-level `am start -a SEND`
  flow, not an in-app scene.
- **Emulator ANRs under host load:** "Process system isn't responding" recurs
  when the host is overloaded (long sessions, concurrent sims). Mitigate by
  shutting down unused sims and cold-restarting the emulator.

### Android tablet (Galaxy Tab S8 Ultra) — done
Captured S1/S2/S7/S8 in landscape (2560×1600) on a fresh host. Both deferred
issues are resolved in `android.sh`:
1. **Landscape (the quirk):** the Tab's `user_rotation`→orientation mapping is
   the same as a phone (rot 1 = landscape), but the **Flutter app reverts to the
   emulator's portrait sensor default on cold start** despite a pre-launch
   rotation, so a hardcoded pre-launch index isn't enough. Fix: a new
   `ensure_orientation land|port` helper runs *after* `SCENE_READY` — it rotates
   the live activity (which has `configChanges=orientation`, so it reflows
   without recreation) and **verifies the real `screencap` aspect**, trying
   rotation candidates `1 3 0 2` (land) / `0 2 1 3` (port) until the framebuffer
   actually matches. Device-agnostic (works for phone + tablet); the captured
   PNG aspect is sanity-printed at the end.
2. **ANR:** `settings put global hide_error_dialogs 1` suppresses the
   "isn't responding" dialog so it can never overlay a capture. Combined with a
   clean cold boot (`-no-snapshot`) and a single running emulator, no ANR
   recurred.
Capture with: `SS_AVD=Galaxy_Tab_S8_Ultra SS_PORT=5556 SS_LANDSCAPE=1 android.sh <scene> …`.
(`orchestrate.ts` still drives only iPhone/macOS; Android is run manually per
the line above, then `compose.ts android-tablet`.)

### Out of scope still
Microsoft Store / Windows (needs a VM); the optional motion previews.
