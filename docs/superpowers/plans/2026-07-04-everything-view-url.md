# Everything View URL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the synthetic "Everything" feed a reserved, refresh-stable URL (`/p/everything`) so reloading or deep-linking to it stays on Everything instead of falling back to the scoped Inbox.

**Architecture:** Reserved route segment on the existing `/p/:priorityId` activity route. `PriorityWrapper` detects the sentinel before base58 parsing and mounts the same activity-feed page in Everything mode (null `priorityId`, `useDefault: true` for the Inbox draft-home, `setContext: false`). The mounted page establishes Everything mode at mount — mirroring how `_SearchView.initState` calls `setEverything(true)` — so the mode is encoded in the URL and survives refresh. The child thread-route tree and `_PriorityWrapperHost` are inherited unchanged.

**Tech Stack:** Flutter, flutter_bloc, auto_route, Drift. Dart tests via `flutter test`. Lint via `flutter analyze`.

## Global Constraints

- Only `flutter/widgets.dart` and `forui/forui.dart` UI imports — never `flutter/material.dart`.
- Strict typing (`strict-casts`, `strict-inference`, `strict-raw-types`). `flutter analyze` must be clean before every commit.
- Bloc only in pages/commands, not widgets.
- UI text sentence case.
- Reserved segment value is the literal string `everything` (10 chars; never collides with a ~22-char base58 priority id).
- All commands run from the worktree: `/Users/kris.braun/code/plot/.claude/worktrees/everything-view-url`. Flutter commands run from `apps/plot` there.
- Do NOT run `dart format`.
- The Everything–Inbox route-clobber guard (`PriorityBloc.shouldApplyRoutePrioritySwitch`) is already committed on this branch and MUST be retained.

---

### Task 1: Reserved segment constant + pure route-target decision

Extract the "what does this route segment mean" decision into a pure, unit-testable function (mirrors the existing `PriorityBloc.shouldApplyWatchedContext` / `shouldApplyRoutePrioritySwitch` pattern). This is the seam Task 2 consumes.

**Files:**
- Modify: `apps/plot/lib/page/priority.dart` (add constant + helper near the top, above `PriorityWrapper` at line 44)
- Test: `apps/plot/test/page/priority_route_target_test.dart` (create)

**Interfaces:**
- Produces:
  - `const String kEverythingRouteSegment = 'everything';`
  - `PriorityRouteTarget parsePriorityRouteTarget(String segment)` returning a value with fields `bool everything`, `PriorityId? priorityId`, `bool invalid`.
  - `class PriorityRouteTarget` (Equatable) with those three fields and named constructors `PriorityRouteTarget.everything()`, `PriorityRouteTarget.focus(PriorityId id)`, `PriorityRouteTarget.invalid()`.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/page/priority_route_target_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/page/priority.dart';
import 'package:plot/store/store.dart' show PriorityId, Uuid;

