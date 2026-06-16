# Durable `/sync/thread-state` push Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Flutter client's per-user `/sync/thread-state` push durable — a persisted dirty marker drained with retries by the normal push cycle — so a transient network failure can no longer silently drop a state change.

**Architecture:** Add a client-only `state_pending` boolean to the local `threads` table. `Thread.copyWith` stamps it whenever a per-user state change is persisted; `Thread.save()`/`saveOrder()` stop firing a one-shot HTTP POST. `Thread.push()` (already run every sync cycle) gains a durable drain that batch-POSTs the current row state, clears the marker only on acceptance (guarded by `updated_at` for last-writer coalescing, never touching `read_at`), retries transient failures, and reports permanent ones to PostHog. A racing pull preserves all unpushed per-user state fields while the marker is set.

**Tech Stack:** Dart/Flutter, Drift (SQLite), `flutter_test`, in-memory `Store.forTesting`.

**Base context:**
- Spec: `docs/superpowers/specs/2026-06-15-durable-thread-state-push-design.md`
- Worktree: `.claude/worktrees/durable-thread-state-push` (branch `durable-thread-state-push`)
- Baseline `flutter test test/store/`: **182 pass, 4 fail** — pre-existing migration-test failures (`link_orphan_migration_test`, `priority_icon_migration_test`, `priority_path_nullable_migration_test`, `stranded_note_migration_test`). These fail WITHOUT this change; do not attribute them to this work.
- All commands run from `apps/plot/`. Generated `*.g.dart` are gitignored (already built in this worktree).

---

## File structure

- **Modify** `apps/plot/lib/store/thread.dart`:
  - `Threads` table — add `statePending` column.
  - `ThreadsBase.toBase` — strip `state_pending`; `ThreadsBase.fromBase` — default it.
  - `ThreadsBase.processPulledRows` — preserve unpushed state on a racing pull.
  - `Thread` factory (`ThreadRow(...)` at ~4463) — pass `statePending: false`.
  - `Thread.copyWith` — stamp `statePending: true` in the state-dirty branch; add `@visibleForTesting bool get statePending`.
  - `Thread.save()` / `Thread.saveOrder()` — persist the marker; delete `_pushThreadState()`.
  - `Thread.push()` — call the new durable drain; add `pushPendingThreadState` + `_threadStateBody`.
- **Modify** `apps/plot/lib/store/store.dart`:
  - `Store.schemaVersion` 371 → 372; add `if (from < 372)` migration step.
- **Create** `apps/plot/test/store/thread_state_push_durability_test.dart` — drain behavior + pull-merge.
- **Modify** `apps/plot/test/store/thread_copywith_done_bump_test.dart` — marker-on-save assertions.
- **Modify** `docs/updates.md` — one Fixes bullet (only if kept; see Task 6).

---

## Task 1: Add the `state_pending` column + migration (schema 372)

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (Threads table ~162; factory ~4473)
- Modify: `apps/plot/lib/store/store.dart` (schemaVersion ~2534; `_incrementalMigration` ~4158)

- [ ] **Step 1: Add the column to the `Threads` table.** After `revoked` (`thread.dart:162`, the last column before the closing `}`), add:

```dart
  /// Client-only durability marker for the per-user thread_state push
  /// (POST /sync/thread-state). Set true whenever a per-user state change is
  /// persisted locally; cleared only after the server accepts the push. Never
  /// sent to the server (stripped in [ThreadsBase.toBase]) and never set from a
  /// server pull (defaulted in [ThreadsBase.fromBase]). Distinct from `pending`
  /// (the full-thread /sync/threads marker) and from `read_at` (a dual-purpose
  /// durable "finished" marker that must survive a successful state push).
  BoolColumn get statePending => boolean().withDefault(const Constant(false))();
```

- [ ] **Step 2: Pass the new required field in the `Thread` factory.** In `thread.dart` the `ThreadRow(...)` construction (~4473, alongside `revoked: false,`), add:

```dart
      revoked: false,
      statePending: false,
```

- [ ] **Step 3: Bump the schema version.** `store.dart:2534`:

```dart
  int get schemaVersion => 372;
```

- [ ] **Step 4: Add the incremental migration step.** In `_incrementalMigration` (`store.dart`), after the `if (from < 371)` block (~4158), add:

