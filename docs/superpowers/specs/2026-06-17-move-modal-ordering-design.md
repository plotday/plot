# Smarter Move-modal focus ordering

**Date:** 2026-06-17
**Status:** Approved design, ready for implementation plan
**Scope:** Flutter app (`apps/plot`) — the "Move thread to focus" modal only

## Problem

The Move modal (`MoveThreadToPriority`, `apps/plot/lib/command/thread.dart:2328`)
orders focuses with `Priority.getRaw(order: PriorityOrder.recent)`. That `recent`
ordering (`apps/plot/lib/store/priority.dart:943`) sorts by `latest_priorities.at
DESC` — the most recent **session** (focuses you *spent time in / visited*), with
alphabetical-by-path as the tiebreaker. The Inbox is partitioned out and pinned to
the bottom; the thread's current focus is filtered out.

So the current order ranks "focuses I've been working in lately," not "focuses I've
recently moved threads into." When a user is triaging — moving a batch of threads —
the most useful target is usually the focus they *just moved the previous thread
into*, and, failing that, a focus in the *same role* as the thread being moved.
Neither signal is used today.

## Goals

Make the Move-modal order more helpful during triage by combining two signals, with
the first taking strict precedence over the second:

1. **Move recency (MRU)** — the user just moved a thread somewhere; good chance the
   next thread goes to the same focus.
2. **Role affinity** — focuses sharing the moved thread's current role rank above
   unrelated focuses. Works with zero history, so it leads before any moves happen.

## Decisions (from brainstorming)

- **Presentation: flat ranked list (tiered sort).** Keep today's single flat
  "Focuses" list; express precedence as sort tiers, not section headers. No visual
  tier labels — it's a pure reorder.
- **Recency window: current session only, in-memory.** Track move destinations only
  for the current app run; resets on restart. No Drift table, no sync, no
  persistence, no time-decay math. Between triage sessions (fresh run, no moves yet),
  role affinity leads.
- **Inbox is NOT pinned.** Per-role Inboxes are reorderable focuses like any other;
  the Inbox participates in the MRU and all tiers normally. The current
  `defaultInbox`/`root` partition-and-pin block is removed.
- **`roleId` is always present.** Per-role Inbox and per-role FYI each belong to a
  role, so a focus's `roleId` (and `thread.priority.roleId`) is a non-null `Uuid`.
  No null-role edge case.
- **Move-modal only.** Compose/file-into-focus pickers are unchanged (YAGNI). The
  recency signal is recorded only on the move path, so it stays purely move-driven.

## The tiers

1. **Tier 1 — recently moved-into** (this session), ordered by MRU position (newest
   first).
2. **Tier 2 — same role**: `roleId == thread.priority.roleId`, excluding focuses
   already in Tier 1.
3. **Tier 3 — everything else**, in the incoming order from `getRaw` (visit-recency,
   then alphabetical).

The thread's current focus is filtered out (unchanged). Inbox/FYI focuses are
ordinary participants in all three tiers.

## Components

### 1. `MoveRecency` — session-scoped in-memory MRU

New file `apps/plot/lib/state/move_recency.dart`. A tiny singleton, not a Bloc — a
session cache shared between the command that records moves and the command that
builds the modal.

```dart
class MoveRecency {
  MoveRecency._();
  static final MoveRecency instance = MoveRecency._();

  final List<Uuid> _recent = []; // newest first, deduped

  /// Most-recently-moved-into focus ids, newest first.
  List<Uuid> get recent => List.unmodifiable(_recent);

  /// Record a move destination: move it to the front, deduped.
  void record(Uuid focusId) {
    _recent.remove(focusId);
    _recent.insert(0, focusId);
  }

  /// Test isolation.
  void clear() => _recent.clear();
}
```

In-memory only means it starts empty every app run; no explicit reset is needed
beyond `clear()` for tests.

### 2. `orderMoveTargets(...)` — pure, testable tiered sort

Lives alongside `MoveRecency` (same file, top-level function) so the ordering logic
is unit-testable without a `BuildContext`, Drift, or the command layer.

