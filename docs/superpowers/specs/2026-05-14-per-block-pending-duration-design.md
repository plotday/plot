# Per-Block Pending Duration — Design

**Date:** 2026-05-14
**Status:** Approved (verbal)
**Scope:** `apps/plot` Flutter agenda + Drift store. No server schema change.
**Builds on:** [2026-04-30-agenda-priority-blocks-design.md](2026-04-30-agenda-priority-blocks-design.md), [2026-05-09-agenda-priority-block-redesign.md](2026-05-09-agenda-priority-block-redesign.md)

## Goal

Make a priority's pending duration **per-block** instead of per-priority, so
adding or removing time on one day's block in the agenda affects only that
block and never bleeds into other days. Do this without introducing a cascade
mechanism and without growing the working set: the agenda only ever loads the
`priority_block` rows that can still apply.

## Today's bug

`priority_block` already supports a per-day timeline via `effective_at`.
Reorders correctly write rows at the block's period start
(`apps/plot/lib/state/priority.dart:893`–`940`). Duration changes, however,
go through `PriorityBlock.setPendingDuration`
(`apps/plot/lib/store/priority_block.dart:190`), which always upserts the
**canonical "current" row at the epoch sentinel** `kCurrentEffectiveAt` =
`1970-01-01`. The resolver `effectivePriorityDurationAt` then picks "latest
non-null-duration row with `effective_at <= moment`", so the epoch row's
duration applies to every block in every day forever.

The user-visible effect:

> "When I have a priority with threads scheduled for several days and add time
> in the agenda to any of them, they all gain the same amount of time."

The `_BlockHeader` gutter subscribes to `NowBloc.watchPendingDisplay(priorityId)`
(`apps/plot/lib/widget/agenda.dart:609`), which surfaces the same per-priority
value on every section's block.

## What changes (user-visible)

- Each agenda block independently owns its scheduled time. `+15m` on Tuesday's
  9–10 block adds 15m to **only** Tuesday's 9–10 block. Wednesday is
  untouched.
- The `+`/`−` gutter on a block reflects only that block's value (plus any
  active/paused session that lands within the block, same as today).
- Reorders are unchanged — they continue to apply on and after the block they
  target.
- **No carry-over / cascade.** If a block's planned time exceeds what fits in
  its window, the remainder simply stays unfulfilled. (Cascade is a possible
  future enhancement; explicitly out of scope here.)
- **No backfill.** Existing epoch rows' duration values are not migrated. The
  first time a user opens the agenda after the update, any previously-set
  "global" pending will appear empty on every block and the user re-enters
  per-block durations as they go. Order values from epoch rows are preserved
  via the anchor mechanism (below) and the existing fallback to `Priority.order`.

## Data model

Schema unchanged. `priority_block` keeps `(priority_id, effective_at)` as its
unique key, with `order_value` (required) and `duration` (nullable).

Conventions:

- The epoch sentinel `kCurrentEffectiveAt` is **abandoned for new writes**.
  Both reorders and duration changes write rows with `effective_at = block.start`.
- The existing epoch sentinel and its masking-row archival logic in
  `PriorityBlock.setPendingDuration` are removed when that method is replaced.
- Existing epoch rows are left in place. After the change they function as a
  natural "carry-forward anchor" for orders (see Resolver below); their
  durations are explicitly ignored.

### Block windows

Every block has a `(start, end)` tuple. `start` is the row's `effective_at`
on write. `(start, end)` is the half-open interval used for session
containment (below). Computed during the agenda build pass by walking each
section's consolidated blocks in order and tracking the previous and next
time-anchored block.

| Block kind | `start` | `end` |
| --- | --- | --- |
| `GapBlock` (priority-led) | `gap.range.start` | `gap.range.end` |
| `EventBlock` | `event.at.start` | `event.at.end` (not user-bumpable; documented for completeness) |
| Standalone `PriorityBlock` after a time-anchored block in its section | the previous time-anchored block's `end` | the next time-anchored block's `start`, or `sectionDate + 1 day` (local) if none follows |
| Standalone `PriorityBlock` at section start (no preceding time-anchored block) | section-date local midnight | the next time-anchored block's `start`, or `sectionDate + 1 day` (local) if none follows |
| Standalone `PriorityBlock` in a section with no time-anchored blocks | section-date local midnight | section-date local midnight + 1 day |