```dart
    if (from < 372) {
      // Client-only durability marker for the /sync/thread-state push.
      // Default false: anything truly unpushed pre-upgrade was already lost
      // by the old fire-and-forget push, so existing rows start clean.
      await _safeAddColumn(m, threads, threads.statePending);
    }
```

- [ ] **Step 5: Regenerate Drift code.**

Run: `flutter pub run build_runner build --delete-conflicting-outputs`
Expected: exit 0; `store.g.dart` now has `statePending` on `ThreadRow`/`ThreadsCompanion`.

- [ ] **Step 6: Analyze.**

Run: `flutter analyze lib/store/thread.dart lib/store/store.dart`
Expected: No errors (warnings about `@visibleForTesting` only appear after Task 2/4).

- [ ] **Step 7: Confirm no new test breakage.**

Run: `flutter test test/store/ 2>&1 | tail -3`
Expected: `+182 -4` (the same 4 pre-existing migration failures, nothing new).

- [ ] **Step 8: Commit.**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/lib/store/store.dart apps/plot/lib/store/store.g.dart
git commit -m "feat(store): add client-only state_pending column (schema 372)"
```

---

## Task 2: Stamp the marker in `copyWith` + expose a getter

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (copyWith state-dirty branch ~6224; getter near `stateDirty` ~4585)
- Test: `apps/plot/test/store/thread_copywith_done_bump_test.dart`

- [ ] **Step 1: Add the failing tests.** In `thread_copywith_done_bump_test.dart`, inside the existing `group('Thread.copyWith read-receipt push path (stateDirty)', ...)` (or a new adjacent group), add:

```dart
    test('a state-dirty copyWith stamps the persisted statePending marker', () {
      final unreadTask = Thread(
        priority: _priority(),
        active: true,
        unread: true,
        stateOn: Date(2026, 1, 1),
        stateOrder: Order.first(),
      );
      expect(unreadTask.statePending, isFalse, reason: 'precondition: clean');

      final read = unreadTask.copyWith(
        unread: false,
        readAt: Value(unreadTask.contentTimestamp),
      );

      expect(read.stateDirty, isTrue);
      expect(
        read.statePending,
        isTrue,
        reason: 'the persisted marker is what drives the durable push',
      );
    });

    test('a non-state copyWith leaves statePending false', () {
      final inDone = Thread(priority: _priority(), active: false);
      final reopened = inDone.copyWith(
        unread: false,
        readAt: Value(inDone.contentTimestamp),
      );

      expect(reopened.stateDirty, isFalse);
      expect(reopened.statePending, isFalse);
    });
```

- [ ] **Step 2: Run to verify it fails.**

Run: `flutter test test/store/thread_copywith_done_bump_test.dart -p vm`
Expected: FAIL — `statePending` getter is undefined (compile error).

- [ ] **Step 3: Add the getter.** In `thread.dart`, next to `bool get stateDirty => _stateDirty;` (~4585):

```dart
  /// The persisted per-user-state dirty marker (`threads.state_pending`).
  /// Drives the durable /sync/thread-state push in [pushPendingThreadState].
  @visibleForTesting
  bool get statePending => _thread.statePending;
