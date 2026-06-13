# PriorityPage thread repositioning — design

Date: 2026-06-12
Status: Approved (requirements supplied verbatim by Kris; design derived from them)

## Requirements

1. All state changes other than unread→read immediately change the thread's
   position in the PriorityPage list (to-do, done, do later, move, mute).
2. For threads rendered in the Active or Scheduled sections, when the changed
   thread is the open thread, the thread below it (positions as of before the
   change) is opened. This works across sections (marking the last Active
   thread done opens the first Scheduled thread). Exception: if the changed
   thread was the last thread before the Done section and there are threads
   above it, open the previous thread above instead (supports working
   bottom-up).
3. The open-next behaviour does not apply in the Done section — the changed
   thread remains open there.
4. New to-do items insert at the bottom of Active; newly scheduled items
   insert at the bottom of their scheduled day.
5. The per-thread 1.5s delayed-move grace window for read threads is removed.
6. When a thread's position changes, animate a collapse at the source
   synchronized with an expand at the destination. Invariant: nothing outside
   the range between source and destination shifts.
7. All of the above apply only to focus (sectioned) feeds. The Everything and
   search/filter (flat) feeds never move a thread on state change.

## What exists today (and what this replaces)

- `PriorityBloc` pins the open thread in place on To do / Done / mute via
  `_Overlay.stickyTodo` + `pinTodoInPlace`, holding position until 1.5s after
  navigate-away (`_stickyMoveDelay` / `_scheduleStickyRemoval`), with
  `_toggleOriginal` snapshots restoring sort position on round-trips.
  **Removed entirely** (rule 1).
