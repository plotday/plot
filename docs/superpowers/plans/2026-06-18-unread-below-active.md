# Unread-below-active sort + unread-only filter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move non-active unread threads to the *bottom* of the Active section (active and scheduled threads stay in place when unread), and add a persistent tri-state header toggle that filters the focus feed to unread-only for triage.

**Architecture:** Pure-Dart client change in `apps/plot/`, no schema/Drift/sync changes. The feed's Doing-section grouping moves into a testable pure helper; the unread-only filter is in-memory bloc state applied at the existing display-level `activityFeedViewItems` seam; drag mechanics reuse the existing `resolveDoingDrop`/overlay machinery with a source-aware boundary tweak. Spec: `docs/superpowers/specs/2026-06-18-unread-below-active-sort-and-filter-design.md`.

**Tech Stack:** Flutter, flutter_bloc, forui widgets, Drift (read-only here), `flutter_test`.

## Global Constraints

- UI text is **sentence case** (e.g. "Show only unread threads").
- Widgets import only `flutter/widgets.dart` and `forui/forui.dart`, never `flutter/material.dart`. Bloc is read only in pages/commands, not widgets.
- Every user action affecting state is a `Command` in `apps/plot/lib/command/`.
- Lint must pass: `cd apps/plot && flutter analyze` (zero errors).
- Run a single test: `cd apps/plot && flutter test test/<path>`.
- Adding/removing a Font Awesome glyph requires bumping `FONT_CACHE_VERSION` in `scripts/cache-bust-fonts.sh`.
- No `flutter test` runs against a device; these are pure widget/unit tests.
- Notable user-facing change → add a bullet under `## Next release` in `docs/updates.md`.

## Phase / sequencing

- **Phase A (Tasks 1–4):** the default-view sort change. Shippable on its own (feed reorders correctly; no filter yet).
- **Phase B (Tasks 5–6):** drag constraints for the relocated cluster.
- **Phase C (Tasks 7–12):** the unread-only filter.
- **Phase D (Task 13):** copy + docs sweep.

Each phase leaves the app working. Commit after every task.

## File structure

- Create `apps/plot/lib/state/activity_feed_layout.dart` — pure helper that splits the Doing-eligible threads into the active-by-order list and the bottom non-active-unread cluster. Testable in isolation (mirrors the existing `activity_feed_drop.dart` / `order_repair.dart` pattern).
- Create `apps/plot/test/state/activity_feed_layout_test.dart` — unit tests for the helper.
- Modify `apps/plot/lib/store/thread.dart` — add `markRead` param to the active-drop transition.
- Modify `apps/plot/lib/state/priority.dart` — `_buildUnifiedFeedItems`, `setThread` sticky gating, drag `clusterOf` + `applyActivityFeedThreadDrop`, new filter method, clear-on-open-last.
- Modify `apps/plot/lib/state/priority_state.dart` — `unreadFilterActive` field, `hasUnread` selector, `activityFeedViewItems` filter.
- Modify `apps/plot/lib/widget/activity_feed_drag.dart` — source-aware drop boundaries.
- Modify `apps/plot/lib/widget/unified_header.dart` — toggle button placement.
- Create `apps/plot/lib/command/unread_filter.dart` — `ToggleUnreadFilter` command.
- Modify `apps/plot/lib/page/priority.dart` — back-gesture clears filter first.
- Modify `apps/plot/lib/state/root_provider.dart` (+ route) — auto-apply on notification entry.
- Modify onboarding copy + `docs/updates.md`.

---

## Phase A — Default-view sort

### Task 1: Thread transition that activates without marking read

`asActiveToday` (`thread.dart:5735-5740`) force-clears `unread`. Reordering an active to-do, and promoting an unread thread up into Active, must be able to **keep** the unread dot. Add an opt-out.

**Files:**
- Modify: `apps/plot/lib/store/thread.dart:5735-5740`
- Test: `apps/plot/test/store/thread_as_active_today_test.dart` (create)