```

- [ ] **Step 4: Stamp the marker in the state-dirty branch.** In `copyWith`, the `if (stateDirty)` activity fold (~6224), add `statePending: true`:

```dart
    if (stateDirty) {
      activity = activity.copyWith(
        active: tsActive,
        urgent: tsUrgent,
        stateOrder: tsStateOrder,
        stateOn: tsStateOn,
        stateAt: tsStateAt,
        readAt: tsReadAt,
        statePending: true,
        updatedAt: now,
      );
      activityDirty = true;
    } else if (readAt.present) {
```

- [ ] **Step 5: Run to verify it passes.**

Run: `flutter test test/store/thread_copywith_done_bump_test.dart -p vm`
Expected: PASS (all tests, including the pre-existing `stateDirty` ones).

- [ ] **Step 6: Commit.**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/test/store/thread_copywith_done_bump_test.dart
git commit -m "feat(store): stamp state_pending marker in Thread.copyWith"
```

---

## Task 3: Keep the column off the wire and out of pulls

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (`ThreadsBase.toBase` ~571; `ThreadsBase.fromBase` ~393)
- Create: `apps/plot/test/store/thread_state_wire_test.dart`

- [ ] **Step 1: Add the failing tests.** Create `apps/plot/test/store/thread_state_wire_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

ThreadRow _row({bool statePending = true}) => ThreadRow(
      id: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      priorityId: Uuid.generate(),
      draft: false,
      unread: false,
      importance: 0,
      active: false,
      hasEmbedding: false,
      revoked: false,
      statePending: statePending,
    );

void main() {
  group('ThreadsBase wire mapping for state_pending', () {
    test('toBase strips the client-only state_pending marker', () {
      final json = ThreadsBase().toBase(_row(statePending: true));
      expect(
        json.containsKey('state_pending'),
        isFalse,
        reason: 'state_pending must never reach the /sync/threads endpoint',
      );
    });

    test('fromBase defaults state_pending to false (server never sends it)',
        () {
      final serverJson = _row(statePending: true).toJson()
        ..remove('state_pending');
      expect(serverJson.containsKey('state_pending'), isFalse);

      final result = ThreadsBase().fromBase(serverJson) as ThreadRow;

      expect(
        result.statePending,
        isFalse,
        reason: 'a pulled row must not arrive already-dirty',
      );
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails.**

Run: `flutter test test/store/thread_state_wire_test.dart -p vm`
Expected: FAIL — `toBase` still contains `state_pending`; `fromBase` throws on the missing non-null key.

- [ ] **Step 3: Strip in `toBase`.** In `ThreadsBase.toBase` (`thread.dart`), after `json.remove('read_at');` (~571):

```dart
    json.remove('read_at');
    // Client-only durability marker — never send it to the server.
    json.remove('state_pending');
```

- [ ] **Step 4: Default in `fromBase`.** In `ThreadsBase.fromBase`, just before `return ThreadRow.fromJson(json);` (~435):

```dart
    // The server view has no `state_pending` (client-only). Default it so the
    // non-null column deserializes; a racing-pull merge restores the local
    // value when a push is still pending (see processPulledRows).
    json['state_pending'] ??= false;

    return ThreadRow.fromJson(json);
```

- [ ] **Step 5: Run to verify it passes.**

Run: `flutter test test/store/thread_state_wire_test.dart -p vm`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit.**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/test/store/thread_state_wire_test.dart
git commit -m "feat(store): keep state_pending off the wire and out of pulls"
```

---

## Task 4: Durable drain in `Thread.push()` (the core)

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (`Thread.push()` ~1024-1103; `_pushThreadState` ~6596; `save()` ~6705; `saveOrder()` ~6573)
- Create: `apps/plot/test/store/thread_state_push_durability_test.dart`

- [ ] **Step 1: Add the failing durability tests.** Create `apps/plot/test/store/thread_state_push_durability_test.dart`:

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/store/store.dart';

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

  Future<void> insertThread(
    Uuid id, {
    bool active = false,
    bool statePending = true,
    DateTime? readAt,
    DateTime? updatedAt,
  }) async {
    await store.into(store.threads).insert(
          ThreadsCompanion(
            id: Value(id),
            priorityId: Value(Uuid.generate()),
            active: Value(active),
            importance: const Value(0),
            readAt: Value(readAt),
            statePending: Value(statePending),
            updatedAt:
                updatedAt == null ? const Value.absent() : Value(updatedAt),
          ),
        );
  }

  Future<ThreadRow> readRow(Uuid id) => (store.select(store.threads)
        ..where((t) => t.id.equalsValue(id)))
      .getSingle();

  ApiException _api(int status) => ApiException(
        statusCode: status,
        endpoint: '/sync/thread-state',
        title: 't',
        description: 'd',
      );

  test('transient failure keeps the row dirty, then a retry clears it',
      () async {
    final id = Uuid.generate();
    await insertThread(id);

    // 503 is not a permanent status → transient → rethrow, keep the marker.
    await expectLater(
      Thread.pushPendingThreadState(
        post: (url, {body = const <String, dynamic>{}}) async => throw _api(503),
      ),
      throwsA(isA<ApiException>()),
    );
    expect((await readRow(id)).statePending, isTrue,
        reason: 'a transient failure must not drop the change');

    // Next cycle succeeds → marker cleared.
    await Thread.pushPendingThreadState(
      post: (url, {body = const <String, dynamic>{}}) async => {'ok': true},
    );
    expect((await readRow(id)).statePending, isFalse);
  });

  test('a successful push clears the marker without clearing an active '
      'thread\'s read_at', () async {
    final id = Uuid.generate();
    final readAt = DateTime(2026, 1, 2, 9);
    await insertThread(id, active: true, readAt: readAt);

    await Thread.pushPendingThreadState(
      post: (url, {body = const <String, dynamic>{}}) async => {'ok': true},
    );

    final row = await readRow(id);
    expect(row.statePending, isFalse);
    expect(row.readAt, readAt,
        reason: 'an active thread keeps read_at as its Doing "finished" marker');
  });

  test('a permanent rejection clears the marker and reports', () async {
    final id = Uuid.generate();
    await insertThread(id);

    var reported = 0;
    await Thread.pushPendingThreadState(
      post: (url, {body = const <String, dynamic>{}}) async => throw _api(422),
      report: (error, stack, count) => reported += count,
    );

    expect((await readRow(id)).statePending, isFalse,
        reason: 'a permanent rejection will never succeed — stop retrying');
    expect(reported, 1, reason: 'permanent rejections must be reported');
  });

  test('an edit during the in-flight POST is not lost (updated_at guard)',
      () async {
    final id = Uuid.generate();
    final t0 = DateTime(2026, 1, 1, 8);
    await insertThread(id, updatedAt: t0);

    // The poster mutates the row mid-flight (a concurrent local edit bumps
    // updated_at and re-sets the marker) before returning success.
    await Thread.pushPendingThreadState(
      post: (url, {body = const <String, dynamic>{}}) async {
        await (store.update(store.threads)
              ..where((t) => t.id.equalsValue(id)))
            .write(ThreadsCompanion(
          updatedAt: Value(t0.add(const Duration(minutes: 1))),
          statePending: const Value(true),
        ));
        return {'ok': true};
      },
    );

    expect((await readRow(id)).statePending, isTrue,
        reason: 'the newer edit (different updated_at) must survive to re-push');
  });
}
```

- [ ] **Step 2: Run to verify it fails.**

Run: `flutter test test/store/thread_state_push_durability_test.dart -p vm`
Expected: FAIL — `Thread.pushPendingThreadState` is undefined.

- [ ] **Step 3: Add the body builder + drain method.** In `thread.dart`, add near `Thread.push()` (after it, ~1104). Note the typedefs go at top-of-`Thread`-class scope is unnecessary — declare them as library-private top-level typedefs just above the `Thread` class, or inline. Use inline function types to avoid new top-level names:

```dart
  /// Builds the POST /sync/thread-state body for one row. Mirrors the shape
  /// the legacy fire-and-forget `_pushThreadState` sent (constraint: keep the
  /// body the endpoint expects), sourced from the persisted row so rapid
  /// edits coalesce to the row's current state.
  static Map<String, dynamic> _threadStateBody(ThreadRow row) =>
      <String, dynamic>{
        'thread_id': row.id.toString(),
        'active': row.active,
        if (row.urgent != null) 'urgent': row.urgent,
        'importance': row.importance,
        if (row.stateOrder != null) 'order': row.stateOrder!.value,
        if (row.stateOn != null) 'on': '[${row.stateOn},)',
        if (row.stateAt != null)
          'at': '["${row.stateAt!.toIso8601String()}",)',
        if (row.readAt != null) 'read_at': row.readAt!.toIso8601String(),
        if (row.bumpedAt != null)
          'bumped_at': row.bumpedAt!.toIso8601String(),
      };

  /// Durable replacement for the old fire-and-forget `_pushThreadState`.
  /// Drains every `state_pending` row through POST /sync/thread-state, then:
  ///   * success / partial → clear the marker for rows whose `updated_at` is
  ///     unchanged since selection (last-writer guard; an edit during the
  ///     in-flight POST bumps `updated_at`, so the marker survives and the
  ///     newer state re-pushes). `read_at` is never touched.
  ///   * per-row `failed[]` (permanent pg rejection) → clear + report.
  ///   * permanent ApiException (4xx) → clear all + report (no rethrow).
  ///   * transient (offline / timeout / 5xx) → keep markers, rethrow so the
  ///     sync orchestrator retries next cycle; not reported (expected).
  /// [post]/[report] are test seams defaulting to `api.post` / PostHog.
  @visibleForTesting
  static Future<void> pushPendingThreadState({
    Future<dynamic> Function(String url, {Object body})? post,
    void Function(Object error, StackTrace stack, int count)? report,
  }) async {
    if (!Store.isAvailable) return;
    final store = Store.get;

    final pending = await (store.select(
      store.threads,
    )..where((t) => t.statePending.equals(true))).get();
    if (pending.isEmpty) return;

    final poster = post ??
        (String url, {Object body = const <String, dynamic>{}}) =>
            api.post<dynamic>(url, body: body);
    final reporter = report ??
        (Object error, StackTrace stack, int count) => Store._reportSyncFailure(
              'Permanent sync push rejected',
              table: 'thread_state',
              endpoint: 'thread-state',
              outcome: 'cleared',
              error: error,
              stackTrace: stack,
              extraProperties: {'record_count': count},
            );

    // Snapshot (id, updated_at) for the guarded clear; build the batched body
    // from the CURRENT row so rapid edits coalesce.
    final snapshots = pending
        .map((row) => (id: row.id, updatedAt: row.updatedAt))
        .toList();
    final records = pending.map(_threadStateBody).toList();

    Future<void> clearUnchanged() async {
      for (final s in snapshots) {
        await (store.update(store.threads)
              ..where((t) =>
                  t.id.equalsValue(s.id) & t.updatedAt.equalsValue(s.updatedAt)))
            .write(const ThreadsCompanion(statePending: Value(false)));
      }
    }

    try {
      final response = await poster('/sync/thread-state', body: records);
      if (response is Map && response['failed'] is List) {
        final failed = (response['failed'] as List).cast<String>();
        if (failed.isNotEmpty) {
          log.warning(
            'Server rejected ${failed.length} thread-state records: $failed',
          );
          reporter(
            StateError('thread-state records rejected'),
            StackTrace.current,
            failed.length,
          );
        }
      }
      await clearUnchanged();
    } catch (e, stackTrace) {
      if (e is ApiException && Store._isPermanentError(e)) {
        log.warning(
          'Permanent error pushing thread-state, '
          'clearing ${pending.length} records: $e',
        );
        reporter(e, stackTrace, pending.length);
        await clearUnchanged();
      } else {
        // Transient — keep the markers, retry on the next push cycle.
        log.warning('Failed to push thread-state changes: $e');
        rethrow;
      }
    }
  }
