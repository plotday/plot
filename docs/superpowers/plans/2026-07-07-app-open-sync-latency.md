# App-Open Sync Catch-Up Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Updated threads visible ~1-2s after reopening the app (down from ~1.5-4s+), by removing a backfill bug, parallelizing the catch-up pulls, and reusing HTTP connections.

**Architecture:** All changes are in the Flutter client (`apps/plot/`) against existing `/sync/*` endpoints. The catch-up sweep (`SyncOrchestrator.syncAll`) switches from dependency-topo levels to two explicit waves (thread+note first); the thread/note entity pull functions parallelize their internal sequential pulls; a recurring agenda/feed backfill bug is removed and replaced by an on-demand pull for the Everything view; `api.dart` gets a shared keep-alive HTTP client.

**Tech Stack:** Flutter/Dart, Drift (SQLite), package:http, flutter_test with in-memory `NativeDatabase`.

**Spec:** `docs/superpowers/specs/2026-07-06-app-open-sync-latency-design.md` (committed in Task 1 — read it before starting any task).

## Global Constraints

- Client-only: NO changes under `workers/`, `libs/db/`, or `public/`. No server/protocol changes.
- Initial-sync behavior must not change: `syncInitialCritical` / `syncInitialDeferred` keep topo ordering; fresh-device seeding (agenda/feed/links) is preserved.
- All work in a worktree (this is multi-file behavioral change); never switch the main repo's branch.
- Every task ends with `cd apps/plot && flutter analyze` clean (zero new issues) before commit.
- Flutter tests run as `cd apps/plot && flutter test <path>`. The full store suite is the regression baseline: `flutter test test/store`.
- Commit style: conventional commits, e.g. `fix(app): …` / `perf(app): …`, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `lib/store/sync_orchestrator.dart` is `part of 'store.dart'` — privates there are shared with `store.dart` but NOT visible to tests; anything tests need must be public or `@visibleForTesting`.
- In the test env no `Base`/auth singletons are registered, so ANY attempted HTTP call throws. "Completes normally" is therefore a valid "no network attempted" assertion; "throws" proves a code path tried the network.

---

### Task 1: Worktree, spec commit, baseline

**Files:**
- Create: `docs/superpowers/specs/2026-07-06-app-open-sync-latency-design.md` (copy from main repo — it is untracked there)

**Interfaces:**
- Produces: branch `app-open-sync-latency` in a worktree with green baseline.

- [x] **Step 1: Create worktree** via superpowers:using-git-worktrees, branch `app-open-sync-latency`. Known harness bug: if the native tool errors with a chdir-to-JSON-blob message, the worktree exists — `cd` into it manually and continue (see user CLAUDE.md skill addenda).

- [x] **Step 2: Copy the spec from the main repo** (it was written there untracked):

```bash
mkdir -p docs/superpowers/specs
cp /Users/kris.braun/code/plot/docs/superpowers/specs/2026-07-06-app-open-sync-latency-design.md docs/superpowers/specs/
```

- [x] **Step 3: Bootstrap the Flutter app for tests** (worktree hooks run pnpm install but not build_runner):

```bash
cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs
```

- [x] **Step 4: Baseline: analyze + store tests**

Run: `cd apps/plot && flutter analyze && flutter test test/store test/util test/state`
Expected: PASS (record any pre-existing failures — they are not yours to fix, but note them).

- [x] **Step 5: Commit the spec**

```bash
git add docs/superpowers/specs/2026-07-06-app-open-sync-latency-design.md
git commit -m "docs: add app-open sync catch-up latency design spec"
```

---

### Task 2: Remove the recurring agenda/feed backfill (bug fix)

`Thread.pullInitial()` (`apps/plot/lib/store/thread.dart:942-966`) runs on EVERY sync via the thread entity's pullFn (`sync_orchestrator.dart:153-156`). Its `initial: true` pulls no-op once initialized, but the trailing `pullAgenda(null)` / `pullActivityFeed(null)` are `pullTo`-based and never short-circuit (only the `noMore` "server exhausted" flag stops them), and the links pull at `thread.dart:945` is un-gated — so every `syncAll` AND every broadcast-driven thread `syncSubset` pulls another feed-history page (200 rows + 3 slice pulls) plus a redundant links pull.

**Files:**
- Modify: `apps/plot/lib/store/store.dart` (~line 1600, just above `pull()`)
- Modify: `apps/plot/lib/store/thread.dart:942` (`Thread.pullInitial`)
- Test: `apps/plot/test/store/thread_pull_initial_skip_test.dart` (create)

**Interfaces:**
- Produces: `Future<bool> Store.isEntityInitialized(String entity)` — true when the entity's `syncStates` row has `lastHorizon` or `pulledAt` set. Task 10's regression tests also rely on `pullInitial` early-returning.

- [x] **Step 1: Write the failing tests**

```dart
// apps/plot/test/store/thread_pull_initial_skip_test.dart
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Regression guard for the recurring-backfill bug: `Thread.pullInitial()`
/// must be a complete no-op once the store is initialized. Its agenda/feed
/// pullTo calls have no caught-up short-circuit, so before this guard every
/// sync (including every broadcast-driven thread sync) pulled another page
/// of feed history + slice pulls + a redundant links pull.
///
/// Test-env property used here: no Base/auth singletons are registered, so
/// ANY attempted HTTP call throws. `completes` == "no network attempted".
void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('initialized store: pullInitial makes no network calls', () async {
    // thread_associations is the LAST initial-gated entity pullInitial
    // seeds, so its presence proves a prior initial run completed.
    await store.into(store.syncStates).insert(
          SyncStatesCompanion.insert(
            entity: 'thread_associations',
            pulledAt: Value(DateTime.now().toUtc().microsecondsSinceEpoch),
          ),
        );

    await expectLater(Thread.pullInitial(), completes);

    // The agenda/feed cursors were not created — the backfill did not run.
    final agenda = await (store.select(store.syncStates)
          ..where((r) => r.entity.equals('agenda')))
        .getSingleOrNull();
    final feed = await (store.select(store.syncStates)
          ..where((r) => r.entity.equals('activity-feed')))
        .getSingleOrNull();
    expect(agenda, isNull);
    expect(feed, isNull);
  });

  test('fresh store: pullInitial still runs (attempts network)', () async {
    // No sync states seeded — the guard must NOT skip. The first pull
    // attempts HTTP, which throws in the test env, proving the body ran.
    await expectLater(Thread.pullInitial(), throwsA(anything));
  });

  test('isEntityInitialized reflects lastHorizon or pulledAt', () async {
    expect(await store.isEntityInitialized('threads'), isFalse);
    await store.into(store.syncStates).insert(
          SyncStatesCompanion.insert(entity: 'threads', lastHorizon: const Value(42)),
        );
    expect(await store.isEntityInitialized('threads'), isTrue);
  });
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `cd apps/plot && flutter test test/store/thread_pull_initial_skip_test.dart`
Expected: FAIL — `isEntityInitialized` undefined; first test attempts network and throws.

- [x] **Step 3: Implement**

In `store.dart`, just above `pull()` (~line 1600):

```dart
  /// True once [entity] has completed a pull — a seq horizon or legacy
  /// pulledAt stamp exists. Mirrors the "initialized" check inside [pull].
  Future<bool> isEntityInitialized(String entity) async {
    final state = await (select(syncStates)
          ..where((row) => row.entity.equals(entity)))
        .getSingleOrNull();
    return state?.lastHorizon != null || state?.pulledAt != null;
  }