- Unread→read uses `_Overlay.stickyUnread`: dot clears on open, row holds its
  unread-cluster position while open, then 1.5s after navigate-away it drops.
  **Pin while open stays** (rule 1's exception); **the 1.5s timer goes** —
  removal happens immediately on navigate-away (rule 5), animated (rule 6).
- `Thread.copyWith(todo: true)` defaults `state_order` to `Order.first()`
  (top of Active); promotion-via-date and `markTodo` do the same.
  **Changed to bottom placement** (rule 4).
- Only `FinishThread` auto-opens the next thread, gated on
  `resolveThreadListSource() == agenda`, using simple next-below.
  **Replaced** by a shared rule-2/3 helper used by Done, To do, Do later,
  Move, and Mute.
- No movement animation. **Added** (rule 6).

## Design

### A. Bottom insertion (rule 4)

Add `Order.last()` to `lib/util/order.dart` (`this(_first())` — a positive
now-timestamp). Every order previously assigned (via `Order.first()`’s
negative values, `Order.between` midpoints, or one-sided bounds derived from
an earlier wall clock) is strictly smaller, so a fresh `Order.last()` sorts
after everything in any bucket — no feed scan needed. Within the Scheduled
section the sort is (day, order), so it is also "bottom of that day".

Call sites switched from top to bottom default:
- `Thread.copyWith` `todo == true` branch (state order default).
- `Thread.copyWith` promote-to-active on date set (state order default).
- `Thread.markTodo` (`stateOrder: Value(Order.first())` today).
- `asActiveToday` / `asScheduled` fallbacks (only fire when the thread has no
  prior state order and the caller passed none).
- `ScheduleThread` ("Do later"): pass `Order.last()` instead of preserving the
  current order, so the thread lands at the bottom of the target day.
- `RescheduleAllInBlock`: assign a strictly-increasing chain
  (`Order.last()`, then `Order.between(prev, null)` per subsequent thread) so
  the block appends to the bottom of the target day preserving its relative
  order. (Plain `Order.last()` per item could interleave randomly within the
  same millisecond.)

Drag/drop paths pass explicit orders and are unchanged.

### B. Remove the pin machinery (rules 1, 5)

In `lib/state/priority.dart`:
- Delete `_Overlay.stickyTodo`, `pinnedSection`, `pinnedInUnread`,
  `pinTodoInPlace`, `_pinnedSectionFor`, `_isPinnedInUnread`,
  `_renderedSectionFor`, `_toggleOriginal`/`toggleOriginalFor`, and the
  pinned-section branches in `_buildUnifiedFeedItems`, `_catchUpCompare`,
  `optimisticallyUpdateThread` (clobber guard), and
  `optimisticallyRemoveThread` (`keepStickyTodo`).
- Replace `_scheduleStickyRemoval` + `_stickyRemovalTimers` +
  `_stickyMoveDelay` with an immediate `_removeSticky(id)` invoked from
  `setThread` on navigate-away. `_Overlay.stickyUnread` itself stays (open
  unread thread holds its cluster position while open, dot cleared).

In `lib/command/thread.dart`:
- `ToggleThreadActive`: drop `pinTodoInPlace` and the `restoreOrder` logic
  (re-activation now always lands at the bottom of Active via A).
- `FinishThread`: drop `pinTodoInPlace` and `effectiveBump` (no
  `_toggleOriginal`; completing from outside Done always bumps — the
  `entersDone` guard in `copyWith` already makes a Done-section re-complete a
  no-op).
- `MuteSimilarThreads`: drop `pinTodoInPlace`.

### C. Open-next (rules 2, 3)

New pure function (new file `lib/state/feed_navigation.dart`):

```dart
/// The thread to open after [changedId]'s state changes, per the
/// sectioned-feed rules, computed against the PRE-change items.
/// Returns null when the changed thread should stay open (it renders in
/// Done, isn't in the list, or the list has no other thread).
Thread? nextThreadAfterStateChange(List<AgendaItem> items, ThreadId changedId)
```

Walk `items` tracking the current section via `ActivitySectionMarker`
decoding; locate the changed row and the nearest thread rows below/above:
- changed row in Done → null (rule 3).
- next-below exists and is not in Done → next-below.
- next-below is in Done (changed row was last before Done): previous-above if
  it exists, else next-below (general rule 2 falls through).
- nothing below: previous-above if it exists, else null.

`PriorityBloc.threadAfterStateChange(ThreadId)` wraps it: returns null in flat
mode (rule 7) and when the changed thread isn't the open thread's feed.
Command wiring (compute target from pre-change items, then navigate, then
apply the optimistic change — mirrors today's FinishThread ordering):
- `FinishThread`: replaces `OpenNextThread()` + the `isAgenda` gate; keeps the
  NewThread fallback when there is no other thread at all.
- `ToggleThreadActive`: when marking done and the thread is open. (Marking
  to-do only happens from Done, where the helper returns null.)
- `ScheduleThread` ("Do later"), `MoveToPriority` (only when the target
  priority is outside the current focus context), `MuteSimilarThreads`
  (set branch): same call when the changed thread is open.

### D. Collapse/expand move animation (rule 6)

Bloc side: every explicit state change already funnels through
`optimisticallyUpdateThread` / `optimisticallyRemoveThread` / the new
`_removeSticky`. Each bumps a `feedMoveTick` counter and records the changed
thread id in `feedMovedIds` on the emitted state (sectioned mode only —
rule 7). Stream-driven rebuilds (sync arrivals) never bump the tick and stay
instant.

Page side (`_buildActivityFeed` host state):
- On a tick change, snapshot the previous `displayItems` and compute a diff
  (pure helper `computeFeedMoveDiff(oldItems, newItems, movedIds)` keyed on
  the rows' feed keys):
  - ghosts = items present only in the old list (the moved row's old
    position, plus any header that vanished with it), anchored after their
    nearest preceding stable item;
  - expanders = items present only in the new list (the moved row's new
    position, plus any header created with it).
  - Stable items are validated to preserve relative order; if not, skip the
    animation (snap, as today).
- Render: splice ghost rows (snapshot of the old item, `IgnorePointer` +
  `ExcludeFocus`, key `ghost_<tick>_<key>`) into the list and drive a single
  `AnimationController` (~300 ms, easeInOutCubic): ghosts get
  `SizeTransition` 1→0, expanders (the real rows at their new positions)
  0→1. One controller for both sides keeps the collapse and expand
  pixel-synchronized; since a moved row's ghost and destination render the
  same content at the same width, their heights match, so total height
  between source and destination is constant — items outside the range never
  shift (the invariant). A source-only change (thread leaving the feed, e.g.
  Move to another focus) collapses without a paired expand.
- Animation completion (or a new tick arriving) clears ghosts and expander
  marks via one setState. Ticks arriving while a diff is pending in the same
  frame coalesce against the original snapshot.
- During the ~300 ms window drop-zone indices include ghosts (acceptable;
  user is mid-action), and keyboard navigation reads bloc items (no ghosts),
  so commands are unaffected.

### E. Flat feeds (rule 7)

Already stable by construction (`contentActivityAt` ordering, bump excluded).
The new behaviours are explicitly gated: move tick and open-next only fire in
sectioned mode (`!_activeTabFlatMode`). State changes in Everything/search
substitute the row in place (existing overlay behaviour) without reordering,
and the open thread stays open.

## Testing

- Unit: `Order.last()` ordering properties; `nextThreadAfterStateChange`
  (below / cross-section / last-before-Done exception / Done no-op / bottom
  thread / single thread); `computeFeedMoveDiff` (simple move, cross-section
  with header add/remove, leave-feed, no-op); `copyWith` bottom-placement
  defaults (extend `thread_copywith_active_test.dart` style); command-level
  changes where the existing harness allows.
- Existing tests touching pin/round-trip behaviour are updated to the new
  semantics.
- Manual `run-app` verification for the animation invariant and open-next
  flows.
