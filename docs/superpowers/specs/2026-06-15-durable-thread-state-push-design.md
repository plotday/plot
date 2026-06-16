# Durable `/sync/thread-state` push — design

**Date:** 2026-06-15
**Branch:** `durable-thread-state-push`
**Area:** `apps/plot` (Flutter client only — no server changes)

## Problem

Per-user thread state (`active`, `urgent`, `importance`, `order`, `on`/`at`,
`read_at`, `bumped_at`) is pushed to the server via `POST /sync/thread-state`.
The push — `Thread._pushThreadState()` in `apps/plot/lib/store/thread.dart`,
called from `Thread.save()` and `Thread.saveOrder()` — is **fire-and-forget**:

```dart
() async {
  try {
    await api.post('/sync/thread-state', body: body);
  } catch (e, t) {
    log.warning('Failed to push thread state for $id: $e\n$t');
  }
}();
```

If that POST fails (offline, transient 5xx, app backgrounded mid-request) the
change is **never retried and never reported**. The local row keeps the new
value; the server never learns of it, so the device diverges from the server and
from the user's other devices. Commit `3ecd7bb3b` routed active-thread read
receipts onto this same fragile channel, so hardening it fixes cross-device
unread **and** active/importance/order/scheduling changes together.

The fully-durable `/sync/thread-read` (inactive read receipts) and full-thread
(`pending` bit) pushes already exist in `Thread.push()` and the `Store.push`
framework. This brings `/sync/thread-state` up to that standard.

## Approach (chosen)

A **persisted boolean dirty marker** drives a **retried push integrated into the
normal push cycle** (`Thread.push()`), replacing the one-shot HTTP call at save
time. This mirrors the existing `/sync/thread-read` durability exactly.

Considered and rejected: a separate outbox table (more machinery, a second
source of truth, an extra lookup to read live state at push time — no gain since
the push re-reads the live row anyway). Decision: boolean column on `threads`.

### 1. Local schema: `state_pending` column

Add to `Threads` (`apps/plot/lib/store/thread.dart`):

```dart
/// Client-only durability marker for the per-user thread_state push
/// (POST /sync/thread-state). Set true whenever a per-user state change is
/// persisted locally; cleared only after the server accepts the push. Never
/// sent to the server (stripped in ThreadsBase.toBase) and never set from a
/// server pull (defaulted in ThreadsBase.fromBase). Distinct from `pending`
/// (the full-thread /sync/threads marker) and from `read_at` (a dual-purpose
/// durable "finished" marker that must survive a successful state push).
BoolColumn get statePending => boolean().withDefault(const Constant(false))();
```

- `Store.schemaVersion` 371 → **372**.
- Incremental migration: `if (from < 372) await _safeAddColumn(m, threads, threads.statePending);`
  (use `_safeAddColumn` so test harnesses that roll back `user_version` don't
  trip a duplicate-column error — same rationale as existing steps).
- `flutter pub run build_runner build` to regenerate `store.g.dart`.
- New nullable-with-default semantics: no data migration needed for existing
  rows (they default to `false` = nothing pending, correct — anything truly
  unpushed pre-upgrade was already lost by the old fire-and-forget path).

### 2. Keep the column off the wire / out of pulls

- **`ThreadsBase.toBase`** already strips every per-user-state field; add
  `json.remove('state_pending');` so a row that is *also* `pending` (full
  `/sync/threads` push) never leaks the client-only marker to the server.
- **`ThreadsBase.fromBase`** calls `ThreadRow.fromJson`; the server JSON has no
  `state_pending`, and a non-null bool column would make `fromJson` throw. Inject
  a default before deserializing: `json['state_pending'] ??= false;` (the merge
  in `processPulledRows`, §4, restores the local value when a push is pending).

### 3. Set the marker on save (`copyWith` → row), drop fire-and-forget

`Thread.copyWith` already computes the in-memory `_stateDirty` under exactly the
conditions that need a `/sync/thread-state` push. When `stateDirty` is true, also
stamp the **persisted** marker on the activity row in the same `copyWith` that
folds the state fields in:

```dart
activity = activity.copyWith(
  active: tsActive, urgent: tsUrgent, stateOrder: tsStateOrder,
  stateOn: tsStateOn, stateAt: tsStateAt, readAt: tsReadAt,
  statePending: true,            // ← durable marker
  updatedAt: now,
);
```

`updatedAt: now` is already set here — it is the coalescing key (§5), so every
state write must bump it. `saveOrder()` likewise sets `statePending` and a fresh
`updatedAt` on its `ThreadsCompanion` write.

`Thread.save()` / `saveOrder()` **stop calling `_pushThreadState()`**. The
local-only update branch in `save()` adds `statePending: Value(_thread.statePending)`
to its `ThreadsCompanion`; the full-save branch carries it via
`toCompanion(false)`. The existing `_deferIdle(Thread.push, ...)` at the end of
`save()` already schedules the durable drain; `saveOrder()` switches its trailing
`_pushThreadState()` to `_deferIdle(Thread.push, ...)`. `_pushThreadState()` is
deleted (only those two callers).

> Scope guard: the **set** of changes that push via `/sync/thread-state` is
> unchanged (still exactly `_stateDirty`). We only make the existing push
> durable — no new fields, no new triggers, no behavior change to *which* edits
> sync where.

### 4. Preserve unpushed state across a racing pull