void main() {
  group('parsePriorityRouteTarget', () {
    test('the reserved segment maps to Everything mode', () {
      final t = parsePriorityRouteTarget(kEverythingRouteSegment);
      expect(t.everything, isTrue);
      expect(t.priorityId, isNull);
      expect(t.invalid, isFalse);
    });

    test('a valid base58 id maps to a scoped focus', () {
      final id = PriorityId(Uuid.generate());
      final t = parsePriorityRouteTarget(id.toShortString());
      expect(t.everything, isFalse);
      expect(t.priorityId, id);
      expect(t.invalid, isFalse);
    });

    test('an unparseable segment is invalid', () {
      final t = parsePriorityRouteTarget('!!!not-base58!!!');
      expect(t.everything, isFalse);
      expect(t.priorityId, isNull);
      expect(t.invalid, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/page/priority_route_target_test.dart`
Expected: FAIL — `kEverythingRouteSegment` / `parsePriorityRouteTarget` / `PriorityRouteTarget` undefined.

- [ ] **Step 3: Write minimal implementation**

In `apps/plot/lib/page/priority.dart`, immediately above `@RoutePage(name: "PriorityRoute")` (line 44), add:

```dart
/// Reserved `/p/:priorityId` segment that opens the synthetic Everything feed
/// instead of a specific priority. A 10-char word can never collide with a
/// real (~22-char base58) priority id, and [PriorityWrapper] checks it before
/// base58 parsing.
const String kEverythingRouteSegment = 'everything';

/// What a `/p/:priorityId` segment resolves to. Pure so it can be unit-tested
/// without a router (see priority_route_target_test.dart), mirroring the
/// [PriorityBloc.shouldApplyWatchedContext] testable-decision pattern.
class PriorityRouteTarget {
  const PriorityRouteTarget._({
    required this.everything,
    required this.priorityId,
    required this.invalid,
  });

  /// The reserved Everything feed (no scoped priority).
  const PriorityRouteTarget.everything()
      : everything = true,
        priorityId = null,
        invalid = false;

  /// A scoped focus/Inbox.
  const PriorityRouteTarget.focus(PriorityId id)
      : everything = false,
        priorityId = id,
        invalid = false;

  /// An unparseable segment (e.g. a stale/malformed link).
  const PriorityRouteTarget.invalid()
      : everything = false,
        priorityId = null,
        invalid = true;

  final bool everything;
  final PriorityId? priorityId;
  final bool invalid;
}

/// Resolves a `/p/:priorityId` segment to a [PriorityRouteTarget]. The reserved
/// [kEverythingRouteSegment] wins before base58 parsing.
PriorityRouteTarget parsePriorityRouteTarget(String segment) {
  if (segment == kEverythingRouteSegment) {
    return const PriorityRouteTarget.everything();
  }
  final id = PriorityId.tryFromShortString(segment);
  return id == null
      ? const PriorityRouteTarget.invalid()
      : PriorityRouteTarget.focus(id);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/page/priority_route_target_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/page/priority.dart test/page/priority_route_target_test.dart`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/page/priority.dart apps/plot/test/page/priority_route_target_test.dart
git commit -m "feat(feed): add reserved Everything route segment + pure target parser"
```

---

### Task 2: Mount the Everything feed for the reserved segment

Wire `PriorityWrapper` → `_PriorityWrapperHost` → `PriorityBlocProvider` → `PriorityPage` so `/p/everything` cold-mounts in Everything mode. Relax the non-null `priorityId` contract (both live consumers already tolerate null) and add the establish-on-mount hook that makes refresh land in Everything.

**Files:**
- Modify: `apps/plot/lib/page/priority.dart`
  - `PriorityWrapper.wrappedRoute` (lines 52-73)
  - `_PriorityWrapperHost` (lines 76-83) + `_build` (lines 164-214)
  - `PriorityPage` (lines 778-785) + `_PriorityPageState.initState`

**Interfaces:**
- Consumes: `kEverythingRouteSegment`, `parsePriorityRouteTarget`, `PriorityRouteTarget` (Task 1).
- Produces:
  - `_PriorityWrapperHost({required String priorityIdString, required PriorityId? priorityId, bool everything})`.
  - `PriorityPage({PriorityId? priorityId, bool everything, Key? key})`.

- [ ] **Step 1: `PriorityWrapper.wrappedRoute` routes the sentinel to Everything mode**

Replace the body of `wrappedRoute` (lines 53-73) with:

```dart
  @override
  Widget wrappedRoute(BuildContext context) {
    final target = parsePriorityRouteTarget(priorityIdString);
    if (target.invalid) {
      // Invalid base58 priority id (e.g. /p/login from a stale or
      // malformed link). Redirect to the user's default landing instead
      // of crashing in the parser.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        context.router.replaceAll([const RootRoute()]);
      });
      return const SizedBox.shrink();
    }
    // Wrap the subtree in a StatefulWidget so the inner AutoRouter's
    // GlobalKey lives on State and survives `wrappedRoute` rebuilds. That
    // way switching priorities flips this widget's `priorityId` prop
    // through `didUpdateWidget` instead of remounting the whole tree.
    //
    // For the reserved Everything segment there is no scoped priority: the
    // host mounts the feed in Everything mode (priorityId null), and the feed
    // resolves the default Inbox as its draft home.
    return _PriorityWrapperHost(
      priorityIdString: priorityIdString,
      priorityId: target.priorityId,
      everything: target.everything,
    );
  }
```

(`this.priorityId` on `PriorityWrapper` at line 47/50 becomes unused; delete the field and the initializer so analyze stays clean — keep only `priorityIdString`.)

Update the constructor (lines 46-50) to:

```dart
  PriorityWrapper({@PathParam("priorityId") required this.priorityIdString});

  final String priorityIdString;
```

- [ ] **Step 2: `_PriorityWrapperHost` accepts a nullable priorityId + everything flag**

Replace lines 76-83:

```dart
class _PriorityWrapperHost extends StatefulWidget {
  const _PriorityWrapperHost({
    required this.priorityIdString,
    required this.priorityId,
    this.everything = false,
  });

  final String priorityIdString;

  /// Null in the reserved Everything view (no scoped priority).
  final PriorityId? priorityId;

  /// Whether this is the synthetic Everything feed rather than a scoped focus.
  final bool everything;
```

- [ ] **Step 3: `_build` mounts the provider/page in Everything mode when there is no scoped priority**

Change `_build` (line 164) signature and body. Replace lines 164-169:

```dart
  Widget _build(BuildContext context, PriorityId? priorityId) {
    final everything = widget.everything;
    return PriorityBlocProvider(
      // Everything has no scoped priority: load the default Inbox as the
      // draft home (the `useDefault` path, as the Search feed does) and do
      // not publish a scoped context to NowBloc. A scoped focus loads its id.
      priorityId: everything ? null : priorityId,
      useDefault: everything,
      setContext: !everything,
      child: _PriorityCommandScope(
        child: _PriorityShortcutsProvider(
          priorityId: priorityId,
```

And update the two remaining `priorityId` references inside `_build`:
- line 192 `middle: PriorityPage(priorityId: priorityId),` →
  `middle: PriorityPage(priorityId: priorityId, everything: everything),`
- line 162 `Widget build(BuildContext context) => _build(context, widget.priorityId);` stays (now passes `PriorityId?`).

- [ ] **Step 4: `PriorityPage` accepts nullable priorityId + everything, and establishes Everything on mount**

Replace lines 778-785:

```dart
class PriorityPage extends StatefulWidget {
  const PriorityPage({this.priorityId, this.everything = false, super.key});

  /// Null in the reserved Everything view.
  final PriorityId? priorityId;

  /// Whether this page is the synthetic Everything feed. When true it
  /// establishes Everything mode on mount (see [initState]).
  final bool everything;

  @override
  State<PriorityPage> createState() => _PriorityPageState();
}
```

Add to `_PriorityPageState` an `initState` override (or extend the existing one if present — search for `void initState` in the class and merge). At the END of initState add:

```dart
    // Cold-load / refresh on /p/everything: nothing set the Everything flag
    // yet, so establish it here — exactly as _SearchView.initState calls
    // setEverything(true) for the spanning search feed. In-app focus→Everything
    // is already handled up front by ChangeCurrentPriority.everything + the
    // NowBloc.everything mirror, and this page is not remounted on that path,
    // so this runs only on a fresh Everything mount.
    if (widget.everything) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Null context + everything flag on NowBloc (drives sidebar highlight);
        // setEverything(true) flips the bloc to the unscoped flat feed and
        // re-aims the draft at the Inbox fallback.
        context.read<NowBloc>().setContext(null, everything: true);
        context.read<PriorityBloc>().setEverything(true);
      });
    }
```

Fix the line-1164 scroll-key fallback (now nullable): `state.activeTabContext?.id ?? widget.priorityId` is already valid with a nullable `widget.priorityId` (the PageStorageKey interpolation tolerates null). No change needed, but verify it analyzes.

- [ ] **Step 5: Analyze the whole app**

Run: `cd apps/plot && flutter analyze lib/page/priority.dart lib/page/agenda.dart lib/page/search.dart`
Expected: `No issues found!` (agenda/search also construct `PriorityBlocProvider`/`PriorityPage`; confirm the nullable/`everything` defaults don't break them — agenda passes `priority:` and never `PriorityPage`; search passes `useDefault`).

If analyze flags other `PriorityPage(priorityId:)` call sites now needing named args, they already use named `priorityId:` so they are unaffected by the added optional `everything`.

- [ ] **Step 6: Run existing priority tests (no regressions)**

Run: `cd apps/plot && flutter test test/page/priority_route_target_test.dart test/state/priority_everything_context_test.dart test/state/everything_entry_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "feat(feed): mount Everything feed for the reserved /p/everything segment"
```

---

### Task 3: Navigate Everything to the reserved segment

Point `ChangeCurrentPriority.everything()` at `/p/everything` instead of the resolved Inbox id, so entering Everything and refreshing it share one URL.

**Files:**
- Modify: `apps/plot/lib/command/priority.dart` (target resolution at lines 181-197; import the constant)
- Test: `apps/plot/test/command/everything_route_target_test.dart` (create) — covers the extracted target helper.

**Interfaces:**
- Consumes: `kEverythingRouteSegment` (Task 1).
- Produces: `String everythingCommandTarget({required bool everything, required Priority? priority, required Priority? defaultInbox})` — pure helper returning the route target segment. Used by `run()` and unit-tested.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/command/everything_route_target_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/priority.dart';
import 'package:plot/page/priority.dart' show kEverythingRouteSegment;
import 'package:plot/store/store.dart';

void main() {
  Priority focus(String title, {bool isInbox = false}) => Priority.fromStore(
        PriorityRow(
          id: Uuid.generate(),
          createdBy: Uuid.generate(),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          title: title,
          path: Path(title.toLowerCase()),
          order: const Order(0),
          unread: false,
          role: 'member',
          isInbox: isInbox,
          isFyi: false,
          attentionWindowSet: false,
          seeWithinSet: false,
          earlyNotificationsEnabledSet: false,
          notifyWindowSet: false,
          sendWindowSet: false,
        ),
        draft: true,
      );

  test('Everything targets the reserved segment, not the Inbox id', () {
    final inbox = focus('Inbox', isInbox: true);
    final target = everythingCommandTarget(
      everything: true,
      priority: null,
      defaultInbox: inbox,
    );
    expect(target, kEverythingRouteSegment);
  });

  test('a scoped focus targets its own id', () {
    final work = focus('Work');
    final target = everythingCommandTarget(
      everything: false,
      priority: work,
      defaultInbox: null,
    );
    expect(target, work.id.toShortString());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/command/everything_route_target_test.dart`
Expected: FAIL — `everythingCommandTarget` undefined.

- [ ] **Step 3: Add the helper and use it in `run()`**

In `apps/plot/lib/command/priority.dart`, add the import near the other `package:plot` imports:

```dart
import 'package:plot/page/priority.dart' show kEverythingRouteSegment;
```

Add the pure helper (top-level, near `ChangeCurrentPriority`):

```dart
/// The `/p/:priorityId` segment a priority navigation should target. The
/// synthetic Everything feed uses the reserved [kEverythingRouteSegment] so its
/// URL is stable across refresh; every ordinary navigation uses the focus's own
/// id. Returns null only when Everything is requested but no default Inbox is
/// loaded yet (nothing to navigate to).
String? everythingCommandTarget({
  required bool everything,
  required Priority? priority,
  required Priority? defaultInbox,
}) {
  if (everything && priority == null) {
    return kEverythingRouteSegment;
  }
  return priority?.id.toShortString() ?? defaultInbox?.id.toShortString();
}
```

Replace the target-resolution block in `run()` (lines 181-197) with a call to it:

```dart
    // For the Everything entry the route target is the reserved
    // `/p/everything` segment (a stable, refresh-safe URL); for ordinary focus
    // navigation it is the tapped focus itself.
    final targetPriorityIdString = everythingCommandTarget(
      everything: everything,
      priority: priority,
      defaultInbox: everything && priority == null
          ? context.read<PrioritiesBloc>().state.root
          : null,
    );

    if (targetPriorityIdString == null) {
      // No inbox priority loaded yet — nothing to navigate to.
      return const CommandDone();
    }
```

(The `defaultInbox` argument now only matters if the reserved segment is ever swapped back to an id; passing root keeps the null-safety identical to today.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/command/everything_route_target_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/priority.dart test/command/everything_route_target_test.dart`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/command/priority.dart test/command/everything_route_target_test.dart
git commit -m "feat(feed): navigate Everything to the reserved /p/everything URL"
```

---

### Task 4: End-to-end verification + retained guard

Confirm the refresh-stable behavior in the running app (the real acceptance criterion — a full-route widget test needs NowBloc + Store + identity + router and is disproportionately heavy), and confirm the guard + its tests still pass.

**Files:**
- None modified (verification only). The `docs/updates.d/fix-everything-view-showing-inbox-lwsm2b.md` fragment already exists; add a second bullet for the URL if desired.

- [ ] **Step 1: Full analyze + relevant test suite**

Run:
```bash
cd apps/plot && flutter analyze
flutter test test/page/priority_route_target_test.dart \
  test/command/everything_route_target_test.dart \
  test/state/priority_everything_context_test.dart \
  test/state/everything_entry_test.dart \
  test/state/priority_switch_fallback_test.dart \
  test/page/new_thread_everything_default_test.dart
```
Expected: analyze clean; all tests PASS.

- [ ] **Step 2: Run the app and verify refresh stability**

Use the `run-app` skill to launch Plot.app for this worktree. Then, via dart-mcp / manual:
1. Open a focus (not the Inbox). Tap **Everything** in the sidebar. Confirm the feed is the flat, unsectioned all-threads list (not the scoped Inbox), and the URL segment is `/p/everything`.
2. Refresh / cold-restart at `/p/everything` (web: reload the page). Confirm it lands back on **Everything** (flat unscoped feed, sidebar highlights Everything), NOT the scoped Inbox.
3. From Everything, tap a real focus. Confirm it scopes correctly and the URL becomes `/p/<focusId>`.
4. From Everything, open a thread. Confirm `/p/everything/:threadId` opens the thread inline (multi-panel) and Back returns to the Everything feed.

Expected: all four behaviors hold. If step 2 fails (lands on Inbox), the establish-on-mount hook (Task 2 Step 4) is not firing — debug there before proceeding.

- [ ] **Step 3: Add the URL bullet to the updates fragment**

Append to `docs/updates.d/fix-everything-view-showing-inbox-lwsm2b.md` under `### Fixes`:

```markdown
- Everything now has its own link, so refreshing or reopening the page keeps you on Everything.
```

- [ ] **Step 4: Commit**

```bash
git add docs/updates.d/fix-everything-view-showing-inbox-lwsm2b.md
git commit -m "docs(feed): note Everything's refresh-stable URL in updates"
```

- [ ] **Step 5: Finalize**

Run the `/finalize` checklist (lint, backwards-compat, error capture, docs). Everything is a client-only routing change (no schema, no worker, no `public/` submodule), so most items are N/A; confirm `flutter analyze` is clean and the updates fragment is present.

---

## Self-Review

**Spec coverage:**
- Reserved constant → Task 1. ✓
- `PriorityWrapper` sentinel detection → Task 2 Step 1. ✓
- `_PriorityWrapperHost` everything flag + nullable priorityId → Task 2 Steps 2-3. ✓
- Mount via `useDefault`/`setContext: false` → Task 2 Step 3. ✓
- Establish Everything at mount (refresh-safe hook) → Task 2 Step 4. ✓
- Command targets sentinel → Task 3. ✓
- Guard retained → Task 4 (retained; never removed). ✓
- Testing: sentinel mapping (Task 1), command target (Task 3), refresh round-trip + focus↔Everything + thread-open (Task 4). ✓

**Placeholder scan:** No TBD/TODO; every code step shows the code. Task 4 is verification (run-app acceptance), not a code placeholder.

**Type consistency:** `PriorityRouteTarget` fields (`everything`, `priorityId`, `invalid`) consistent across Tasks 1-2. `_PriorityWrapperHost` / `PriorityPage` gain `everything` (default false) and nullable `priorityId` consistently. `everythingCommandTarget` signature identical in Task 3 helper and test. `kEverythingRouteSegment` used verbatim in Tasks 1-3.

**Known heaviness (honest):** Tasks 2-3's core is Flutter route wiring that only fully exercises end-to-end; the unit-testable decisions are extracted (`parsePriorityRouteTarget`, `everythingCommandTarget`) and covered, with the route-level behavior verified via run-app in Task 4 rather than a heavyweight full-router widget test.