This matches the convention reorders already use via `periodReferenceTime`
for `start`. `end` is new but derived purely from the same section's
contents, so two clients viewing the same agenda will compute identical
windows. A single priority can have at most one standalone block per
"run" between time-anchored blocks (the existing consolidation in
`_consolidatePriorityBlocks` enforces "one block per priority per period"),
so anchors do not collide for a given priority within a section.

## Query: bounded window with per-priority anchor

`streamPriorityBlocksGroupedByPriority` (in `apps/plot/lib/store/priority_block.dart`)
changes from a plain `archived_at IS NULL` select to a UNION:

```sql
-- Forward chunk: every row whose effective_at is today or later.
-- Holds the current block, future-dated blocks, and any pre-planned
-- future reorders.
SELECT * FROM priority_block
WHERE archived_at IS NULL AND effective_at >= :today_midnight

UNION ALL

-- Per-priority carry-forward anchor: the most recent non-archived
-- row strictly before today, for each priority. Provides the
-- "what was the latest order" answer that the cumulative order
-- resolver needs once historical rows fall out of the forward window.
SELECT pb.* FROM priority_block pb
WHERE pb.archived_at IS NULL
  AND pb.effective_at < :today_midnight
  AND pb.effective_at = (
    SELECT MAX(effective_at) FROM priority_block
    WHERE priority_id = pb.priority_id
      AND archived_at IS NULL
      AND effective_at < :today_midnight
  )
```

`:today_midnight` is the user's local midnight at watch-creation time
(stored as a UTC `DateTime`). The result is grouped by `priority_id` exactly
as today.

Implementation note: Drift's `customSelect` is the cleanest expression; the
result rows map back into `PriorityBlockRow` via the existing
`PriorityBlockRow.fromJson`-style constructor or a hand-rolled mapping. The
existing public `Stream<Map<PriorityId, List<PriorityBlockRow>>>` signature
does not change.

### Window freshness at date rollover

`:today_midnight` is bound at watch construction. If the app stays open past
midnight, the window doesn't re-narrow on its own. Add a small per-instance
date watcher in `NowBloc`: when the local date changes (detected by the
existing minute tick comparing the last-seen local date against
`Time.now().toDate()`), tear down and re-subscribe the
`streamPriorityBlocksGroupedByPriority` stream. About a dozen lines.

If we forget this watcher, correctness is not affected — the window simply
grows by one day past midnight until the next app start. Worth doing for the
working-set guarantee.

## Resolver changes

The store-side resolver functions in
`apps/plot/lib/store/priority_block.dart` split by concern:

### `effectivePriorityOrderAt` — unchanged

```dart
double effectivePriorityOrderAt({
  required DateTime moment,
  required Iterable<PriorityBlockRow> blocksForPriority,
  required double fallback,
}) { ... }
```

Same logic as today. Runs over the unified row set, so the per-priority
anchor row contributes when no forward-window row qualifies. Falls back to
`Priority.order` if the priority has no non-archived rows at all.

### Replace `effectivePriorityDurationAt` with `resolveBlockDurations`

The current point-query is replaced by a **chronological walker** that
assigns at most one duration row to each block, in agenda order:

```dart
/// Pure function. Returns a map from block id to the duration that
/// block should display, by walking the priority's blocks in chronological
/// order and consuming the latest unconsumed in-window row whose
/// `effective_at <= block.start`.
///
/// Rows with `effective_at < todayMidnight` (the carry-forward anchor) are
/// ignored for duration purposes — their job is order resolution only.
Map<String, Duration?> resolveBlockDurations({
  required DateTime todayMidnight,
  required List<({String id, DateTime start})> blocks,   // chronological
  required Iterable<PriorityBlockRow> blocksForPriority,
}) {
  final rows = blocksForPriority
      .where((r) => r.archivedAt == null)
      .where((r) => r.duration != null)
      .where((r) => !r.effectiveAt.isBefore(todayMidnight))
      .toList()
    ..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));

  final out = <String, Duration?>{};
  var rowIdx = 0;
  for (final b in blocks) {
    Duration? best;
    while (rowIdx < rows.length &&
           !rows[rowIdx].effectiveAt.isAfter(b.start)) {
      best = rows[rowIdx].duration;
      rowIdx++;
    }
    out[b.id] = best;
  }
  return out;
}
```