**Interfaces:**
- Produces: `Thread asActiveToday({Order? order, bool markRead = true})` — when `markRead` is `false`, the returned thread keeps its current `unread`/`readAt`.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/store/thread_as_active_today_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  test('asActiveToday(markRead: false) keeps an unread thread unread', () {
    final t = Thread(priority: Priority(title: 'p'))
        .asUnreadInDoing(order: const Order(1), urgent: false, importance: 0);
    expect(t.unread, isTrue);

    final reordered = t.asActiveToday(order: const Order(2), markRead: false);
    expect(reordered.unread, isTrue, reason: 'reorder must not mark read');
    expect(reordered.active, isTrue);
    expect(reordered.order, const Order(2));
  });

  test('asActiveToday() default still marks an unread thread read', () {
    final t = Thread(priority: Priority(title: 'p'))
        .asUnreadInDoing(order: const Order(1), urgent: false, importance: 0);
    final activated = t.asActiveToday(order: const Order(2));
    expect(activated.unread, isFalse);
    expect(activated.active, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/store/thread_as_active_today_test.dart`
Expected: FAIL — `asActiveToday` does not accept `markRead`.

- [ ] **Step 3: Implement**

Replace `asActiveToday` (`thread.dart:5735-5740`):

```dart
Thread asActiveToday({Order? order, bool markRead = true}) {
  final effectiveOrder = order ?? _thread.stateOrder ?? Order.last();
  final restored = withScheduleRestored(order: effectiveOrder);
  if (!unread || !markRead) return restored;
  return restored.copyWith(unread: false, readAt: Value(contentTimestamp));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/store/thread_as_active_today_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/test/store/thread_as_active_today_test.dart
git commit -m "feat(thread): asActiveToday(markRead:) to reorder/promote without marking read"
```

---

### Task 2: Pure helper that splits the Doing section

Extract the new grouping/sort into a pure, testable function: active to-dos by `order` (read + unread intermixed), then the non-active unread cluster (urgent DESC, importance DESC, order ASC, id ASC) at the bottom.

**Files:**
- Create: `apps/plot/lib/state/activity_feed_layout.dart`
- Test: `apps/plot/test/state/activity_feed_layout_test.dart`

**Interfaces:**
- Produces:
  ```dart
  typedef DoingSplit = ({List<Thread> active, List<Thread> unreadCluster});
  DoingSplit splitDoingSection(Iterable<Thread> doingEligible);
  ```
  `doingEligible` = threads whose primary section is Doing (active) PLUS non-active unread threads (and the sticky-pinned open thread) that belong at the bottom. The caller decides eligibility; this function only classifies + sorts. Classification: a thread goes to `active` iff `t.isActiveThread`; otherwise to `unreadCluster`.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/state/activity_feed_layout_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_feed_layout.dart';
import 'package:plot/store/store.dart';

Thread _active(int order, {bool unread = false}) {
  var t = Thread(priority: Priority(title: 'p')).asActiveToday(order: Order(order.toDouble()));
  if (unread) t = t.copyWith(unread: true);
  return t;
}

Thread _unread(int order, {bool urgent = false, int importance = 0}) =>
    Thread(priority: Priority(title: 'p'))
        .asUnreadInDoing(order: Order(order.toDouble()), urgent: urgent, importance: importance);

void main() {
  test('active to-dos sort by order; unread active stays among them', () {
    final a1 = _active(1);
    final a2 = _active(2, unread: true);
    final a3 = _active(3);
    final split = splitDoingSection([a3, a1, a2]);
    expect(split.active.map((t) => t.order.value), [1, 2, 3]);
    expect(split.unreadCluster, isEmpty);
  });

  test('non-active unread cluster sorts urgent, importance, order', () {
    final u1 = _unread(5, urgent: false, importance: 0);
    final u2 = _unread(1, urgent: true, importance: 0);
    final u3 = _unread(9, urgent: false, importance: 7);
    final split = splitDoingSection([u1, u2, u3]);
    // urgent first (u2), then higher importance (u3), then u1
    expect(split.unreadCluster, [u2, u3, u1]);
    expect(split.active, isEmpty);
  });

  test('active and unread are separated regardless of input order', () {
    final a = _active(1);
    final u = _unread(1);
    final split = splitDoingSection([u, a]);
    expect(split.active, [a]);
    expect(split.unreadCluster, [u]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/activity_feed_layout_test.dart`
Expected: FAIL — `activity_feed_layout.dart` does not exist.

- [ ] **Step 3: Implement**

```dart
// apps/plot/lib/state/activity_feed_layout.dart
import 'package:plot/store/store.dart';

/// Result of splitting the Doing section into its two ordered groups.
typedef DoingSplit = ({List<Thread> active, List<Thread> unreadCluster});

/// Splits Doing-eligible threads into the active-to-do list (sorted by
/// `order`, read and unread intermixed) and the bottom non-active unread
/// cluster (urgent DESC, importance DESC, order ASC, id ASC).
///
/// A thread is "active" iff [Thread.isActiveThread]; everything else passed
/// in is treated as a bottom-cluster row (the caller only passes non-active
/// unread threads + the sticky-pinned open thread here).
DoingSplit splitDoingSection(Iterable<Thread> doingEligible) {
  final active = <Thread>[];
  final unreadCluster = <Thread>[];
  for (final t in doingEligible) {
    (t.isActiveThread ? active : unreadCluster).add(t);
  }

  active.sort((a, b) {
    final ord = a.order.compareTo(b.order);
    if (ord != 0) return ord;
    return a.id.toString().compareTo(b.id.toString());
  });

  unreadCluster.sort((a, b) {
    if (a.urgent != b.urgent) return a.urgent ? -1 : 1;
    final imp = b.importance.compareTo(a.importance);
    if (imp != 0) return imp;
    final ord = a.order.compareTo(b.order);
    if (ord != 0) return ord;
    return a.id.toString().compareTo(b.id.toString());
  });

  return (active: active, unreadCluster: unreadCluster);
}
```

> Note: if `Order` has no public `.value` getter, assert on `split.active` identity order instead (`expect(split.active, [a1, a2, a3])`). Adjust the test in Step 1 if `flutter analyze` flags `.value`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/state/activity_feed_layout_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/activity_feed_layout.dart apps/plot/test/state/activity_feed_layout_test.dart
git commit -m "feat(feed): pure splitDoingSection helper (active by order; unread cluster at bottom)"
```

---

### Task 3: Rewire `_buildUnifiedFeedItems` to put unread at the bottom of Active

**Files:**
- Modify: `apps/plot/lib/state/priority.dart:1250-1379`
- Test: covered by Task 2's helper unit tests; add a guard test in `apps/plot/test/state/priority_feed_order_test.dart` if a PriorityBloc can be constructed cheaply — otherwise rely on Task 2 + manual run-app verification (see Step 4).

**Interfaces:**
- Consumes: `splitDoingSection` (Task 2).
- The Doing section emits: header, then `split.active` rows, then `split.unreadCluster` rows. Scheduled/Done unchanged.

- [ ] **Step 1: Replace the classification + sort in `_buildUnifiedFeedItems`**

In the loop (`priority.dart:1259-1282`), the current `if (t.unread || _isStickyPinned(t.id))` branch routes ALL unread to a top cluster. Replace the loop body so only **non-active, non-scheduled** unread (plus sticky-pinned) go to the bottom cluster, and active/scheduled threads route to their natural section regardless of read state:

```dart
final doingEligible = <Thread>[];   // active to-dos + bottom unread cluster
final scheduled = <Thread>[];
final activity = <Thread>[];

for (final t in merged) {
  if (t.isActiveThread) {
    doingEligible.add(t);            // active to-dos stay in place (incl. unread)
    continue;
  }
  if (t.isScheduledThread) {
    scheduled.add(t);                // scheduled stays in place (incl. unread)
    continue;
  }
  if (t.unread || _isStickyPinned(t.id)) {
    doingEligible.add(t);            // non-active unread → bottom cluster
    continue;
  }
  activity.add(t);                   // read, non-active → Done
}

final split = splitDoingSection(doingEligible);
```

Delete the old `unreadDoing`/`readDoing` lists and their two `.sort(...)` blocks (`priority.dart:1284-1303`) — sorting now lives in `splitDoingSection`. Keep the `scheduled.sort` and `activity.sort` blocks (1305-1327) unchanged.

- [ ] **Step 2: Replace the Doing render block**

Where the Doing header + rows are emitted (`priority.dart:1334-1346`):

```dart
if (split.active.isNotEmpty || split.unreadCluster.isNotEmpty) {
  items.add(
    AgendaHeaderItem(text: ActivitySectionMarker.encode(ActivitySection.doing)),
  );
  for (final t in split.active) {
    items.add(AgendaThreadItem(t));
  }
  for (final t in split.unreadCluster) {
    items.add(AgendaThreadItem(t));
  }
}
```

Add the import at the top of `priority.dart`:

```dart
import 'package:plot/state/activity_feed_layout.dart';
```

- [ ] **Step 3: Update the doc comment** (`priority.dart:1244-1249`) to describe the new behavior:

```dart
/// Build the unified feed: Doing → Scheduled (per-day) → Activity.
/// Active to-dos hold their `order` position (read and unread intermixed).
/// Non-active unread threads cluster at the BOTTOM of Doing (urgent,
/// importance, order) and drain to Activity (Done) once read and navigated
/// away from. Scheduled unread threads stay in their date slot.
```

- [ ] **Step 4: Verify analyze + run**

Run: `cd apps/plot && flutter analyze`
Expected: no errors.

Run the app via the `run-app` skill, open a focus with unread non-active threads, and confirm: active to-dos stay on top in their order; unread items sit at the bottom of Active; reading one and navigating away drains it to Done.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/priority.dart
git commit -m "feat(feed): unread non-active threads render at the bottom of Active"
```

---

### Task 4: Sticky-pin only non-active unread on open

`setThread` (`priority.dart:3121-3171`) pins ANY opened unread thread into the cluster. In the new model an unread **active** to-do already stays in place, so pinning it is wrong (it would yank it to the bottom cluster). Pin only when the opened thread is non-active.

**Files:**
- Modify: `apps/plot/lib/state/priority.dart:3144-3156`

- [ ] **Step 1: Narrow the sticky-pin condition**

Change the guard from `thread.unread && _activeTabSubscriptionTab == ActivityTab.catchUp` to also require non-active:

```dart
if (thread != null &&
    thread.unread &&
    !thread.isActiveThread &&
    _activeTabSubscriptionTab == ActivityTab.catchUp) {
  _overlay[thread.id] = _Overlay.stickyUnread(
    thread,
    sortKeys: (
      urgent: thread.urgent ? 1 : 0,
      importance: thread.importance,
      activityAt: thread.activityAt,
    ),
  );
  _rebuildActiveTabSection();
}
```

- [ ] **Step 2: Verify analyze + run**

Run: `cd apps/plot && flutter analyze` → no errors.
Run-app: open an unread **active** to-do — it must stay in place (not jump to the bottom cluster) and lose its dot in place. Open an unread **non-active** item — it stays pinned at the bottom until you navigate away, then drains to Done.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/state/priority.dart
git commit -m "fix(feed): only sticky-pin non-active unread threads on open"
```

---

## Phase B — Drag constraints

### Task 5: Drop logic — reorder/promote preserve unread; cluster keyed on active

**Files:**
- Modify: `apps/plot/lib/state/priority.dart:2227-2285` (the `ActivitySection.doing` case in `applyActivityFeedThreadDrop`)
- Test: `apps/plot/test/state/activity_feed_drop_test.dart` (extend)

**Interfaces:**
- `clusterOf(t)` now keys on `t.isActiveThread`, not `t.unread`: active → `DoingCluster.read()` (the single active order-space); non-active → `DoingCluster.unread(urgent, importance)`.
- Landing in the active space uses `asActiveToday(order, markRead: false)` (preserve unread).

- [ ] **Step 1: Write the failing test**

Extend `activity_feed_drop_test.dart` (it already tests `resolveDoingDrop`/`DoingCluster`). Add a unit test for the new `clusterOf` semantics by exercising the helper that you will extract. To keep it pure, add a tiny top-level helper in `activity_feed_drop.dart`:

```dart
// add to apps/plot/lib/state/activity_feed_drop.dart
import 'package:plot/store/store.dart';

DoingCluster doingClusterFor(Thread t) => t.isActiveThread
    ? const DoingCluster.read()
    : DoingCluster.unread(urgent: t.urgent, importance: t.importance);
```

Test:

```dart
// apps/plot/test/state/activity_feed_drop_test.dart  (add)
test('doingClusterFor: active thread -> read cluster regardless of unread', () {
  final activeUnread = Thread(priority: Priority(title: 'p'))
      .asActiveToday(order: const Order(1), markRead: false)
      .copyWith(unread: true);
  expect(doingClusterFor(activeUnread), const DoingCluster.read());
});

test('doingClusterFor: non-active unread -> unread cluster with its bucket', () {
  final u = Thread(priority: Priority(title: 'p'))
      .asUnreadInDoing(order: const Order(1), urgent: true, importance: 3);
  expect(doingClusterFor(u), const DoingCluster.unread(urgent: true, importance: 3));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/activity_feed_drop_test.dart`
Expected: FAIL — `doingClusterFor` undefined.

- [ ] **Step 3: Implement the helper (above) and rewire the drop case**

In `applyActivityFeedThreadDrop`, replace the local `clusterOf` (`priority.dart:2235-2237`) with the shared helper and adjust the active-landing branch (`priority.dart:2277-2284`) to preserve unread:

```dart
final resolution = resolveDoingDrop(
  prev: prevThread == null ? null : doingClusterFor(prevThread),
  next: nextThread == null ? null : doingClusterFor(nextThread),
  dragged: doingClusterFor(dragged),
);
```

```dart
if (destination.unread) {
  updated = dragged.asUnreadInDoing(
    order: doingNewOrder,
    urgent: destination.urgent,
    importance: destination.importance,
  );
} else {
  // Land in the active order-space: become/stay an active to-do, set
  // order, but DON'T mark read — reordering or promoting up must not
  // clear the unread dot. Clear any sticky pin.
  updated = dragged.asActiveToday(order: doingNewOrder, markRead: false);
  _overlay.remove(draggedId);
}
```

Update the `doingBucket` comprehension (`priority.dart:2250-2257`) to use `doingClusterFor` instead of `clusterOf`. Add the import for `doingClusterFor` if not already exported from the same file.

- [ ] **Step 4: Run tests**

Run: `cd apps/plot && flutter test test/state/activity_feed_drop_test.dart` → PASS.
Run: `cd apps/plot && flutter analyze` → no errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/activity_feed_drop.dart apps/plot/lib/state/priority.dart apps/plot/test/state/activity_feed_drop_test.dart
git commit -m "feat(drag): cluster by active-state; reorder/promote preserve unread"
```

---

### Task 6: Source-aware drop boundaries (active can't enter the unread cluster)

`computeActivityFeedDropBoundaries` (`activity_feed_drag.dart:88-232`) emits a slot above every Doing row, source-agnostically. An active drag must only see a single slot at the active/unread boundary (end of active); it must NOT open slots between unread-cluster rows. An unread drag keeps all slots (reorder within cluster + promote up).

**Files:**
- Modify: `apps/plot/lib/widget/activity_feed_drag.dart`
- Test: `apps/plot/test/widget/activity_feed_drag_boundaries_test.dart` (create)

**Interfaces:**
- `computeActivityFeedDropBoundaries({required List<AgendaItem> items, required bool draggingActive, required Set<ThreadId> unreadClusterIds})` — when `draggingActive` is true, suppress the "before" slot for every row in `unreadClusterIds` and keep the boundary slot above the FIRST unread-cluster row (which equals the end-of-active boundary).
- Dispatcher clamp: in `dispatchActivityFeedThreadDrop`, if `draggingActive` and the resolved neighbours are both inside the unread cluster, retarget to the end-of-active boundary.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/widget/activity_feed_drag_boundaries_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/activity_feed_drag.dart';

void main() {
  test('dragging an active thread opens no slots between unread rows', () {
    final active = Thread(priority: Priority(title: 'p'))
        .asActiveToday(order: const Order(1));
    final u1 = Thread(priority: Priority(title: 'p'))
        .asUnreadInDoing(order: const Order(2), urgent: false, importance: 0);
    final u2 = Thread(priority: Priority(title: 'p'))
        .asUnreadInDoing(order: const Order(3), urgent: false, importance: 0);
    final items = <AgendaItem>[
      AgendaHeaderItem(text: ActivitySectionMarker.encode(ActivitySection.doing)),
      AgendaThreadItem(active),
      AgendaThreadItem(u1),
      AgendaThreadItem(u2),
    ];

    final res = computeActivityFeedDropBoundaries(
      items: items,
      draggingActive: true,
      unreadClusterIds: {u1.id, u2.id},
    );
    // A "before" slot exists above u1 (the end-of-active boundary) but NOT above u2.
    final indexOfU1 = items.indexOf(items.firstWhere(
        (i) => i is AgendaThreadItem && i.thread.id == u1.id));
    final indexOfU2 = items.indexOf(items.firstWhere(
        (i) => i is AgendaThreadItem && i.thread.id == u2.id));
    expect(res.before.containsKey(indexOfU1), isTrue);
    expect(res.before.containsKey(indexOfU2), isFalse);
  });

  test('dragging an unread thread keeps slots between unread rows', () {
    final u1 = Thread(priority: Priority(title: 'p'))
        .asUnreadInDoing(order: const Order(2), urgent: false, importance: 0);
    final u2 = Thread(priority: Priority(title: 'p'))
        .asUnreadInDoing(order: const Order(3), urgent: false, importance: 0);
    final items = <AgendaItem>[
      AgendaHeaderItem(text: ActivitySectionMarker.encode(ActivitySection.doing)),
      AgendaThreadItem(u1),
      AgendaThreadItem(u2),
    ];
    final res = computeActivityFeedDropBoundaries(
      items: items,
      draggingActive: false,
      unreadClusterIds: {u1.id, u2.id},
    );
    final indexOfU2 = items.indexOf(items.firstWhere(
        (i) => i is AgendaThreadItem && i.thread.id == u2.id));
    expect(res.before.containsKey(indexOfU2), isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/activity_feed_drag_boundaries_test.dart`
Expected: FAIL — `computeActivityFeedDropBoundaries` does not accept `draggingActive`/`unreadClusterIds`.

- [ ] **Step 3: Implement**

Add the two params to `computeActivityFeedDropBoundaries` (default `draggingActive: false`, `unreadClusterIds: const {}`). In the `AgendaThreadItem` branch for the Doing section (currently the generic `if (!item.pinned)` emit, `activity_feed_drag.dart:180-194`), suppress the slot when dragging active into a non-first cluster row:

```dart
if (item is AgendaThreadItem) {
  if (currentSection == null) continue;
  // ... existing Done handling ...
  final threadId = item.thread.id;
  final inUnreadCluster = unreadClusterIds.contains(threadId);
  // When dragging an ACTIVE thread, the only slot in/around the unread
  // cluster is the boundary above its FIRST row (== end of active). Skip
  // slots above every subsequent cluster row so no gap opens between
  // unread rows.
  final firstClusterRow =
      inUnreadCluster && !_emittedUnreadBoundary;
  if (draggingActive && inUnreadCluster && !firstClusterRow) {
    prevThreadId = threadId.toString();
    continue;
  }
  if (inUnreadCluster) _emittedUnreadBoundary = true;
  // ... existing slot emit ...
}
```

Add a `bool _emittedUnreadBoundary = false;` local at the top of the loop scope. Then thread `draggingActive` + the cluster id-set through `dispatchActivityFeedThreadDrop` and its caller. The caller is the drag controller in `activity_feed_drag.dart` (the `BlockDragController`/`BlockDropZone` integration) — derive `draggingActive` from the dragged payload's thread (`bloc.threadById(payload.blockId)?.isActiveThread ?? false`) and `unreadClusterIds` from the current `split.unreadCluster` (expose it from the bloc/state, e.g. a `Set<ThreadId> get unreadClusterIds` on `PriorityState` populated when building the feed in Task 3).

In `dispatchActivityFeedThreadDrop`, add the clamp: if `draggingActive` and both `prevId` and `nextId` resolve to cluster members, set `nextId` to the first cluster id and `prevId` to the last active id (end-of-active boundary) before calling `applyActivityFeedThreadDrop`.

- [ ] **Step 4: Run tests + analyze**

Run: `cd apps/plot && flutter test test/widget/activity_feed_drag_boundaries_test.dart` → PASS.
Run: `cd apps/plot && flutter analyze` → no errors.
Run-app: drag an active to-do downward — a single placeholder opens at the end of active, none between unread rows; dropping snaps to end of active. Drag an unread item up above an active row — it becomes active and stays put; drag within the cluster — it reorders and sticks.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/activity_feed_drag.dart apps/plot/lib/state/priority.dart apps/plot/lib/state/priority_state.dart apps/plot/test/widget/activity_feed_drag_boundaries_test.dart
git commit -m "feat(drag): source-aware boundaries keep active threads out of the unread cluster"
```

---

## Phase C — Unread-only filter

### Task 7: Filter state + `hasUnread` + `updateUnreadFilter`

**Files:**
- Modify: `apps/plot/lib/state/priority_state.dart` (add field + selector + copyWith)
- Modify: `apps/plot/lib/state/priority.dart` (add `updateUnreadFilter`)
- Test: `apps/plot/test/state/priority_state_test.dart` (extend with `hasUnread`)

**Interfaces:**
- Produces: `bool get hasUnread` on `PriorityState`; `final bool unreadFilterActive` on `PriorityState`; `void updateUnreadFilter(bool active)` on `PriorityBloc`.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/state/priority_state_test.dart (add)
test('hasUnread reflects unread rows in the activity feed', () {
  final priority = Priority(title: 'p');
  final unread = Thread(priority: priority)
      .asUnreadInDoing(order: const Order(1), urgent: false, importance: 0);
  final state = _stateWith(
    priority: priority,
    agendaItems: const [],
  ).copyWith(activityFeedItems: [AgendaThreadItem(unread)]);
  expect(state.hasUnread, isTrue);
  expect(state.copyWith(activityFeedItems: const []).hasUnread, isFalse);
});
```

> If `_stateWith` doesn't expose `activityFeedItems`, set it through whatever constructor/field `PriorityState` uses for the feed (confirm the field name — it is the list `activityFeedViewItems`/`_buildUnifiedFeedItems` writes; in this codebase the built list is surfaced via `activityFeedItems`). Adapt the helper.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/priority_state_test.dart`
Expected: FAIL — `unreadFilterActive`/`hasUnread` undefined.

- [ ] **Step 3: Implement state additions**

In `priority_state.dart`: add `this.unreadFilterActive = false` to the constructor (alongside `filter`/`search`, ~line 126-162), add the field declaration `final bool unreadFilterActive;`, add it to `copyWith`, and add the selector:

```dart
/// True when the focus feed currently contains at least one unread thread.
bool get hasUnread {
  for (final item in activityFeedItems) {
    if (item is AgendaThreadItem && item.thread.unread) return true;
  }
  return false;
}
```

In `priority.dart`, add the bloc method (mirror `updateIconFilter`'s rebuild path, but the unread filter is display-level so it does NOT need a SQL subscription restart — just rebuild the feed view):

```dart
void updateUnreadFilter(bool active) {
  if (state.unreadFilterActive == active) return;
  log.info('Updating unread filter to $active');
  emit(state.copyWith(unreadFilterActive: active));
}
```

- [ ] **Step 4: Run tests + analyze**

Run: `cd apps/plot && flutter test test/state/priority_state_test.dart` → PASS.
Run: `cd apps/plot && flutter analyze` → no errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/priority_state.dart apps/plot/lib/state/priority.dart apps/plot/test/state/priority_state_test.dart
git commit -m "feat(filter): unreadFilterActive state + hasUnread selector + updateUnreadFilter"
```

---

### Task 8: Apply the filter at `activityFeedViewItems`

The display-level getter `activityFeedViewItems` (`priority_state.dart:319-345`) already drops rows + empty section headers. Extend its `keep` predicate to require unread when the filter is on, with the currently-open thread always kept (the pin-while-open rule).

**Files:**
- Modify: `apps/plot/lib/state/priority_state.dart:319-345`
- Test: `apps/plot/test/state/priority_state_test.dart` (extend)

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/state/priority_state_test.dart (add)
test('unread filter keeps unread rows + the open thread, drops read rows', () {
  final priority = Priority(title: 'p');
  final read = Thread(priority: priority).asActiveToday(order: const Order(1));
  final unread = Thread(priority: priority)
      .asUnreadInDoing(order: const Order(2), urgent: false, importance: 0);
  final openRead = Thread(priority: priority).asActiveToday(order: const Order(3));

  final state = _stateWith(priority: priority, agendaItems: const []).copyWith(
    activityFeedItems: [
      AgendaHeaderItem(text: ActivitySectionMarker.encode(ActivitySection.doing)),
      AgendaThreadItem(read),
      AgendaThreadItem(unread),
      AgendaThreadItem(openRead),
    ],
    unreadFilterActive: true,
    thread: Value(openRead), // currently open
  );

  final rows = state.activityFeedViewItems
      .whereType<AgendaThreadItem>()
      .map((i) => i.thread.id)
      .toSet();
  expect(rows, {unread.id, openRead.id});
  expect(rows.contains(read.id), isFalse);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/priority_state_test.dart`
Expected: FAIL — read row still present (filter not applied).

- [ ] **Step 3: Implement**

In `activityFeedViewItems`, change the early-return guard and `keep`:

```dart
List<AgendaItem> get activityFeedViewItems {
  final scope = globalViewScope;
  if (!muteOnly && scope == null && !unreadFilterActive) return activityFeedItems;
  final openId = thread?.id;
  bool keep(Thread t) {
    if (muteOnly && t.muteByThreadId == null) return false;
    if (scope != null && t.priority.id != scope.id) return false;
    if (unreadFilterActive && !t.unread && t.id != openId) return false;
    return true;
  }
  // ... unchanged header-coalescing loop ...
}
```

- [ ] **Step 4: Run tests + analyze**

Run: `cd apps/plot && flutter test test/state/priority_state_test.dart` → PASS.
Run: `cd apps/plot && flutter analyze` → no errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/priority_state.dart apps/plot/test/state/priority_state_test.dart
git commit -m "feat(filter): activityFeedViewItems shows unread-only, pinning the open thread"
```

---

### Task 9: `ToggleUnreadFilter` command + tri-state header button

**Files:**
- Create: `apps/plot/lib/command/unread_filter.dart`
- Modify: `apps/plot/lib/widget/unified_header.dart:759-769`
- Modify: `apps/plot/lib/widget/icon.dart` (add `envelopeDot`/`envelopeCircleCheck` if available)
- Modify: `scripts/cache-bust-fonts.sh` (bump `FONT_CACHE_VERSION`)
- Test: `apps/plot/test/widget/unread_filter_button_test.dart` (create)

**Interfaces:**
- Produces: `ToggleUnreadFilter` command with `.on`/`enabled`/`icon`/`title` reflecting the three states, and a header `Button.icon(ToggleUnreadFilter(context: context))` placed immediately before the menu/search button.

- [ ] **Step 1: Add icons** (verify availability first)

Run: `cd apps/plot && grep -n "envelope" lib/widget/icon.dart` and check `font_awesome_flutter` for `envelopeDot` / `envelopeCircleCheck`. If present, add to `PlotIcon`:

```dart
static const envelopeUnread = FontAwesomeIcons.envelopeDot;       // has unread
static const envelopeAllRead = FontAwesomeIcons.envelopeCircleCheck; // none unread
```

If `envelopeDot` is absent, use `FontAwesomeIcons.messageDot` (already used for `PlotIcon.unread`) for `envelopeUnread`. Bump `FONT_CACHE_VERSION` in `scripts/cache-bust-fonts.sh`.

- [ ] **Step 2: Write the command**

```dart
// apps/plot/lib/command/unread_filter.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

import 'package:plot/command/base.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/icon.dart';

/// Tri-state header toggle for the unread-only feed filter.
/// - no unread: disabled, "No unread threads"
/// - unread, off: tap to filter, "Show only unread threads"
/// - on: highlighted, tap to clear, "Show all threads"
class ToggleUnreadFilter extends Command {
  ToggleUnreadFilter._({required bool active, required this.hasUnread})
    : super(
        title: active ? 'Show all threads' : 'Show only unread threads',
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
        icon: hasUnread ? PlotIcon.envelopeUnread : PlotIcon.envelopeAllRead,
        on: active,
      );

  factory ToggleUnreadFilter({required BuildContext context}) {
    final state = context.read<PriorityBloc>().state;
    return ToggleUnreadFilter._(
      active: state.unreadFilterActive,
      hasUnread: state.hasUnread,
    );
  }

  final bool hasUnread;

  @override
  bool enabled(BuildContext context) => hasUnread;

  @override
  String get title => hasUnread
      ? (on == true ? 'Show all threads' : 'Show only unread threads')
      : 'No unread threads';

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final bloc = context.read<PriorityBloc>();
    bloc.updateUnreadFilter(!bloc.state.unreadFilterActive);
    return const CommandDone();
  }
}
```

> Confirm `Command.title` is not `final` in `base.dart` before overriding it; if it is final, compute the title in the private constructor instead (pass `hasUnread`/`active` and build the string there) and drop the getter override.

- [ ] **Step 3: Place the button before search/menu**

In `_buildMainHeader` (`unified_header.dart:759-764`):

```dart
final List<Widget> trailing = <Widget>[
  Button.icon(NewThread()),
  Button.icon(
    ToggleUnreadFilter(context: context),
    selected: state.unreadFilterActive,
    selectedColor: context.read<ColourSchemeData>().accent, // highlight colour
  ),
  Button.icon(_buildPriorityMenuCommand(state)),
  if (resolvedToolbarPadding.right != 0)
    SizedBox(width: resolvedToolbarPadding.right),
];
```

> The spec says "first, before the search button." The search affordance is `_searchButton()` / `ToggleSearchCommand`; place the unread toggle immediately to its left in whatever row renders search. If the search button is not in `trailing`, locate `_searchButton()`'s call site and insert there. Confirm the highlight colour source (`ColourSchemeData.accent` or the existing selected-button default).

- [ ] **Step 4: Write the widget test**

```dart
// apps/plot/test/widget/unread_filter_button_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/unread_filter.dart';
// + provider/bloc test harness mirroring pro_badge_test.dart's host()

void main() {
  testWidgets('disabled with "No unread threads" when nothing is unread',
      (tester) async {
    // Pump a PriorityBloc whose state.hasUnread == false; assert the
    // command.enabled(context) == false and title == 'No unread threads'.
  });
  testWidgets('enabled "Show only unread threads" when unread exist & off',
      (tester) async { /* ... */ });
  testWidgets('"Show all threads" + on when filtering', (tester) async { /* ... */ });
}
```

Fill these using the `host()`/provider pattern from `pro_badge_test.dart` and a minimally-constructed `PriorityBloc`/`PriorityState` (reuse `_stateWith` from `priority_state_test.dart` via a shared test helper, or construct the state inline). Assert on `ToggleUnreadFilter(context:).enabled(context)` and `.title`/`.on`.

- [ ] **Step 5: Run tests + analyze, then commit**

Run: `cd apps/plot && flutter test test/widget/unread_filter_button_test.dart` → PASS.
Run: `cd apps/plot && flutter analyze` → no errors.

```bash
git add apps/plot/lib/command/unread_filter.dart apps/plot/lib/widget/unified_header.dart apps/plot/lib/widget/icon.dart scripts/cache-bust-fonts.sh apps/plot/test/widget/unread_filter_button_test.dart
git commit -m "feat(filter): tri-state unread toggle in the focus header"
```

---

### Task 10: Back gesture clears the filter first

Mirror the search precedent (`page/priority.dart:731-745`). The unread filter is pure bloc state, so the PopScope can clear it directly — no widget registration needed.

**Files:**
- Modify: `apps/plot/lib/page/priority.dart:731-745`

- [ ] **Step 1: Add the clear-first branch**

In the `onPopInvokedWithResult` callback, after the `tryCloseSearch()` check:

```dart
onPopInvokedWithResult: (didPop, popResult) {
  if (didPop) return;
  final shortcuts = ActivityPanelControllerProvider.maybeOf(context);
  if (shortcuts != null && shortcuts.tryCloseSearch()) return;
  final priorityBloc = context.read<PriorityBloc>();
  if (priorityBloc.state.unreadFilterActive) {
    priorityBloc.updateUnreadFilter(false); // first back clears the filter
    return;                                  // stay in the focus
  }
  returnFromPriorityToSourceTab(context);
},
```

- [ ] **Step 2: Verify analyze + run**

Run: `cd apps/plot && flutter analyze` → no errors.
Run-app (single-panel): toggle the filter on, press back once → filter clears, still in the focus showing the full feed; press back again → leaves the focus.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "feat(filter): back gesture clears the unread filter before leaving the focus"
```

---

### Task 11: Clear the filter when the last unread is opened or drains away

Two paths must turn the filter off so it never sits active over an empty feed:
(a) opening the last remaining unread (the spec's primary, in-session path — the Task-4 sticky-pin keeps the just-opened thread visible while the feed reappears behind it); (b) the **auto-off safety net** — the unread set reaching 0 by any other means (e.g. the last item read on another device syncs in), detected on feed rebuild.

**Files:**
- Modify: `apps/plot/lib/state/priority.dart` (`setThread` near the sticky-pin block; and `_rebuildActiveTabSection`)
- Test: `apps/plot/test/state/priority_last_unread_test.dart` (create, if a bloc is constructible in tests; otherwise verify via run-app and note it)

- [ ] **Step 1: Clear on opening the last unread**

After the sticky-pin block in `setThread` (Task 4), add:

```dart
if (thread != null && thread.unread && state.unreadFilterActive) {
  final otherUnread = state.activityFeedItems.any((item) =>
      item is AgendaThreadItem &&
      item.thread.unread &&
      item.thread.id != thread.id);
  if (!otherUnread) {
    updateUnreadFilter(false); // opening the last unread reveals the full feed
  }
}
```

- [ ] **Step 2: Auto-off safety net on feed rebuild**

In `_rebuildActiveTabSection` (`priority.dart:1173-1242`), after the `emit(...)` that publishes the rebuilt `activityFeedItems`, add a guard that drops a now-pointless filter:

```dart
// Auto-off: if the filter is on but nothing is unread any more (e.g. the
// last unread was read on another device and synced in), release it so we
// never show an empty filtered feed behind a disabled toggle.
if (state.unreadFilterActive && !state.hasUnread) {
  emit(state.copyWith(unreadFilterActive: false));
}
```

Place this where `state` already reflects the new `activityFeedItems` (so `hasUnread` is current). Guard against the open-thread exception: if `state.thread?.unread == true` the feed still has unread, so `hasUnread` stays true and the filter is kept — correct.

- [ ] **Step 3: Verify analyze + run**

Run: `cd apps/plot && flutter analyze` → no errors.
Run-app (multi-panel): with several unread, filter on, click through them; opening the LAST one clears the filter (full feed reappears in the list panel) while the opened thread stays visible until you navigate away. (Single-panel: opening the last unread navigates into it; backing out lands on the full feed.)

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/state/priority.dart
git commit -m "feat(filter): clear unread filter when opening the last unread or it drains away"
```

---

### Task 12: Auto-apply the filter on notification entry

When a focus is opened by tapping a notification, enable the unread filter once (if there is unread). Hook the notification navigation in `root_provider.dart:370` (`_navigateToNotificationTarget`).

**Files:**
- Modify: `apps/plot/lib/state/root_provider.dart` (pass an `unreadOnly` intent into the priority route)
- Modify: `apps/plot/lib/page/priority.dart` (apply once after first load when the intent is set)

- [ ] **Step 1: Thread an `openUnreadOnly` flag from notification routes to the priority page**

Add an optional `bool openUnreadOnly = false` to `PriorityRoute` / `NotificationLandingRoute` params. In `_navigateToNotificationTarget`, set `openUnreadOnly: true` on the priority route used for the notification-landing (multi-thread) and no-thread cases. (For single-thread deep links, opening the thread + Task 11's clear-on-last makes the filter moot; leave those as-is.)

- [ ] **Step 2: Apply once in the priority page**

Where `PriorityPage` first loads its `PriorityBloc` (after the feed is available), if `widget.openUnreadOnly` and `bloc.state.hasUnread`, call `bloc.updateUnreadFilter(true)` exactly once (guard with a `_appliedUnreadIntent` bool so rebuilds don't re-apply).

- [ ] **Step 3: Verify analyze + run**

Run: `cd apps/plot && flutter analyze` → no errors.
Run-app or trigger a local notification that lands on a focus with unread → the focus opens filtered to unread. Normal navigation into the focus does NOT filter.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/state/root_provider.dart apps/plot/lib/page/priority.dart
git commit -m "feat(filter): auto-apply unread filter when opening a focus from a notification"
```

> Optional follow-up (not a task): keyboard shortcut `⌘⇧U` / `Ctrl+Shift+U` bound to `ToggleUnreadFilter` via `platformSingleActivator(LogicalKeyboardKey.keyU, shift: true)`, gated on `hasUnread`. Add only if desired.

---

## Phase D — Copy & docs

### Task 13: Sweep old "top of Active" copy + updates.md

**Files:**
- Modify: onboarding/guidance copy + seeded threads that describe the old behavior
- Modify: `docs/updates.md`

- [ ] **Step 1: Find the stale copy**

Run:
```bash
cd /Users/kris.braun/code/plot
grep -rin "top of active\|arrive at the top\|top of the list\|top of your" apps/plot/lib apps/plot/assets workers public/twists twists connectors public/connectors 2>/dev/null
```
Also search onboarding tool/thread content for "Active" descriptions. Inspect each hit; update any that claim new/updated threads arrive at the **top** of Active to say they now arrive at the **bottom** of Active (committed to-dos stay on top).

- [ ] **Step 2: Reword each hit**

Edit each confirmed location to the new behavior, e.g.:
`New and updated threads arrive at the top of Active` → `New and updated threads arrive at the bottom of Active, below your committed to-dos`.

- [ ] **Step 3: Add the updates.md entry**

Under `## Next release` in `docs/updates.md`, add to a `### Focuses` section (create it above `### Fixes` if absent):

```markdown
- Your active to-dos now stay put at the top of a focus — new and unread items arrive below them, so incoming messages no longer push your committed work down. Use the new envelope toggle in the header to see only unread.
```

- [ ] **Step 4: Verify + commit**

Run: `cd apps/plot && flutter analyze` → no errors (in case any Dart string copy changed).

```bash
git add -A
git commit -m "docs: reword 'top of Active' copy for the new sort + updates.md entry"
```

---

## Self-review notes (for the executor)

- **Type/name consistency:** `splitDoingSection` → `DoingSplit` (`{active, unreadCluster}`); `doingClusterFor(Thread)` shared by feed + drag; `asActiveToday({Order? order, bool markRead})`; `updateUnreadFilter(bool)`; `unreadFilterActive` / `hasUnread`. Use these exact names across tasks.
- **Things to confirm against the live code before coding each task** (the plan flags them inline): the exact feed-list field name on `PriorityState` (`activityFeedItems`) the view getter reads; whether `Command.title` is `final`; the highlight-colour source for a selected `Button.icon`; the search button's exact call site for placement; and whether `Order` exposes `.value` (test assertions).
- **No schema/sync/Drift changes** — do not bump `Store.schemaVersion`.
- **Phase A is independently shippable**; if review wants to land it first, stop after Task 4, run `flutter analyze` + the Phase-A tests, and open a PR before starting Phase B.