```

In `thread.dart`, at the top of `pullInitial()` (before the links pull at :945):

```dart
  static Future<void> pullInitial() async {
    // Recurring syncs skip this method entirely — everything in it is
    // initial-only seeding. The seq pulls below are `initial:`-gated
    // (no-op once a cursor exists), but the agenda/feed pullTo calls and
    // the links baseline are NOT: they re-ran on every sync, paging ever
    // deeper into feed history (one 200-row page + 3 slice pulls per
    // sync, on every syncAll AND every broadcast-driven thread sync).
    // See docs/superpowers/specs/2026-07-06-app-open-sync-latency-design.md.
    //
    // Keyed on the LAST initial-gated entity seeded here so a crash midway
    // through a genuine initial run re-enters (idempotent) instead of
    // stranding the unseeded tail.
    if (await Store.get.isEntityInitialized('thread_associations')) return;

    // ...existing body unchanged (links baseline, threads/schedules/
    // associations initial pulls, pullAgenda(null), pullActivityFeed(null))...
  }
```

- [x] **Step 4: Run tests to verify they pass**

Run: `cd apps/plot && flutter test test/store/thread_pull_initial_skip_test.dart`
Expected: PASS (3 tests)

- [x] **Step 5: Analyze + full store suite**

Run: `cd apps/plot && flutter analyze && flutter test test/store`
Expected: clean / green (modulo pre-existing failures recorded in Task 1)

- [x] **Step 6: Commit**

```bash
git add apps/plot/lib/store/store.dart apps/plot/lib/store/thread.dart apps/plot/test/store/thread_pull_initial_skip_test.dart
git commit -m "fix(app): stop re-running agenda/feed backfill on every sync"
```

---

### Task 3: Everything view — on-demand global feed pull

The Everything view never triggers a server feed sync: `_pendingFeedSync = state.context` (`priority.dart:3925`) is null in Everything mode so `_firePendingFeedSync` no-ops (`:3940-3941`), and its scroll pagination (`fetchAllTabPage`) is pure local SQL. It only worked because the (now removed) background crawl kept deepening local history. Give it the same demand-driven path every focus has.

**Files:**
- Modify: `apps/plot/lib/state/priority.dart` — `_loadPriority` tail (~:3916-3931), `_firePendingFeedSync` (~:3939-3947), `_triggerActivityFeedSync` (~:4629-4695), `_fetchMoreAllTab` (~:1585-1656)
- Test: `apps/plot/test/store/global_feed_scope_test.dart` (create)

**Interfaces:**
- Consumes: `Thread.pullActivityFeed(PriorityId?, {bool archived})` — null id already means global scope (sync state entity `activity-feed`, from `ThreadsBase(syncName: 'activity-feed')` with null `filterName`).
- Produces: `_triggerActivityFeedSync(Priority? priorityToLoad)` accepts null = Everything/global.

- [x] **Step 1: Write the failing store-level test** (pins the global cursor name + noMore short-circuit the bloc code relies on):

```dart
// apps/plot/test/store/global_feed_scope_test.dart
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// The Everything view's on-demand pull uses the GLOBAL activity-feed
/// cursor: `pullActivityFeed(null)` must key sync state on entity
/// 'activity-feed' (no scope suffix) and must short-circuit WITHOUT any
/// network attempt once that cursor is marked noMore. (In the test env any
/// HTTP attempt throws, so `completes` proves the short-circuit.)
void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('ThreadsBase global feed scope maps to entity "activity-feed"', () {
    expect(ThreadsBase(syncName: 'activity-feed').fullName, 'activity-feed');
  });

  test('pullActivityFeed(null) respects global noMore without network', () async {
    await store.into(store.syncStates).insert(
          SyncStatesCompanion.insert(
            entity: 'activity-feed',
            noMore: const Value(true),
          ),
        );
    await expectLater(Thread.pullActivityFeed(null), completes);
  });
}
```

- [x] **Step 2: Run it**

Run: `cd apps/plot && flutter test test/store/global_feed_scope_test.dart`
Expected: PASS already (this pins existing behavior the new bloc code relies on — keep it as the regression anchor). If either test fails, STOP and re-read `Store.pullTo`'s `anyNoMore` logic before continuing.

- [x] **Step 3: Make `_triggerActivityFeedSync` scope-nullable** in `priority.dart` (~:4629). Replace the signature and the two scope-dependent lines; the loop structure stays identical:

```dart
  /// [priorityToLoad] == null → the Everything view's GLOBAL feed scope
  /// (sync-state entity 'activity-feed', no scope suffix).
  Future<void> _triggerActivityFeedSync(Priority? priorityToLoad) async {
    final archived = _effectiveShowArchived;
    // The sync cursor anchor keys on the priority id string (path-independent),
    // matching [ThreadsBase.filterName]. Null scope = global feed.
    final scopeKey = priorityToLoad?.id.toString();
    final suffix = archived ? '_archived' : '';
    final entityName = scopeKey == null
        ? 'activity-feed$suffix'
        : 'activity-feed:$scopeKey$suffix';
    ...
    for (var i = 0; i < 10; i++) {
      await Thread.pullActivityFeed(
        priorityToLoad?.id,
        archived: archived,
      );
      ...
```

Inside the loop, the "check local activity feed" read currently uses `Thread.get(priorityId: priorityToLoad.id, ...)`. Verify `Thread.get(priorityId: null, ...)` returns the unscoped feed; if it does, pass `priorityToLoad?.id`. If it does not (scoped-only), use the flat query instead — it is the exact query the Everything view renders from:

```dart
      final page = await Thread.fetchAllTabPage(
        priorityId: priorityToLoad?.id,
        archived: archived ? null : false,
        limit: _activityFeedLimit,
      );
      final localThreads = page.threads;
```

(`fetchAllTabPage` returns threads sorted `activity_at DESC`, so the existing `localThreads.last.activityAt` boundary comparison is unchanged.)

- [x] **Step 4: Queue the global sync when entering Everything.** In `_loadPriority` (~:3925) and `_firePendingFeedSync` (~:3939):

```dart
  // _loadPriority tail — was: _pendingFeedSync = state.context;
  _pendingFeedSync = state.context;
  _pendingFeedSyncEverything = state.everything;
```

```dart
  /// Focus whose activity-feed sync is owed once the feed has rendered (or
  /// the fallback timer fires). Overwritten by a newer [_loadPriority] —
  /// only the most recent focus is synced. When [_pendingFeedSyncEverything]
  /// is set the owed sync is the GLOBAL scope (Everything has no context).
  Priority? _pendingFeedSync;
  bool _pendingFeedSyncEverything = false;
  Timer? _pendingFeedSyncFallback;

  void _firePendingFeedSync() {
    final priority = _pendingFeedSync;
    final isEverything = _pendingFeedSyncEverything;
    _pendingFeedSync = null;
    _pendingFeedSyncEverything = false;
    _pendingFeedSyncFallback?.cancel();
    _pendingFeedSyncFallback = null;
    if (isClosed) return;
    if (priority == null && !isEverything) return;
    unawaited(_triggerActivityFeedSync(isEverything ? null : priority));
  }
```

**[Amended during execution — review round 2]** The interactive "enter Everything" path (`setEverything`) reuses the bloc and never calls `_loadPriority`; `setEverything(true)` must arm the pending-everything flag + fallback timer itself (fired via `_subscribeAllTabHead`'s first-emission hook), and `setEverything(false)`/`close()` must clear it.

- [x] **Step 5: Pull on deep scroll.** ~~In `_fetchMoreAllTab`'s `cursor == null` branch~~ **[Amended during execution — review round 2]** The `cursor == null` + `needsProbeBeyondHead()` combination is unreachable (a saturated head always has a non-null tailCursor). The bounded retry lives at the REAL exhaustion signal instead — the `!page.saturated` branch of the fetch loop: when `state.everything && !_activityFeedSyncNoMore && globalPulls < 3`, pull via `_triggerActivityFeedSync(null)`, advance the cursor via `page.nextCursor ?? cursor`, re-check `isClosed`/generation after the await, and `continue`; otherwise mark `_activeTabAppendsExhausted` as before.

- [x] **Step 6: Analyze + tests**

Run: `cd apps/plot && flutter analyze && flutter test test/store/global_feed_scope_test.dart test/state`
Expected: clean / green

- [x] **Step 7: Commit**

```bash
git add apps/plot/lib/state/priority.dart apps/plot/test/store/global_feed_scope_test.dart
git commit -m "feat(app): pull Everything feed history on demand"
```

---

### Task 4: Parallelize thread/note entity pulls + catch-up page size

**Files:**
- Modify: `apps/plot/lib/store/store.dart` (`BaseTable`, ~:228 — add `kCatchUpPageLimit`)
- Modify: `apps/plot/lib/store/thread.dart` — `ThreadsBase` ctor (:329-348), `SchedulesBase` ctor (:726), `Thread.pull()` (:968-979)
- Modify: `apps/plot/lib/store/link.dart` — `LinksBase` ctor (:386)
- Modify: `apps/plot/lib/store/thread_tags.dart` — `ThreadTagsBase` ctor (:15)
- Modify: `apps/plot/lib/store/note.dart` — `NotesBase` ctor (:128), `Note.pullUpdates()` (:481-485)
- Modify: `apps/plot/lib/store/note_tags.dart` — `NoteTagsBase` ctor (:10)
- Test: `apps/plot/test/store/catchup_page_limit_test.dart` (create)

**Interfaces:**
- Produces: `const int kCatchUpPageLimit = 500` (top-level in `store.dart`); optional `int limit` parameter on `ThreadsBase`, `LinksBase`, `SchedulesBase`, `ThreadTagsBase`, `NotesBase`, `NoteTagsBase` (default 200 — existing behavior everywhere else; feed/agenda `pullTo` slices are NOT changed).

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/store/catchup_page_limit_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Catch-up seq pulls use a 500-row page (server MAX_LIMIT is 1000) to cut
/// page-loop round trips after a long absence. Everything else — on-demand
/// feed/agenda slices, per-thread pulls — keeps the 200 default.
void main() {
  test('catch-up constant', () {
    expect(kCatchUpPageLimit, 500);
  });

  test('opt-in limit on high-churn Base classes', () {
    expect(ThreadsBase(limit: kCatchUpPageLimit).limit, 500);
    expect(LinksBase(limit: kCatchUpPageLimit).limit, 500);
    expect(SchedulesBase(limit: kCatchUpPageLimit).limit, 500);
    expect(ThreadTagsBase(limit: kCatchUpPageLimit).limit, 500);
    expect(NotesBase(limit: kCatchUpPageLimit).limit, 500);
    expect(NoteTagsBase(limit: kCatchUpPageLimit).limit, 500);
  });

  test('defaults unchanged', () {
    expect(ThreadsBase().limit, 200);
    expect(ThreadsBase(initial: true).limit, isNull); // unbounded initial
    expect(LinksBase().limit, 200);
    expect(NotesBase().limit, 200);
  });
}
```

- [ ] **Step 2: Run it**

Run: `cd apps/plot && flutter test test/store/catchup_page_limit_test.dart`
Expected: FAIL — `kCatchUpPageLimit` undefined, ctors reject `limit:`.

- [ ] **Step 3: Implement the constant + ctor params**

`store.dart`, above `BaseTable`:

```dart
/// Page size for incremental catch-up seq pulls on high-churn entities
/// (threads, notes, links, tags, schedules). The server clamps limits at
/// 1000; 500 cuts the page-loop round trips ~2.5× after a long absence and
/// changes nothing when fewer than 200 rows changed. On-demand pullTo
/// slices (feed/agenda scrolling) keep [BaseTable]'s 200 default.
const int kCatchUpPageLimit = 500;
```

Ctor pattern (repeat for each of the six classes — shown for `LinksBase`; `ThreadsBase` is the special case below):

```dart
class LinksBase extends BaseTable {
  LinksBase({this.priorityId, int limit = 200})
    : super(
        // ...existing args unchanged...
        limit: limit,
      );
```

`ThreadsBase` (`thread.dart:329-348`) — preserve the unbounded initial pull:

```dart
  ThreadsBase({
    this.priorityId,
    this.initial = false,
    String? syncName,
    String? sortBy,
    super.ascending = false,
    int limit = 200,
  }) : super(
         // ...existing args unchanged...
         limit: initial
             ? null // No limit for initial pull (active OR unread)
             : limit,
       );
```

- [ ] **Step 4: Run the test — PASS.** `cd apps/plot && flutter test test/store/catchup_page_limit_test.dart`

- [ ] **Step 5: Commit the page-size half**

```bash
git add apps/plot/lib/store/store.dart apps/plot/lib/store/thread.dart apps/plot/lib/store/link.dart apps/plot/lib/store/thread_tags.dart apps/plot/lib/store/note.dart apps/plot/lib/store/note_tags.dart apps/plot/test/store/catchup_page_limit_test.dart
git commit -m "perf(app): 500-row pages for catch-up seq pulls"
```

- [ ] **Step 6: Parallelize `Thread.pull()`** (`thread.dart:968-979`):

```dart
  static Future<void> pull() async {
    // All six cursors are independent — run them concurrently. Ordering is
    // a non-issue for correctness: rows are insertOrReplace upserts and all
    // cross-entity reads join at query time. A thread landing a beat before
    // its link briefly sorts by stale activity_at and self-heals on the
    // next watch-stream emit — already true across page boundaries today.
    // eagerError:false so one failing pull doesn't abort the other five;
    // the first error still propagates to the orchestrator's expected-error
    // handling after all complete.
    await Future.wait([
      Store.get.pull(Store.get.links, LinksBase(limit: kCatchUpPageLimit)),
      Store.get.pull(Store.get.threads, ThreadsBase(limit: kCatchUpPageLimit)),
      Store.get.pull(
        Store.get.schedules,
        SchedulesBase(limit: kCatchUpPageLimit),
      ),
      Store.get.pull(
        Store.get.threadTags,
        ThreadTagsBase(limit: kCatchUpPageLimit),
      ),
      Store.get.pull(Store.get.threadReactions, ThreadReactionsBase()),
      Store.get.pull(
        Store.get.threadAssociations,
        ThreadAssociationsBase(),
      ),
    ], eagerError: false);
  }
```

- [ ] **Step 7: Parallelize `Note.pullUpdates()`** (`note.dart:481-485`):

```dart
  static Future<void> pullUpdates() async {
    // Independent cursors, concurrent. Notes-before-tags only matters on
    // PUSH (the server rejects tags for unpersisted notes); on pull an
    // orphan tag row simply doesn't render until its note lands.
    await Future.wait([
      Store.get.pull(Store.get.notes, NotesBase(limit: kCatchUpPageLimit)),
      Store.get.pull(Store.get.noteTags, NoteTagsBase(limit: kCatchUpPageLimit)),
      Store.get.pull(Store.get.noteReactions, NoteReactionsBase()),
    ], eagerError: false);
  }
```

- [ ] **Step 8: Analyze + store suite** (no dedicated concurrency unit test — there is no HTTP mock seam at this layer; behavior is verified end-to-end in Task 10's SYNC_PERF_LOG run where the six pulls must log overlapping/near-identical start times).

Run: `cd apps/plot && flutter analyze && flutter test test/store`
Expected: clean / green

- [ ] **Step 9: Commit**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/lib/store/note.dart
git commit -m "perf(app): parallelize thread and note catch-up pulls"
```

---

### Task 5: Two-wave incremental pull ordering in syncAll

**Files:**
- Modify: `apps/plot/lib/store/sync_orchestrator.dart` — add wave list (~:206, after `allEntities`), rewrite `syncAll`'s pull phase (:361-375), delete `_computePullLevels` (:787-789)
- Test: `apps/plot/test/store/incremental_pull_waves_test.dart` (create)

**Interfaces:**
- Consumes: existing `SyncEntity` statics (`thread`, `note`, `actor`, …) and `allEntities` (14 entities, `sync_orchestrator.dart:191-206`).
- Produces: `@visibleForTesting List<List<SyncEntity>> SyncOrchestrator.incrementalPullWaves()`.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/store/incremental_pull_waves_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// syncAll's incremental catch-up pulls in two explicit waves instead of
/// dependency-topo levels: wave 1 = thread + note (what the user is waiting
/// for after reopening the app — updated threads land in round trip #1),
/// wave 2 = everything else (typically 0 rows on reopen). Safe because
/// incremental rows are idempotent insertOrReplace upserts, cross-entity
/// reads join at query time, and every pullFn still self-seeds via its own
/// pullInitial. Initial syncs keep strict topo ordering.
void main() {
  final waves = SyncOrchestrator.instance.incrementalPullWaves();

  test('exactly two waves; thread and note are wave 1', () {
    expect(waves, hasLength(2));
    expect(
      waves[0].map((e) => e.debugName).toSet(),
      {'thread', 'note'},
    );
  });

  test('waves cover allEntities exactly, no duplicates', () {
    final waveNames = waves.expand((w) => w).map((e) => e.debugName).toList();
    final allNames =
        SyncOrchestrator.allEntities.map((e) => e.debugName).toList();
    expect(waveNames.toSet(), allNames.toSet());
    expect(waveNames.length, allNames.length, reason: 'no entity twice');
  });

  test('critical initial path still topo-sorted (untouched)', () {
    // Guard that the wave change didn't leak into the initial path.
    expect(
      () => SyncOrchestrator.instance.criticalPullLevels(),
      returnsNormally,
    );
  });
}
```

- [ ] **Step 2: Run it** — Expected: FAIL — `incrementalPullWaves` undefined.

- [ ] **Step 3: Implement.** After `allEntities` (~:206):

```dart
  /// Pull order for incremental catch-up ([syncAll]) — replaces the
  /// dependency-topo levels there. On incremental sync, ordering is a
  /// latency decision, not a correctness one: rows are idempotent
  /// insertOrReplace upserts, cross-entity reads join at query time, and
  /// the UI skips missing referents until their row lands (watch streams
  /// re-emit — same as the documented unresolved-contact pattern). Wave 1
  /// is what the user is waiting for after reopening; wave 2 (typically
  /// all 0-row on reopen) follows. Initial syncs (syncInitialCritical /
  /// syncInitialDeferred) keep strict dependency ordering, and every
  /// entity's pullFn still runs its own pullInitial, so an uninitialized
  /// entity self-seeds regardless of wave order.
  static final _incrementalPullWaves = <List<SyncEntity>>[
    [thread, note],
    [
      actor,
      group,
      topic,
      teamUser,
      userSettings,
      role,
      priority,
      priorityBlock,
      twistInstance,
      channel,
      twistConnection,
      session,
    ],
  ];

  /// Exposed for tests to lock the wave composition.
  @visibleForTesting
  List<List<SyncEntity>> incrementalPullWaves() => _incrementalPullWaves;
```

In `syncAll` (:361-375), replace `final pullLevels = _computePullLevels();` with:

```dart
      final pullLevels = _incrementalPullWaves;
```

Delete `_computePullLevels` (:787-789) — now unused (`_computePushLevels` stays; the push phase is unchanged).

- [ ] **Step 4: Run tests**

Run: `cd apps/plot && flutter test test/store/incremental_pull_waves_test.dart test/store/critical_sync_actor_scope_test.dart`
Expected: PASS (both files — critical path untouched)

- [ ] **Step 5: Analyze + store suite, commit**

Run: `cd apps/plot && flutter analyze && flutter test test/store`

```bash
git add apps/plot/lib/store/sync_orchestrator.dart apps/plot/test/store/incremental_pull_waves_test.dart
git commit -m "perf(app): pull threads+notes first in catch-up sync"
```

---

### Task 6: Shared keep-alive HTTP client

`lib/api/api.dart` uses package:http top-level functions (`http.get`/`http.post`/…) — each call creates and closes a client, paying a fresh TCP+TLS handshake per request. Route all verb helpers through one long-lived client. GET retries once on `ClientException` (stale keep-alive socket after backgrounding) with a recreated client; mutating verbs surface the error unchanged (a blind retry could double-apply, e.g. double-send a note).

**Files:**
- Modify: `apps/plot/lib/api/api.dart` — add client + helper (~:195), rewrite the `http.<verb>` call in `post` (:236), `put` (:277), `patch` (:318), `get` (:359), both `delete`s (:399, :442), and the standalone `http.get` (:547)
- Test: `apps/plot/test/api/shared_client_test.dart` (create)

**Interfaces:**
- Produces: `Future<http.Response> sendWithReconnect(Future<http.Response> Function(http.Client) send, {required bool idempotent})` (public — it's the test seam); `@visibleForTesting void debugSetHttpClientFactory(http.Client Function() factory)`.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/api/shared_client_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plot/api/api.dart' as api;

/// The shared keep-alive client: a ClientException (stale socket after
/// backgrounding) recreates the client; idempotent sends retry once on the
/// fresh client, mutating sends surface the error unchanged.
void main() {
  tearDown(() => api.debugSetHttpClientFactory(http.Client.new));

  /// First client throws ClientException on use; every later client
  /// responds 200. Returns the call counter.
  List<int> installFlakyFactory() {
    final counts = [0];
    var clientIndex = -1;
    api.debugSetHttpClientFactory(() {
      clientIndex++;
      final failing = clientIndex == 0;
      return MockClient((request) async {
        counts[0]++;
        if (failing) throw http.ClientException('stale socket');
        return http.Response('ok', 200);
      });
    });
    return counts;
  }

  test('idempotent send retries once on a fresh client', () async {
    final counts = installFlakyFactory();
    final response = await api.sendWithReconnect(
      (client) => client.get(Uri.parse('https://example.test/x')),
      idempotent: true,
    );
    expect(response.statusCode, 200);
    expect(counts[0], 2, reason: 'failed once, retried once');
  });

  test('mutating send surfaces ClientException without retry', () async {
    final counts = installFlakyFactory();
    await expectLater(
      api.sendWithReconnect(
        (client) => client.post(Uri.parse('https://example.test/x')),
        idempotent: false,
      ),
      throwsA(isA<http.ClientException>()),
    );
    expect(counts[0], 1, reason: 'no retry for mutating requests');
  });

  test('client is reused across sends (no per-call client)', () async {
    var created = 0;
    api.debugSetHttpClientFactory(() {
      created++;
      return MockClient((request) async => http.Response('ok', 200));
    });
    for (var i = 0; i < 3; i++) {
      await api.sendWithReconnect(
        (client) => client.get(Uri.parse('https://example.test/$i')),
        idempotent: true,
      );
    }
    expect(created, 1, reason: 'one shared client for all three sends');
  });
}
```

- [ ] **Step 2: Run it** — Expected: FAIL — `sendWithReconnect` / `debugSetHttpClientFactory` undefined. (If `package:http/testing.dart` is unavailable, `http` is already a direct dependency — `MockClient` ships with it.)

- [ ] **Step 3: Implement** in `api.dart` (near `_random`, ~:195):

```dart
/// Shared keep-alive client. package:http's top-level functions create and
/// close a client per call, paying a fresh TCP+TLS handshake on EVERY
/// request (~50-150ms+, worse on mobile radio). One long-lived client
/// reuses connections; on web it delegates to the browser's fetch pool
/// exactly like the top-level functions did.
http.Client Function() _httpClientFactory = http.Client.new;
http.Client _httpClient = _httpClientFactory();

@visibleForTesting
void debugSetHttpClientFactory(http.Client Function() factory) {
  _httpClient.close();
  _httpClientFactory = factory;
  _httpClient = _httpClientFactory();
}

/// Runs [send] against the shared client. A [http.ClientException] usually
/// means the kept-alive socket died while the app was backgrounded: the
/// client is recreated, and [idempotent] sends (GET) are retried once on
/// the fresh client. Mutating sends (POST/PUT/PATCH/DELETE) are NOT
/// retried — a blind retry could double-apply a write (e.g. double-send a
/// note) — they surface the exception to the existing NetworkException
/// mapping unchanged.
Future<http.Response> sendWithReconnect(
  Future<http.Response> Function(http.Client client) send, {
  required bool idempotent,
}) async {
  try {
    return await send(_httpClient);
  } on http.ClientException {
    _httpClient.close();
    _httpClient = _httpClientFactory();
    if (!idempotent) rethrow;
    return await send(_httpClient);
  }
}
```

**[Amended during execution — review round 1]** The immediate `_httpClient.close()` above is WRONG: `IOClient.close()` force-terminates all active connections, so a stale-socket GET failing would abort unrelated concurrent in-flight requests (including healthy writes) sharing the client. As implemented: snapshot the client before sending, recreate only when the snapshot is still current (identical-reference guard, so concurrent failures produce one recreation), and defer the dead client's `close()` via a 150s timer — past the longest request timeout (120s) — so nothing legitimate can still be running when it fires.

Add `import 'package:meta/meta.dart';` if `@visibleForTesting` isn't already resolvable in this file (it comes with flutter/foundation too — match existing imports).

Rewrite each verb call site. `get` (:359) becomes:

```dart
    final response = await _retryOn401(
      (headers) => _retryOn429(() => sendWithReconnect(
        (client) => client
            .get(Uri.parse(Env.apiRoot + url), headers: headers)
            .timeout(const Duration(seconds: 30)),
        idempotent: true,
      )),
      url,
    );
```

`post` (:236) — same shape with `client.post(..., headers: headers, body: jsonEncode(body))` and `idempotent: false`. Same for `put` (:277), `patch` (:318), both `delete`s (:399, :442) with `idempotent: false`, and the standalone `http.get` at :547 with `idempotent: true`. The multipart upload (`request.send()`, ~:489-511) stays as-is — streamed requests can't be blindly re-sent; leave a one-line comment saying so.

- [ ] **Step 4: Run tests** — `cd apps/plot && flutter test test/api/shared_client_test.dart` — Expected: PASS (3 tests)

- [ ] **Step 5: Analyze + api tests + commit**

Run: `cd apps/plot && flutter analyze && flutter test test/api`

```bash
git add apps/plot/lib/api/api.dart apps/plot/test/api/shared_client_test.dart
git commit -m "perf(app): reuse one keep-alive HTTP client for API calls"
```

---

### Task 7: Coalesce concurrent catch-up syncs

On resume with a dropped socket, the lifecycle observer's `_startSync` (`store.dart:4686`) and the broadcast reconnect's `_syncAll` (`store.dart:2423`) overlap; the orchestrator's per-entity dedupe turns the second into a `_pullDirty` re-pull of every entity — a full second ~19-request sweep.

**Files:**
- Create: addition to `apps/plot/lib/util/async.dart` (`CoalescedRunner`)
- Modify: `apps/plot/lib/store/store.dart` — `_syncAll` (:2327)
- Test: `apps/plot/test/util/coalesced_runner_test.dart` (create)

**Interfaces:**
- Produces: `class CoalescedRunner { Future<void> run(Future<void> Function() action); bool get isRunning; }` — concurrent `run` calls while one is in flight return the in-flight future; the action runs once.
- Task 8 renames `_syncAll`'s body to `_syncAllInner` — this task establishes that split.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/util/coalesced_runner_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/async.dart';

void main() {
  test('concurrent runs share one execution', () async {
    final runner = CoalescedRunner();
    var executions = 0;
    final gate = Completer<void>();

    Future<void> action() async {
      executions++;
      await gate.future;
    }

    final first = runner.run(action);
    final second = runner.run(action); // joins in-flight run
    expect(runner.isRunning, isTrue);

    gate.complete();
    await Future.wait([first, second]);
    expect(executions, 1);
    expect(runner.isRunning, isFalse);
  });

  test('sequential runs execute each time', () async {
    final runner = CoalescedRunner();
    var executions = 0;
    await runner.run(() async => executions++);
    await runner.run(() async => executions++);
    expect(executions, 2);
  });

  test('errors propagate to every joined caller, then reset', () async {
    final runner = CoalescedRunner();
    final gate = Completer<void>();
    Future<void> failing() async {
      await gate.future;
      throw StateError('boom');
    }

    final first = runner.run(failing);
    final second = runner.run(failing);
    gate.complete();
    await expectLater(first, throwsStateError);
    await expectLater(second, throwsStateError);
    // A later run starts fresh.
    var ran = false;
    await runner.run(() async => ran = true);
    expect(ran, isTrue);
  });

  test('synchronously-completing action does not wedge the runner', () async {
    final runner = CoalescedRunner();
    await runner.run(() async {});
    expect(runner.isRunning, isFalse);
    var ran = false;
    await runner.run(() async => ran = true);
    expect(ran, isTrue);
  });
}
```

- [ ] **Step 2: Run it** — Expected: FAIL — `CoalescedRunner` undefined.

- [ ] **Step 3: Implement** in `lib/util/async.dart`:

```dart
/// Coalesces concurrent invocations of one async operation: while a run is
/// in flight, additional callers share its future instead of starting
/// another run. Used for the sync catch-up sweep, where app-resume and the
/// WebSocket reconnect can both fire within milliseconds — the in-flight
/// sweep already covers the second trigger's window (every pull fetches up
/// to the server's current horizon at request time), so a second sweep
/// would only queue a redundant ~19-request dirty re-pull.
class CoalescedRunner {
  Future<void>? _inFlight;

  bool get isRunning => _inFlight != null;

  Future<void> run(Future<void> Function() action) {
    final existing = _inFlight;
    if (existing != null) return existing;

    final completer = Completer<void>();
    _inFlight = completer.future;
    () async {
      try {
        await action();
        _inFlight = null;
        completer.complete();
      } catch (e, stackTrace) {
        _inFlight = null;
        completer.completeError(e, stackTrace);
      }
    }();
    return completer.future;
  }
}
```

- [ ] **Step 4: Run the test — PASS.** `cd apps/plot && flutter test test/util/coalesced_runner_test.dart`

- [ ] **Step 5: Wire into Store.** In `store.dart`, rename the existing `_syncAll` (:2327) to `_syncAllInner` and add:

```dart
  /// Coalesces overlapping catch-up triggers (resume + reconnect firing
  /// within milliseconds) onto one sweep. The per-entity _pullDirty
  /// machinery still covers broadcast-driven changes that land mid-pull.
  final _catchUpRunner = CoalescedRunner();

  Future<void> _syncAll() => _catchUpRunner.run(_syncAllInner);
```

All existing call sites (`:2423`, `:2641`, `:2993`, `:4680`) keep calling `_syncAll()` unchanged. Add the `import 'util/async.dart'` only if `store.dart` doesn't already import it (it does — the debouncer comes from there; verify).

- [ ] **Step 6: Analyze + suites + commit**

Run: `cd apps/plot && flutter analyze && flutter test test/util test/store`

```bash
git add apps/plot/lib/util/async.dart apps/plot/lib/store/store.dart apps/plot/test/util/coalesced_runner_test.dart
git commit -m "fix(app): coalesce overlapping resume/reconnect catch-up syncs"
```

---

### Task 8: sync_catchup telemetry

**Files:**
- Create: `apps/plot/lib/store/sync_catchup_stats.dart`
- Modify: `apps/plot/lib/store/store.dart` — `_syncAllInner` (from Task 7), `_startSync` (:2607), connectivity listener (:2661-2700), `_handleReconnected` (:2420), `fullResync` (`_syncAll` call at :2993), lifecycle observer (:4668-4691), `Store.pull` (stats hook, ~:1826)
- Modify: `apps/plot/lib/store/sync_orchestrator.dart` — `syncAll` wave timings (:361-375)
- Test: `apps/plot/test/store/sync_catchup_stats_test.dart` (create)

**Interfaces:**
- Consumes: `Tracker.track(String eventName, [Map<String, dynamic>? properties])` (`lib/analytics/tracker.dart:425`); `CoalescedRunner` from Task 7.
- Produces: `class SyncCatchupStats` with `static SyncCatchupStats? current`, `void recordPull(String entity, int ms, int pages, int rows)`, `void recordWave(int index, int ms)`, `Map<String, dynamic> finish()`.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/store/sync_catchup_stats_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/sync_catchup_stats.dart';

void main() {
  test('accumulates pulls, waves and totals into event props', () {
    final stats = SyncCatchupStats('resume');
    stats.recordPull('threads', 120, 2, 350);
    stats.recordPull('notes', 90, 1, 40);
    stats.recordPull('links', 80, 1, 12);
    stats.recordWave(0, 150);
    stats.recordWave(1, 60);

    final props = stats.finish();
    expect(props['trigger'], 'resume');
    expect(props['threads_ms'], 120);
    expect(props['notes_ms'], 90);
    expect(props['wave1_ms'], 150);
    expect(props['wave2_ms'], 60);
    expect(props['requests'], 4); // one per page
    expect(props['pages'], 4);
    expect(props['rows_total'], 402);
    expect(props['total_ms'], isA<int>());
  });

  test('current is null outside a catch-up window', () {
    expect(SyncCatchupStats.current, isNull);
  });
}
```

- [ ] **Step 2: Run it** — Expected: FAIL — file/class missing.

- [ ] **Step 3: Implement `lib/store/sync_catchup_stats.dart`:**

```dart
/// Collects one catch-up sweep's timing for the `sync_catchup` analytics
/// event (prod p50/p95 dashboard for app-open sync latency). Installed as
/// [current] by Store's catch-up sweep and read by Store.pull; broadcast
/// subset syncs never install it. The sweep is coalesced (one at a time),
/// so a plain static is safe; concurrent broadcast-driven pulls landing
/// mid-sweep add slight noise, which is acceptable for a latency metric.
class SyncCatchupStats {
  SyncCatchupStats(this.trigger);

  static SyncCatchupStats? current;

  final String trigger;
  final Stopwatch _total = Stopwatch()..start();
  final Map<String, int> _waveMs = {};
  int _requests = 0;
  int _pages = 0;
  int _rows = 0;
  int _threadsMs = 0;
  int _notesMs = 0;

  void recordPull(String entity, int ms, int pages, int rows) {
    _requests += pages; // one HTTP request per page
    _pages += pages;
    _rows += rows;
    if (entity == 'threads') _threadsMs = ms;
    if (entity == 'notes') _notesMs = ms;
  }

  void recordWave(int index, int ms) => _waveMs[index == 0 ? 'wave1_ms' : 'wave2_ms'] = ms;

  Map<String, dynamic> finish() => {
        'trigger': trigger,
        'total_ms': _total.elapsedMilliseconds,
        'threads_ms': _threadsMs,
        'notes_ms': _notesMs,
        ..._waveMs,
        'requests': _requests,
        'pages': _pages,
        'rows_total': _rows,
      };
}
```

- [ ] **Step 4: Run the test — PASS.**

- [ ] **Step 5: Plumb the trigger.** Signature changes in `store.dart`:

```dart
  Future<void> _syncAll({required String trigger}) =>
      _catchUpRunner.run(() => _syncAllInner(trigger));

  Future<void> _syncAllInner(String trigger) async {
    SyncCatchupStats.current = SyncCatchupStats(trigger);
    try {
      // ...existing body (orchestrator.syncAll() etc.) unchanged...
    } finally {
      final stats = SyncCatchupStats.current;
      SyncCatchupStats.current = null;
      if (stats != null) {
        unawaited(Tracker.track('sync_catchup', stats.finish()));
      }
    }
  }
```

`_startSync` gains `({required String trigger})` and forwards it to `await _syncAll(trigger: trigger)`. Update every call site (grep `_startSync(` and `_syncAll(`):
- connectivity listener initial online check (:2672): `trigger: 'startup'`
- connectivity-restored branch inside the listener: `trigger: 'connectivity'`
- sync-retry timer (`_scheduleSyncRetry`'s callback, grep it): `trigger: 'retry'`
- `_handleReconnected` (:2423): `trigger: 'reconnect'`
- `fullResync` (:2993): `trigger: 'resync'`
- lifecycle observer (:4680 and :4686): `trigger: 'resume'`

In `Store.pull`, next to the existing `syncPerfLog` block (~:1826):

```dart
    SyncCatchupStats.current?.recordPull(
      baseTable.fullName,
      sw.elapsedMilliseconds,
      pages,
      totalRows,
    );
```

In `SyncOrchestrator.syncAll`'s pull-phase loop (Task 5's shape), after each `_executePullLevel`:

```dart
        SyncCatchupStats.current?.recordWave(i, levelSw.elapsedMilliseconds);
```

(`sync_orchestrator.dart` is `part of 'store.dart'` — add the `sync_catchup_stats.dart` import to `store.dart`.)

- [ ] **Step 6: Analyze + suites + commit**

Run: `cd apps/plot && flutter analyze && flutter test test/store`

```bash
git add apps/plot/lib/store/sync_catchup_stats.dart apps/plot/lib/store/store.dart apps/plot/lib/store/sync_orchestrator.dart apps/plot/test/store/sync_catchup_stats_test.dart
git commit -m "feat(app): sync_catchup timing telemetry for catch-up syncs"
```

---

### Task 9: Orphan-tolerance audit + regression tests

The wave change reorders relative landings: thread before priority/role/actor; note possibly before its thread; thread-aux (tags/reactions/schedules/links) concurrent with threads; channel/twistConnection concurrent with twistInstance. Writes are safe (no FK enforcement, insertOrReplace) and SQL reads join-filter; the risk is Dart-side presence-assuming lookups.

**Files:**
- Audit (possibly modify): files under `apps/plot/lib/state/`, `apps/plot/lib/page/`, `apps/plot/lib/widget/`, and `processPulledRows` overrides in `apps/plot/lib/store/`
- Test: `apps/plot/test/store/orphan_tolerance_test.dart` (create)

**Interfaces:**
- Consumes: seeding helpers pattern from `test/store/activity_feed_done_order_test.dart` (Store.forTesting + `store.into(...).insert(...Companion(...))` + `seedSelf()`).

- [ ] **Step 1: Run the audit greps** and review every hit against the reordered pairs above (only those pairs — don't refactor unrelated code):

```bash
cd apps/plot
# firstWhere without orElse in resolution layers:
rg -n "firstWhere\(" lib/state lib/page lib/widget | rg -v "firstWhereOrNull|orElse"
# null-assert after cross-entity map/lookup access:
rg -n "\[[a-zA-Z_.]+\]\!" lib/state lib/page lib/widget | rg -i "thread|note|priorit|actor|link|channel|twist"
# pulled-row processors that might read sibling tables:
rg -n "processPulledRows" lib/store
```

For each genuine hit (a lookup that can now run before its referent has synced), convert to skip-and-self-heal (`firstWhereOrNull` + early return / render without the decoration), matching the unresolved-contact pattern documented at `sync_orchestrator.dart:281-292`. Record each change in the commit message body. If a hit is only reachable with data that syncs atomically in one entity (same table), leave it and move on.

- [ ] **Step 2: Write the orphan-tolerance tests** (these encode the write/read safety contract regardless of audit findings):

```dart
// apps/plot/test/store/orphan_tolerance_test.dart
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Catch-up pulls run in parallel waves, so child rows can land before the
/// rows they reference (note before thread, thread before priority, tag
/// before thread). These tests pin the two layers that make that safe:
/// SQLite FK enforcement is OFF (orphan writes succeed) and the feed/query
/// layer filters or null-tolerates missing referents instead of throwing.
void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    Actor.clearCache();
  });

  tearDown(() async {
    Actor.clearCache();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('PRAGMA foreign_keys is OFF — orphan writes cannot throw', () async {
    final row = await store.customSelect('PRAGMA foreign_keys').getSingle();
    expect(row.data.values.first, 0,
        reason: 'parallel catch-up writes rely on unenforced FKs; if this '
            'ever flips ON, the wave ordering needs a rethink');
  });

  test('note without its thread: insert + query do not throw', () async {
    await store.into(store.notes).insert(
          NotesCompanion(
            id: Value(NoteId(Uuid.generate())),
            threadId: Value(ThreadId(Uuid.generate())), // absent thread
            authorId: Value(ActorId(Uuid.generate())),
            createdAt: Value(DateTime.now()),
            sourceCreatedAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
    // Feed queries must simply not surface it.
    final page = await Thread.fetchAllTabPage(limit: 50);
    expect(page.threads, isEmpty);
  });

  test('thread without its priority: feed query does not throw and thread '
      'appears once the priority lands', () async {
    // Seed self actor (thread hydration resolves the current user).
    // Follow the seedSelf() pattern from activity_feed_done_order_test.dart.
    // ... seedSelf() as in that file ...
    // Insert a thread whose priorityId references a not-yet-synced priority
    // (use the ThreadsCompanion shape from activity_feed_done_order_test's
    // insertThread helper, with a fresh random priority id).
    // Assert: fetchAllTabPage completes without throwing.
    // Then insert the priority row (insertPriority pattern) and assert the
    // thread is present in a fresh fetchAllTabPage call.
  });

  test('threadTag without its thread: queries do not throw', () async {
    await store.into(store.threadTags).insert(
          ThreadTagsCompanion(
            threadId: Value(ThreadId(Uuid.generate())),
            tag: const Value('star'),
            actorId: Value(ActorId(Uuid.generate())),
            updatedAt: Value(DateTime.now()),
          ),
        );
    final page = await Thread.fetchAllTabPage(limit: 50);
    expect(page.threads, isEmpty);
  });
}
```

NOTE: the exact `Companion` field sets above must be adjusted to the real table
schemas (copy working inserts from `activity_feed_done_order_test.dart` and
`note_test.dart` rather than guessing; required columns differ). The assertions
to preserve verbatim: no throw on insert, no throw on query, self-heal after
parent insert.

- [ ] **Step 3: Run the tests**

Run: `cd apps/plot && flutter test test/store/orphan_tolerance_test.dart`
Expected: PASS. Any failure here is a REAL finding — fix the throwing lookup per Step 1's pattern, not the test.

- [ ] **Step 4: Analyze + full suites + commit**

Run: `cd apps/plot && flutter analyze && flutter test test/store test/state test/widget`

```bash
git add -A apps/plot/lib apps/plot/test/store/orphan_tolerance_test.dart
git commit -m "fix(app): harden cross-entity lookups for parallel catch-up sync"
```

---

### Task 10: End-to-end verification, updates fragment, finalize

**Files:**
- Create: `docs/updates.d/<slug>.md` (via `pnpm updates:new`)

- [ ] **Step 1: Launch the app with perf logging** using the `run-app` skill, adding `--dart-define=SYNC_PERF_LOG=true` to the launch (the flag is `bool.fromEnvironment('SYNC_PERF_LOG')`, `lib/store/logging.dart:8`).

- [ ] **Step 2: Verify the catch-up shape in logs.** Background the app (or start it fresh with existing local data) and resume. In the logs confirm ALL of:
  1. `syncAll: pull L0` lists `[thread,note]` and `pull L1` the remaining 12 entities (two waves only).
  2. The six thread sub-pulls (`Store.pull links/threads/schedules/thread_tags/thread_reactions/thread_associations`) log near-simultaneous completion (parallel), not a serial staircase.
  3. NO `Store.pull agenda` / `Store.pull activity-feed` lines on the resume sync (backfill gone).
  4. A single catch-up sweep on resume (no second full sweep from the reconnect path).
  5. The `sync_catchup` event props logged/emitted with plausible `threads_ms`/`total_ms`.

- [ ] **Step 3: Verify data freshness end-to-end.** With the app backgrounded, change data through another surface (e.g. mark a thread read/unread or send a note from the web app at `app.plot.day`, or a second local profile), then resume: the change must appear in the feed within ~1-2s. Record the observed `total_ms`.

- [ ] **Step 4: Verify Everything on-demand pull.** Open the Everything view, scroll to the bottom repeatedly: confirm `Store.pull` lines for the global `activity-feed` cursor fire as you scroll (and stop once `noMore`), and the spinner resolves. Confirm no global feed pulls happen while merely resuming.

- [ ] **Step 5: Updates fragment** (user-visible perf change):

```bash
pnpm updates:new "Opening the app after time away now shows your updated threads much faster"
```

Place the bullet under an existing suitable `### section` (e.g. a syncing/performance section if one exists in recent fragments; otherwise `### Syncing`).

- [ ] **Step 6: Run /finalize** (mandatory project checklist: lint, backwards compat, error capture, docs, public submodule — no public/ changes expected here).

- [ ] **Step 7: Commit any remaining changes; hand off for PR** per superpowers:finishing-a-development-branch (user decides merge/PR).

```bash
git add docs/updates.d
git commit -m "docs: updates fragment for faster app-open sync"
```