Two consequences fall out of the algorithm:

- Each row attaches to **exactly one** block — the first chronological block
  whose `start >= row.effective_at`. Duration is one-shot per block.
- A future-dated row whose `effective_at` is after the last fetched block's
  start is simply not consumed; it lives in the table for whenever its day
  is in view.

## Agenda integration

`agenda_builder.dart`:

- `_cascadePendingDurations` is replaced by `_attachBlockDurations`. The new
  pass:
  1. Builds the chronological block list for each priority from the
     consolidated model (sections in date order; within a section, the
     sequence of `GapBlock` / `EventBlock` / `PriorityBlock` headers as
     emitted by `_consolidateSection`). Each entry has a stable `id`
     (the existing block id) and a `start` per the [anchor table](#block-start-anchor-per-block-kind).
  2. Calls `resolveBlockDurations` per priority over the unified row set.
  3. Folds the result onto each block as `cascadeDuration` (kept as the
     field name to avoid churn; semantically it is now "this block's
     pending duration").
- The synthetic-tail-block logic and the empty-gap-merge logic stay, because
  they remain useful when a block exists chronologically but the priority
  has no thread-bearing block in that section.

`_BlockHeader` in `agenda.dart`:

- Stops subscribing to the per-priority `NowBloc.watchPendingDisplay`.
- Reads its duration from the block's own `cascadeDuration` for the read
  path, plus a new per-block live overlay (see `watchBlockDisplay` below).

## Sessions and the live overlay

The active timer remains per-priority. When a session lands in a particular
block's time window, the gutter should show the session's live remaining
instead of the static row value. Add:

```dart
/// Live remaining-duration stream for a specific block. Resolution order:
///   1. Active session for this priority whose pomodoroAt falls inside the
///      block's window AND at.isNow() → `pomodoroAt + pomodoro - now`.
///   2. Paused-explicit session for this priority whose pomodoroAt falls
///      inside the block's window → `pomodoroAt + pomodoro - end`.
///   3. The block's static `cascadeDuration` from the agenda model.
static Stream<PriorityPendingDisplay> watchBlockDisplay({
  required PriorityId priorityId,
  required DateTime blockStart,
  required DateTime blockEnd,
}) { ... }
```

The "block contains the session" test is `session.pomodoroAt >= block.start
&& session.pomodoroAt < block.end`, using the `(start, end)` tuple defined
in [Block windows](#block-windows). Because every block kind — including
standalones — has a definite `end`, the test is unambiguous and no two
blocks in the same section claim the same session.

`NowBloc.watchPendingDisplay` and its callers are deleted.

## Writes

`PriorityBlock.setPendingDuration` is replaced by:

```dart
/// Upsert a `priority_block` row for [priorityId] at `effective_at =
/// blockStart`, carrying [newDuration]. Carries the priority's effective
/// order at [blockStart] into `order_value` (same convention reorders use).
///
/// Semantics:
///   - normalize null/≤0 → null,
///   - if normalized equals the current row's duration, no-op,
///   - if normalized is null, soft-archive the row at this slot,
///   - otherwise upsert in place at `(priorityId, blockStart)`.
static Future<void> setBlockDuration({
  required PriorityId priorityId,
  required DateTime blockStart,
  required Duration? newDuration,
}) async { ... }
```

The masking-row archival sweep on the epoch sentinel is dropped — no row
ever occupies the epoch slot from new code, and old epoch rows are harmless
(their durations are filtered out by the walker; their orders feed the
anchor mechanism).

`NowBloc.applyPendingBump` is replaced by `applyBlockBump`:

```dart
static Future<void> applyBlockBump({
  required PriorityId priorityId,
  required DateTime blockStart,
  required DateTime blockEnd,
  required Duration? currentDisplayed,
  required Duration? newDisplayed,
}) async { ... }
```

The session-vs-row routing is the same as today's `applyPendingBump`, but
"is there a live session?" becomes "is there a live session within this
block's window?" using the same containment test as `watchBlockDisplay`.

`_BlockHeader._applyPriorityBump` learns `blockStart` / `blockEnd` from the
header's `AgendaHeaderItem` (`sourcePeriodStart`, `dateTimeRange`, and
`sourceDate` are already populated; the block-anchor function in this design
is built on top of them).

## What this does not change

- `priority_block` schema. No Atlas migration, no Drift schema bump.
- `Priority.order` semantics. It continues to function as the ultimate
  fallback when a priority has no non-archived `priority_block` rows.
- Reorder write path. Reorders already write `effective_at = period start`
  and continue to do so.
- The `cascadeDuration` field name on `PriorityBlock` / `GapBlock`. Semantics
  shift from "the priority's global pending folded onto today" to "this
  block's resolved duration", but the field stays so existing renderers
  don't churn.

## Testing

Pure unit tests on the new resolver and the agenda builder:

- `resolveBlockDurations`:
  - Single row consumed by the first block; later blocks get null.
  - Multiple rows in different windows → each block gets its own row.
  - Multiple rows in the same window → block gets the latest.
  - Row with `effective_at < todayMidnight` is filtered (never consumed).
- `effectivePriorityOrderAt` over a unified set including an anchor row
  with `effective_at < todayMidnight` → still resolves to the anchor when
  no forward-window row qualifies.
- `_attachBlockDurations`:
  - Block-anchor per block kind (gap, event, standalone-after-event,
    standalone-at-section-start).
  - Synthetic tail blocks unchanged.

Bump tests:

- `setBlockDuration` upserts at `(priorityId, blockStart)` and leaves rows
  at other `effective_at`s alone.
- `applyBlockBump` writes to the active session when one is in the block's
  window; otherwise writes to the row.

Manual / integration:

- Open the agenda. For a priority with threads on Mon/Tue/Wed, bump time on
  Tuesday's block. Verify only Tuesday's gutter changes.
- Run the timer through a block; verify the block's live overlay
  counts down; verify other blocks for the same priority do not.

## Documentation updates

`docs/agenda.md` describes the current cascade behavior and needs to be
rewritten alongside the code:

- **"Pending Duration Cascade" section** — replace entirely. The new copy
  describes per-block pending: each block independently owns a planned
  duration; editing it writes a `priority_block` row at the block's
  `effective_at`; nothing cascades into or out of the block. Keep the note
  about the gutter UI and the `cascadeDuration` field name (still used as
  the carrier on the `AgendaBlock` model).
- **"Drop Behavior" — cross-period drop into a gap with no pending duration
  set** — the default 30m write changes from "writes priority's total
  pending" to "writes a `priority_block` row at the destination gap's
  anchor with `duration = min(30m, available-gap-room)`". Behavior stays
  visually identical; only the storage location changes.
- **"Inline Duration Bump" — Priority blocks (cascade slice / no slice)** —
  collapse the two cases into one bullet: "Priority and priority-led gap
  blocks — the block's own pending duration. There is no priority-wide
  total to re-anchor; each block stands alone."
- **"Block Sort Within a Period"** — no change. Order semantics are
  preserved.

`docs/updates.md` — add a one-liner to the top section:
"Time you add to a block in the agenda now applies only to that block
instead of every day."

## Rollout

- No DB migration. Ship the Flutter / Drift changes in one PR.
- Pre-existing epoch rows continue to feed `Priority.order` via the anchor
  mechanism. Their durations are dropped silently — acknowledged regression
  for users with a non-null epoch duration; they re-enter per block.
- Window-rollover watcher is the only "infrastructure" addition; everything
  else is local to read/write helpers and the agenda builder.

## Open questions / future work

- **Cascade.** Not in scope. If we add it later, the resolver becomes a
  walker that propagates unfinished remainder forward; the
  `Duration? carriedIn` field on `AgendaBlock` is the natural place to hang
  the visual "+10m carried" indicator.
- **Same-day cross-block overflow** (e.g., a priority with two gap regions on
  one day, the first overflowing into the second). Also not in scope;
  same-day blocks are independent for now.
- **Future-planned reorders that age out of the window without ever being
  visible.** Currently impossible under the UNION because the anchor query
  returns the most recent row strictly before midnight regardless of whether
  it's a reorder or a duration; once a future-dated row's day passes, it
  becomes the anchor for the next day's window. No action required, called
  out for clarity.