`user.thread` exposes per-user state (active/order/importance/on/at), so a pull
that lands between a local state edit and its push would overwrite the local
value — and because the durable push reads from the **DB row**, it would then
push the stale server value. `ThreadsBase.processPulledRows` already preserves
local `read_at`/`bumped_at` on a pending read; extend it: when
`local.statePending == true`, preserve **all** per-user-state fields from local
over the server row and keep `statePending = true`, then skip the existing
read_at/bumped_at-specific branches for that row (the broad preserve supersedes
them). Server-authoritative content fields (title, preview, contacts, …) still
update from the pull. Once the push clears the flag, a later pull brings
authoritative server state normally.

### 5. Durable drain in `Thread.push()`

Extract a `@visibleForTesting static Future<void> pushPendingThreadState({post, report})`
and call it from `Thread.push()` (after the `/sync/thread-read` block; remove the
early `return success` so it always runs). Seams default to `api.post` and
`Store._reportSyncFailure` so tests can simulate outcomes without the network.

Algorithm:

1. `select(threads)..where((t) => t.statePending.equals(true))` → dirty rows.
   If empty, return.
2. Capture `(id, updatedAt)` per row and build one batched body — each record
   from the **current row** (coalesces rapid edits; no stale snapshot queue).
   Body shape identical to today's `_pushThreadState` (`thread_id`, `active`,
   `urgent?`, `importance`, `order?`, `on?`, `at?`, `read_at?`, `bumped_at?`).
3. `await post('/sync/thread-state', body: records)` (batched array — the
   endpoint already accepts arrays and returns `{ok, failed}`).
4. **Success / partial:** for each row whose `updated_at` is unchanged since
   capture, clear the marker: `update(threads)..where((t) => t.id.equals(idBytes)
   & t.updatedAt.equals(captured))..write(statePending: false)`. The
   `updated_at` guard is the last-writer safeguard: an edit during the in-flight
   POST bumps `updated_at`, so the marker survives and the newer state re-pushes
   next cycle. **`read_at` is never touched** — an active thread stays "finished"
   in Doing (constraint #1 holds *because* the marker is separate from the
   receipt).
   - Per-row `failed[]` ids are permanent server rejections (mapped pg errors):
     clear their marker too (won't succeed on retry) and `report(...)`.
5. **Catch:** if `Store._isPermanentError(e)` (400/403/404/409/422) → permanent:
   clear all markers (guarded) + `report(...)` (PostHog). Else transient
   (offline/timeout/5xx) → **keep markers, rethrow** so the orchestrator retries
   next cycle; **no error report** (expected failure).

`report` builds the same grouping-stable PostHog exception as the thread-read
path: message `'Permanent sync push rejected (thread-state)'`, `table:
'thread_state'`, `endpoint: 'thread-state'`, `record_count` in properties.

## Constraints check

1. **`read_at` survives a successful active-thread push** — the drain clears only
   `state_pending`, never `read_at`. ✓
2. **Last-writer / idempotency** — current-row read + `updated_at`-guarded clear;
   no historical snapshots. ✓
3. **Server read guard unchanged** — body shape preserved (`read_at` via
   `clear_thread_state`, other fields via `upsert_thread_state` with
   `p_set_read_at: false`). No server change. ✓
4. **Local migration** — schema 371→372, incremental `_safeAddColumn`,
   build_runner; never drop/recreate. ✓
5. **Error capture** — permanent → `_reportSyncFailure` (PostHog); transient →
   silent retry. ✓

## Testing (TDD)

New `apps/plot/test/store/thread_state_push_durability_test.dart`, in-memory
`Store.forTesting(NativeDatabase.memory())` + injected `post`/`report` seams:

1. **Transient failure keeps the row dirty** — poster throws a `NetworkException`
   (or 503 `ApiException`); assert `pushPendingThreadState` rethrows, the row's
   `state_pending` stays `true`, and a second call with a succeeding poster
   clears it (proves retry lands).
2. **Success clears the flag without clearing an active thread's `read_at`** —
   active row, `read_at` set, `state_pending = true`; succeeding poster; assert
   `state_pending == false` **and** `read_at` unchanged.
3. **Permanent rejection clears the flag and reports** — poster throws a 422
   `ApiException`; assert `state_pending == false` and the injected `report`
   seam fired once (no rethrow).
4. **Coalescing / `updated_at` guard** — poster mutates the row (bump
   `updated_at`, re-set `state_pending`) before returning success; assert
   `state_pending` is still `true` afterward (newer edit will re-push).
5. **Marker-on-save (pure, no DB)** — extend `thread_copywith_done_bump_test`
   coverage: `copyWith` that sets `_stateDirty` yields a row with
   `statePending == true` (add a `@visibleForTesting bool get statePending`).

Plus the existing `thread_copywith_done_bump_test.dart` `stateDirty` assertions
must stay green (the in-memory `_stateDirty` getter is unchanged).

## Out of scope

- Server-side changes.
- The `/sync/thread-read` (inactive) path.
- Other fire-and-forget pushes elsewhere (note if spotted, don't refactor).

## Verification

- `flutter analyze` clean on changed files.
- `flutter test test/store/` — new tests green; pre-existing failures (if any)
  confirmed present without this change.
- `docs/updates.md` bullet under `## Next release` → `### Fixes` only if
  user-noticeable (cross-device state reliability) — otherwise skip (mostly
  internal robustness).