```

- [ ] **Step 4: Wire the drain into `Thread.push()`.** In `Thread.push()`, replace the early-return guard so the drain always runs. Change (~1034):

```dart
    if (readActivities.isEmpty) {
      return success;
    }

    try {
```

to:

```dart
    if (readActivities.isNotEmpty) {
      try {
```

and close that `if` after the existing read-receipt `catch (...) { ... }` block (before `return success;` at ~1102). I.e. the existing `try { ...thread-read... } catch (...) { ... }` becomes the body of `if (readActivities.isNotEmpty) { ... }`. Then, immediately before `return success;`, add:

```dart
    // Durable per-user thread_state push (replaces the old fire-and-forget
    // _pushThreadState). Runs every cycle, independent of read receipts.
    await pushPendingThreadState();

    return success;
```

- [ ] **Step 5: Run to verify the durability tests pass.**

Run: `flutter test test/store/thread_state_push_durability_test.dart -p vm`
Expected: PASS (4 tests).

- [ ] **Step 6: Persist the marker on save & delete the fire-and-forget push.** In `Thread.save()`, the local-only update branch `ThreadsCompanion` (~6641) — add the marker with a mark-or-leave rule (save never clears the marker; only the drain does):

```dart
        )..where((a) => a.id.equalsValue(id))).write(
          ThreadsCompanion(
            unread: Value(_thread.unread),
            importance: Value(_thread.importance),
            active: Value(_thread.active),
            urgent: Value(_thread.urgent),
            stateOrder: Value(_thread.stateOrder),
            stateOn: Value(_thread.stateOn),
            stateAt: Value(_thread.stateAt),
            readAt: Value(_thread.readAt),
            bumpedAt: Value(_thread.bumpedAt),
            // Mark dirty when this save carries a state change; never write
            // `false` here — only the durable drain clears the marker, so a
            // stale in-memory copy can't resurrect or erase a pending push.
            statePending:
                _thread.statePending ? const Value(true) : const Value.absent(),
            updatedAt: Value(_thread.updatedAt),
          ),
        );
```

Then remove the now-dead direct push at the end of `save()` (~6705):

```dart
    // Push per-user state changes via /sync/thread-state.
    if (_stateDirty) {
      _pushThreadState();
    }

```

Delete those four lines (the trailing `_deferIdle(Thread.push, ...)` immediately below already schedules the durable drain).

- [ ] **Step 7: Update `saveOrder()` and delete `_pushThreadState`.** In `saveOrder()` (~6573), add the marker to the write and replace the trailing `_pushThreadState();`:

```dart
    await (Store.get.update(
      Store.get.threads,
    )..where((a) => a.id.equalsValue(id))).write(
      ThreadsCompanion(
        stateOrder: Value(_thread.stateOrder),
        statePending: const Value(true),
        updatedAt: Value(_thread.updatedAt),
      ),
    );
    // Durable drain runs on the next push cycle; schedule it now.
    _deferIdle(Thread.push, debugLabel: 'thread push');
  }