```dart
List<Priority> orderMoveTargets({
  required List<Priority> focuses,   // base order from getRaw = visit-recency (Tier 3)
  required List<Uuid> recentMoves,   // MRU, newest first (Tier 1)
  required Uuid currentRoleId,       // thread's current focus role (Tier 2)
}) {
  int tierOf(Priority p) {
    final mru = recentMoves.indexOf(p.id);
    if (mru >= 0) return 0;             // Tier 1
    if (p.roleId == currentRoleId) return 1; // Tier 2
    return 2;                          // Tier 3
  }

  // Stable: original index is the final tiebreaker, so the incoming
  // visit-recency/alpha order survives within Tier 2 and Tier 3, and the
  // MRU order drives Tier 1.
  final indexed = [
    for (var i = 0; i < focuses.length; i++) (i, focuses[i]),
  ];
  indexed.sort((a, b) {
    final ta = tierOf(a.$2), tb = tierOf(b.$2);
    if (ta != tb) return ta.compareTo(tb);
    if (ta == 0) {
      // both Tier 1: MRU order (smaller index = more recent = first)
      return recentMoves.indexOf(a.$2.id).compareTo(recentMoves.indexOf(b.$2.id));
    }
    return a.$1.compareTo(b.$1); // preserve incoming order
  });
  return [for (final e in indexed) e.$2];
}
```

(Final implementation may differ in mechanics, but must be a **stable** tiered sort
with these exact tier rules.)

## Data flow — two touch-points in `thread.dart`

### Record (one line)

In `_applyPriorityMove` (`apps/plot/lib/command/thread.dart:2222`) — the single path
both `MoveToPriority` and `_CreateAndMoveToNewPriority` funnel through — record the
destination alongside the optimistic move:

```dart
MoveRecency.instance.record(priority.id);
```

### Read (replace the partition block)

In `_getMoveCommands` (`apps/plot/lib/command/thread.dart:2344`), replace the
`defaultInbox`/`root` partition-and-pin block (`:2353–2371`) with a straight filter +
tiered sort:

```dart
final priorities = await Priority.getRaw(order: PriorityOrder.recent);
final focuses = priorities.where((p) => p.id != thread.priority.id).toList();
final ordered = orderMoveTargets(
  focuses: focuses,
  recentMoves: MoveRecency.instance.recent,
  currentRoleId: thread.priority.roleId,
);
final commands = ordered
    .map((priority) => MoveToPriority(thread, priority, bloc: bloc))
    .toList();
```

`getRaw(order: PriorityOrder.recent)` is retained — it provides the Tier-3 base
order and supplies `roleId` on each focus. The `Commands(...)` wrapper, `'Focuses'`
group, and `secondaryCommand` (`_CreateAndMoveToNewPriority`) are unchanged.

## Edge cases

- **Fresh app run / no moves yet:** Tier 1 empty → role affinity (Tier 2) leads,
  then visit-recency base order. This is the intended between-sessions behavior.
- **Move into an Inbox/FYI:** floats that focus to Tier 1 next time, like any other
  focus. Inbox is no longer special-cased.
- **A focus that is both recently-moved and same-role:** appears once, in Tier 1.
- **Current focus:** filtered out before sorting (unchanged).
- **Rendering:** `FocusLabel` still brands Inbox via `isInbox`; ordering does not
  affect how rows render.

## Testing (TDD)

`orderMoveTargets` is pure → unit tests in `apps/plot/test/` (e.g.
`apps/plot/test/state/move_recency_test.dart`):

- Empty `recentMoves` → same-role focuses precede unrelated; incoming order preserved
  within each tier.
- Recent moves float above same-role focuses, in MRU order (newest first).
- Same-role focuses precede unrelated focuses.
- Incoming (visit-recency/alpha) order is preserved within Tier 2 and Tier 3.
- A focus that is both recently-moved and same-role appears exactly once, in Tier 1.
- Inbox/FYI focuses participate normally (not pinned, not excluded).

`MoveRecency`:

- `record` moves an existing id to the front (dedup) and prepends a new id
  (newest-first ordering).

Run `cd apps/plot && flutter analyze` before completion.

## Out of scope

- Persisting move recency across app runs.
- Time-decay / count caps on the recency tier.
- Applying the signal to compose / file-into-focus pickers.
- Any server, Drift schema, or sync change.