```

Then delete the entire `_pushThreadState()` method (~6596-6619) — it now has no callers.

- [ ] **Step 8: Analyze and run the full store suite.**

Run: `flutter analyze lib/store/thread.dart`
Expected: No errors (no "unused" for `_pushThreadState`, since it's deleted).

Run: `flutter test test/store/ 2>&1 | tail -3`
Expected: `+N -4` with N increased by the new tests; only the same 4 pre-existing migration failures.

- [ ] **Step 9: Commit.**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/test/store/thread_state_push_durability_test.dart
git commit -m "feat(store): durable /sync/thread-state push with retry + reporting"
```

---

## Task 5: Preserve unpushed state across a racing pull (spec §4)

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (`ThreadsBase.processPulledRows` merge loop ~462-521)
- Test: `apps/plot/test/store/thread_state_push_durability_test.dart` (append)

- [ ] **Step 1: Add the failing test.** Append to `thread_state_push_durability_test.dart` (inside `main`, after the existing tests):

```dart
  test('a racing pull preserves unpushed per-user state while dirty', () async {
    final id = Uuid.generate();
    final readAt = DateTime(2026, 1, 3, 10);
    // Local: an unpushed "active + importance 80 + read" edit.
    await store.into(store.threads).insert(ThreadsCompanion(
          id: Value(id),
          priorityId: Value(Uuid.generate()),
          active: const Value(true),
          importance: const Value(80),
          readAt: Value(readAt),
          statePending: const Value(true),
          updatedAt: Value(DateTime(2026, 1, 3, 10)),
        ));

    // Server snapshot (pre-edit): inactive, importance 0, no read.
    final serverRow = ThreadRow(
      id: id,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 3, 11),
      priorityId: Uuid.generate(),
      draft: false,
      title: 'server title',
      unread: true,
      importance: 0,
      active: false,
      hasEmbedding: false,
      revoked: false,
      statePending: false,
    );

    final merged =
        await ThreadsBase().processPulledRows(store, [serverRow]);

    expect(merged, hasLength(1));
    final row = merged.single as ThreadRow;
    expect(row.active, isTrue, reason: 'unpushed active survives the pull');
    expect(row.importance, 80, reason: 'unpushed importance survives');
    expect(row.readAt, readAt, reason: 'unpushed read survives');
    expect(row.statePending, isTrue, reason: 'still needs to push');
    expect(row.title, 'server title',
        reason: 'server-authoritative content fields still update');
  });
```

- [ ] **Step 2: Run to verify it fails.**

Run: `flutter test test/store/thread_state_push_durability_test.dart -p vm -N "racing pull preserves"`
Expected: FAIL — without the merge rule the server's `active=false`/`importance=0`/`readAt=null` win.

- [ ] **Step 3: Add the preservation branch.** In `ThreadsBase.processPulledRows`, the per-row loop currently runs an `if (local != null && local.readAt != null) { ... }` block then an `if (local != null && local.bumpedAt != null) { ... }` block (~474-519). Wrap those in an else so a pending row takes the broad preserve instead. Replace the start of the readAt block (~474):

```dart
      // Conflict resolution: local has a pending read (readAt != null).
      if (local != null && local.readAt != null) {
```

with:

```dart
      // An unpushed per-user state edit (state_pending) is the local source of
      // truth until the durable /sync/thread-state push clears the marker — the
      // pull would otherwise clobber it (and the drain reads the DB row, so it
      // would then push the stale server value). Preserve all per-user state
      // fields; server-authoritative content fields still update from `merged`.
      if (local != null && local.statePending) {
        merged = merged.copyWith(
          active: local.active,
          urgent: Value(local.urgent),
          importance: local.importance,
          stateOrder: Value(local.stateOrder),
          stateOn: Value(local.stateOn),
          stateAt: Value(local.stateAt),
          readAt: Value(local.readAt),
          bumpedAt: Value(local.bumpedAt),
          statePending: true,
        );
        result.add(merged);
        continue;
      }

      // Conflict resolution: local has a pending read (readAt != null).
      if (local != null && local.readAt != null) {
```

> The `continue` skips the existing readAt/bumpedAt branches for pending rows — the broad preserve supersedes them. Non-pending rows fall through to the unchanged logic. `urgent`/`stateOrder`/`stateOn`/`stateAt`/`readAt`/`bumpedAt` are nullable columns, so they use `Value(...)`; `active`/`importance`/`statePending` are non-null.

- [ ] **Step 4: Run to verify it passes.**

Run: `flutter test test/store/thread_state_push_durability_test.dart -p vm`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full store suite.**

Run: `flutter test test/store/ 2>&1 | tail -3`
Expected: only the same 4 pre-existing migration failures.

- [ ] **Step 6: Commit.**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/test/store/thread_state_push_durability_test.dart
git commit -m "feat(store): preserve unpushed thread state across a racing pull"
```

---

## Task 6: Docs + final verification

**Files:**
- Modify: `docs/updates.md` (only if kept)

- [ ] **Step 1: Decide on a user-facing note.** This is mostly internal robustness, but cross-device state reliability is user-noticeable. Add ONE bullet under `## Next release` → `### Fixes` (create `### Fixes` if absent, last in the section). Keep it plain:

```markdown
- Changes you make to a thread (marking it done, reordering, scheduling, or reading it) now reliably reach your other devices even if your connection drops briefly.
```

If `docs/updates.md`'s top section is a stamped `## <version> — <date>` (no `## Next release`), create a fresh `## Next release` above it with a `### Fixes` subsection.

- [ ] **Step 2: Full analyze of changed files.**

Run: `flutter analyze lib/store/thread.dart lib/store/store.dart`
Expected: No errors.

- [ ] **Step 3: Full store suite — confirm only pre-existing failures remain.**

Run: `flutter test test/store/ 2>&1 | tail -4`
Expected: `Some tests failed.` with exactly the 4 pre-existing migration tests
(`link_orphan_migration_test`, `priority_icon_migration_test`,
`priority_path_nullable_migration_test`, `stranded_note_migration_test`) — and
all new tests green. Diff the failing-test list against the baseline list to
confirm no new failures.

- [ ] **Step 4: Commit docs.**

```bash
git add docs/updates.md
git commit -m "docs(updates): note cross-device reliability for thread changes"
```

---

## Self-review notes

- **Spec coverage:** §1 schema → Task 1; §2 wire → Task 3; §3 marker-on-save → Task 2 + Task 4 (save/saveOrder); §4 pull-merge → Task 5; §5 drain → Task 4; constraints 1/2/5 exercised by Task 4 tests, 3 by `_threadStateBody` mirroring the legacy body, 4 by Task 1. Testing §1–5 covered.
- **Type consistency:** `pushPendingThreadState`, `_threadStateBody`, `statePending` getter/column used identically across tasks. Guarded clear uses `equalsValue` for both mapped columns (`id`, `updatedAt`).
- **No placeholders:** every code step is complete.
