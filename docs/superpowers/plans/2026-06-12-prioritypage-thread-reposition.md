# PriorityPage Thread Repositioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Immediate (animated) thread repositioning on state changes in focus feeds, rule-2/3 open-next navigation, bottom insertion for new to-do/scheduled items, and removal of the 1.5s sticky-move delay.

**Architecture:** Remove the sticky-todo pin machinery from `PriorityBloc` (state changes reposition immediately); keep the sticky-unread pin while a thread is open but drop it the instant the user navigates away. Pure helpers decide open-next navigation (`feed_navigation.dart`) and compute the move-animation diff (`feed_move_diff.dart`); the bloc stamps a `moveGen` generation + moved-ids on `ActivityFeedTabData` when a user state change rebuilds the sectioned feed, and the page renders collapsing ghosts + expanding rows driven by one `AnimationController`. Flat feeds (Everything/search/filter) are excluded from all of it.

**Tech Stack:** Flutter (no material), flutter_bloc/Cubit, Drift-backed `Thread` store model, `flutter test`.

**Spec:** `docs/superpowers/specs/2026-06-12-prioritypage-thread-reposition-design.md`

**Conventions for every commit in this plan:** run from repo root; stage exact paths and commit path-scoped (concurrent agents share the index):
`git add <paths> && git commit -m "<msg>" -- <paths>`

---

### Task 1: `Order.last()`

**Files:**
- Modify: `apps/plot/lib/util/order.dart`
- Test: `apps/plot/test/util/order_test.dart` (create)

- [x] **Step 1: Write the failing test**

Create `apps/plot/test/util/order_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/order.dart';

void main() {
  group('Order.last', () {
    test('sorts after Order.first and between-derived orders', () {
      final top = Order.first();
      final afterTop = Order.between(top, null);
      final bottom = Order.last();
      // Order.first is a negative timestamp (top of an ASC list);
      // Order.last is a positive timestamp, strictly after anything
      // assigned earlier.
      expect(bottom.compareTo(top), greaterThan(0));
      expect(bottom.compareTo(afterTop) >= 0, isTrue);
      expect(bottom.value, greaterThan(0));
    });

    test('Order.between(prev, null) extends a bottom-append chain', () {
      final first = Order.last();
      final second = Order.between(first, null);
      final third = Order.between(second, null);
      expect(second.compareTo(first), greaterThan(0));
      expect(third.compareTo(second), greaterThan(0));
    });
  });
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/util/order_test.dart`
Expected: FAIL — `Order.last` is not defined.

- [x] **Step 3: Implement `Order.last()`**

In `apps/plot/lib/util/order.dart`, below `Order.first()`:

```dart
  /// Creates an order value that places the new item at the visual BOTTOM
  /// of its list (largest value, sorted ASC). A positive now-timestamp is
  /// strictly larger than every order assigned earlier — [Order.first]'s
  /// negative values, [Order.between] midpoints, and one-sided bounds all
  /// derive from an earlier wall clock — so no neighbour scan is needed.
  /// NOTE: two `last()` calls in the same millisecond tie-break randomly;
  /// for bulk appends chain `Order.between(prev, null)` after the first.
  Order.last() : this(_first());
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/util/order_test.dart`
Expected: PASS (2 tests).

- [x] **Step 5: Commit**

```bash
git add apps/plot/lib/util/order.dart apps/plot/test/util/order_test.dart
git commit -m "feat(app): add Order.last() for bottom-of-list placement" -- apps/plot/lib/util/order.dart apps/plot/test/util/order_test.dart
```

---

### Task 2: Bottom placement defaults in the Thread store model

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (4 sites)
- Test: `apps/plot/test/store/thread_bottom_placement_test.dart` (create)

- [x] **Step 1: Write the failing tests**

Create `apps/plot/test/store/thread_bottom_placement_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

Priority _priority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: Order(0),
    root: false,
    unread: false,
    role: 'member',
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

/// New to-do and newly scheduled threads append to the BOTTOM of their
/// section / day. Bottom placement uses [Order.last] — a positive
/// timestamp — while top placement ([Order.first]) is negative, so the
/// sign is a deterministic proxy for "appended at the bottom".
void main() {
  group('bottom placement on activation', () {
    test('marking to-do without an explicit order appends at the bottom', () {
      final inactive = Thread(priority: _priority());
      final activated = inactive.copyWith(todo: true);
      expect(activated.todo, isTrue);
      expect(activated.rawStateOrder, isNotNull);
      expect(activated.order.value, greaterThan(0));
    });

    test('marking to-do honors an explicitly passed order', () {
      final inactive = Thread(priority: _priority());
      final activated = inactive.copyWith(todo: true, order: const Order(-5));
      expect(activated.order.value, -5);
    });

    test('date promotion of an inactive thread appends at the bottom', () {
      final draft = Thread(priority: _priority(), draft: true);
      final scheduled = draft.copyWith(
        on: Value(CustomDateRange(Date(2026, 1, 1), null)),
      );
      expect(scheduled.active, isTrue);
      expect(scheduled.rawStateOrder, isNotNull);
      expect(scheduled.order.value, greaterThan(0));
    });

    test('asActiveToday with no prior state order appends at the bottom', () {
      final inactive = Thread(priority: _priority());
      expect(inactive.rawStateOrder, isNull);
      final active = inactive.asActiveToday();
      expect(active.order.value, greaterThan(0));
    });

    test('asScheduled with no prior state order appends at the bottom', () {
      final inactive = Thread(priority: _priority());
      final scheduled = inactive.asScheduled(Date(2026, 6, 20));
      expect(scheduled.order.value, greaterThan(0));
    });
  });
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `cd apps/plot && flutter test test/store/thread_bottom_placement_test.dart`
Expected: FAIL — `order.value` is negative (Order.first) in the no-explicit-order tests.

- [x] **Step 3: Switch the four defaults to `Order.last()`**

In `apps/plot/lib/store/thread.dart`:

(a) `copyWith` `todo == true` branch (~line 6234):

```dart
    // Handle personal to-do state.
    if (todo == true) {
      tsActive = true;
      tsStateOn = Value(Thread.todoNowDate);
      tsStateAt = const Value(null);
      // Honor an explicitly-passed order (drag-drop positions rows
      // precisely); otherwise a newly-activated to-do appends to the
      // BOTTOM of Active.
      tsStateOrder = order != null ? Value(order) : Value(Order.last());
      stateDirty = true;
    }
```

(b) promote-to-active on date set (~line 6201):

```dart
        if (settingDate && !_thread.active) {
          tsActive = true;
          // Promoting an inactive thread to active — populate state_order
          // when the caller didn't pass one and no prior order exists, so
          // Doing/Scheduled drag-reorders against this row sort
          // deterministically. Newly scheduled items append to the BOTTOM
          // of their day. See [Thread.order] doc for the failure mode a
          // NULL state_order causes.
          if (order == null && _thread.stateOrder == null) {
            tsStateOrder = Value(Order.last());
          }
        }
```

(c) `asActiveToday` / `asScheduled` fallbacks (~lines 5670, 5681): change both
`final effectiveOrder = order ?? _thread.stateOrder ?? Order.first();` to

```dart
    final effectiveOrder = order ?? _thread.stateOrder ?? Order.last();
```

(d) `addToTodoWithPropagation` (~line 6584): change
`stateOrder: Value(Order.first()),` to

```dart
      stateOrder: Value(Order.last()),
```

- [x] **Step 4: Run tests to verify they pass (plus existing copyWith suites)**

Run: `cd apps/plot && flutter test test/store/thread_bottom_placement_test.dart test/store/thread_copywith_active_test.dart test/store/thread_copywith_done_bump_test.dart test/store/thread_todo_predicate_test.dart`
Expected: PASS. (The existing suites assert `rawStateOrder` is non-null, not its sign — they keep passing.)

- [x] **Step 5: Commit**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/test/store/thread_bottom_placement_test.dart
git commit -m "feat(app): new to-do and scheduled threads append to the bottom of their section" -- apps/plot/lib/store/thread.dart apps/plot/test/store/thread_bottom_placement_test.dart
```

---

### Task 3: Open-next navigation helper (rules 2 & 3)

**Files:**
- Create: `apps/plot/lib/state/feed_navigation.dart`
- Test: `apps/plot/test/state/feed_navigation_test.dart` (create)

- [x] **Step 1: Write the failing tests**

Create `apps/plot/test/state/feed_navigation_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/state/feed_navigation.dart';
import 'package:plot/store/store.dart';

Priority _priority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: Order(0),
    root: false,
    unread: false,
    role: 'member',
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

AgendaHeaderItem _header(ActivitySection s, {Date? date}) => AgendaHeaderItem(
  date: date,
  text: ActivitySectionMarker.encode(s),
);

void main() {
  final priority = _priority();
  Thread thread(String title) => Thread(priority: priority, title: title);
  AgendaThreadItem row(Thread t) => AgendaThreadItem(t);

  final a = thread('a');
  final b = thread('b');
  final c = thread('c');
  final done1 = thread('done1');

  group('nextThreadAfterStateChange', () {
    test('opens the thread below within the same section', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        row(b),
        row(c),
      ];
      final nav = nextThreadAfterStateChange(items, a.id);
      expect(nav.open?.id, b.id);
      expect(nav.stay, isFalse);
    });

    test('crosses from Active into Scheduled', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        _header(ActivitySection.scheduled, date: Date(2026, 6, 20)),
        row(b),
      ];
      final nav = nextThreadAfterStateChange(items, a.id);
      expect(nav.open?.id, b.id);
    });

    test('last thread before Done opens the previous thread above', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        row(b),
        _header(ActivitySection.activity),
        row(done1),
      ];
      final nav = nextThreadAfterStateChange(items, b.id);
      expect(nav.open?.id, a.id, reason: 'works bottom-up: prefer above');
      expect(nav.stay, isFalse);
    });

    test('last thread before Done with nothing above falls through to Done',
        () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        _header(ActivitySection.activity),
        row(done1),
      ];
      final nav = nextThreadAfterStateChange(items, a.id);
      expect(nav.open?.id, done1.id);
    });

    test('changed thread in Done stays open (rule 3)', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        _header(ActivitySection.activity),
        row(done1),
        row(b),
      ];
      final nav = nextThreadAfterStateChange(items, done1.id);
      expect(nav.open, isNull);
      expect(nav.stay, isTrue);
    });

    test('bottom thread with no Done section opens the thread above', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        row(b),
      ];
      final nav = nextThreadAfterStateChange(items, b.id);
      expect(nav.open?.id, a.id);
    });

    test('only thread in the feed: no navigation, not a stay', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
      ];
      final nav = nextThreadAfterStateChange(items, a.id);
      expect(nav.open, isNull);
      expect(nav.stay, isFalse);
    });

    test('changed thread not in the list stays open', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
      ];
      final nav = nextThreadAfterStateChange(items, b.id);
      expect(nav.open, isNull);
      expect(nav.stay, isTrue);
    });
  });
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `cd apps/plot && flutter test test/state/feed_navigation_test.dart`
Expected: FAIL — `feed_navigation.dart` does not exist.

- [x] **Step 3: Implement the helper**

Create `apps/plot/lib/state/feed_navigation.dart`:

```dart
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Navigation decision after an explicit state change on the open thread.
///
/// [open]: the thread to open, or null for no navigation.
/// [stay]: the changed thread should stay open — it renders in Done
/// (rule 3), isn't in the list, or the feed is flat. Distinguishes "stay
/// put" from "nothing left to open" ([open] null, [stay] false), which
/// lets Done's caller fall back to the compose page.
typedef StateChangeNav = ({Thread? open, bool stay});

/// Decide which thread to open after the user changes the state of
/// [changedId] while it is the open thread, per the reposition spec:
///
/// - The decision is computed against the PRE-change [items] (call this
///   before applying the optimistic update).
/// - Threads rendered in Active (Doing, including the unread cluster) or
///   Scheduled open the next thread below, across sections.
/// - Exception: when the changed thread is the last one before the Done
///   section and there are threads above it, the previous thread above is
///   opened instead (supports working bottom-up).
/// - In the Done section the changed thread stays open.
StateChangeNav nextThreadAfterStateChange(
  List<AgendaItem> items,
  ThreadId changedId,
) {
  // Walk the feed, tracking each thread row's section from the
  // marker-encoded headers above it.
  ActivitySection? section;
  final rows = <({Thread thread, ActivitySection? section})>[];
  var changedIndex = -1;
  for (final item in items) {
    item.when<void>(
      header: (h) {
        final marker = h.text == null
            ? null
            : ActivitySectionMarker.tryDecode(h.text!);
        if (marker != null) section = marker.section;
      },
      activity: (a) {
        if (a.thread.id == changedId && changedIndex == -1) {
          changedIndex = rows.length;
        }
        rows.add((thread: a.thread, section: section));
      },
    );
  }

  if (changedIndex == -1) return (open: null, stay: true);
  if (rows[changedIndex].section == ActivitySection.activity) {
    return (open: null, stay: true);
  }

  final below = changedIndex + 1 < rows.length ? rows[changedIndex + 1] : null;
  final above = changedIndex > 0 ? rows[changedIndex - 1] : null;

  if (below != null && below.section != ActivitySection.activity) {
    return (open: below.thread, stay: false);
  }
  if (below != null) {
    // The changed thread was the last one before Done: prefer the thread
    // above; fall through to the first Done thread when nothing is above.
    return (open: (above ?? below).thread, stay: false);
  }
  return (open: above?.thread, stay: false);
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `cd apps/plot && flutter test test/state/feed_navigation_test.dart`
Expected: PASS (8 tests).

- [x] **Step 5: Commit**

```bash
git add apps/plot/lib/state/feed_navigation.dart apps/plot/test/state/feed_navigation_test.dart
git commit -m "feat(app): pure open-next decision helper for thread state changes" -- apps/plot/lib/state/feed_navigation.dart apps/plot/test/state/feed_navigation_test.dart
```

---

### Task 4: Move-diff helper (rule 6 input)

**Files:**
- Create: `apps/plot/lib/state/feed_move_diff.dart`
- Test: `apps/plot/test/state/feed_move_diff_test.dart` (create)

- [x] **Step 1: Write the failing tests**

Create `apps/plot/test/state/feed_move_diff_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/state/feed_move_diff.dart';
import 'package:plot/store/store.dart';

Priority _priority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: Order(0),
    root: false,
    unread: false,
    role: 'member',
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

AgendaHeaderItem _header(ActivitySection s, {Date? date}) => AgendaHeaderItem(
  date: date,
  text: ActivitySectionMarker.encode(s),
);

void main() {
  final priority = _priority();
  Thread thread(String title) => Thread(priority: priority, title: title);
  AgendaThreadItem row(Thread t) => AgendaThreadItem(t);

  final a = thread('a');
  final b = thread('b');
  final c = thread('c');
  final hDoing = _header(ActivitySection.doing);
  final hDone = _header(ActivitySection.activity);

  group('computeFeedMoveDiff', () {
    test('single move within the list: one ghost, one expander', () {
      final oldItems = [hDoing, row(a), row(b), row(c)];
      final newItems = [hDoing, row(a), row(c), row(b)];
      final diff = computeFeedMoveDiff(oldItems, newItems, {b.id});
      expect(diff.ghosts, hasLength(1));
      expect(diff.ghosts.single.anchorKey, feedItemKey(row(a)));
      expect(diff.expandingKeys, {feedItemKey(row(b))});
    });

    test('cross-section move with a header removal ghosts the header too',
        () {
      final day = _header(ActivitySection.scheduled, date: Date(2026, 6, 20));
      final oldItems = [hDoing, row(a), day, row(b), hDone, row(c)];
      // b marked done: its day bucket disappears, b lands at top of Done.
      final newItems = [hDoing, row(a), hDone, row(b), row(c)];
      final diff = computeFeedMoveDiff(oldItems, newItems, {b.id});
      // Ghosts: the day header and b's old row, both anchored after a.
      expect(diff.ghosts, hasLength(2));
      expect(
        diff.ghosts.map((g) => g.anchorKey),
        everyElement(feedItemKey(row(a))),
      );
      expect(diff.expandingKeys, {feedItemKey(row(b))});
    });

    test('thread leaving the feed: ghost only, no expander', () {
      final oldItems = [hDoing, row(a), row(b)];
      final newItems = [hDoing, row(a)];
      final diff = computeFeedMoveDiff(oldItems, newItems, {b.id});
      expect(diff.ghosts, hasLength(1));
      expect(diff.expandingKeys, isEmpty);
    });

    test('identical lists produce an empty diff even with movedIds', () {
      final items = [hDoing, row(a), row(b)];
      final diff = computeFeedMoveDiff(items, items, {b.id});
      expect(diff.isEmpty, isTrue);
    });

    test('reordered stable rows bail out to an empty diff', () {
      final oldItems = [hDoing, row(a), row(b), row(c)];
      final newItems = [hDoing, row(b), row(a), row(c)];
      // c is "moved" but a and b also swapped — ambiguous, snap.
      final diff = computeFeedMoveDiff(oldItems, newItems, {c.id});
      expect(diff.isEmpty, isTrue);
    });

    test('mass changes beyond the cap bail out', () {
      final oldItems = [hDoing, for (var i = 0; i < 14; i++) row(thread('o$i'))];
      final newItems = [hDoing, for (var i = 0; i < 14; i++) row(thread('n$i'))];
      final diff = computeFeedMoveDiff(oldItems, newItems, const {});
      expect(diff.isEmpty, isTrue);
    });
  });
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `cd apps/plot && flutter test test/state/feed_move_diff_test.dart`
Expected: FAIL — `feed_move_diff.dart` does not exist.

- [x] **Step 3: Implement the diff**

Create `apps/plot/lib/state/feed_move_diff.dart`:

```dart
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Identity key for feed items used by the move diff and ghost splicing.
/// Section headers key on their marker-encoded text, day headers on their
/// date, thread rows on thread id (+ association disambiguator) — matching
/// the page's widget-key identities.
String feedItemKey(AgendaItem item) => item.when(
  header: (h) =>
      h.date != null ? 'h_date_${h.date}' : 'h_text_${h.text}',
  activity: (a) => 't_${a.thread.id}'
      '${a.thread.occurrence != null ? '_${a.thread.occurrence}' : ''}'
      '${a.thread.isLinkScheduleInstance ? '_link' : ''}'
      '${a.isAssociated ? '_assoc_${a.associationParentId ?? ''}' : ''}',
);

/// A collapsing ghost: [item]'s pre-move row, rendered directly after the
/// stable item with key [anchorKey] (null = at the very top of the list).
class FeedGhost {
  const FeedGhost({required this.item, required this.anchorKey});
  final AgendaItem item;
  final String? anchorKey;
}

/// The animated difference between two sectioned-feed item lists.
/// [ghosts] collapse (height 1 → 0) at the source; rows/headers whose keys
/// are in [expandingKeys] expand (0 → 1) at the destination. Driven by one
/// shared animation so total height between source and destination stays
/// constant — nothing outside that range shifts.
class FeedMoveDiff {
  const FeedMoveDiff({required this.ghosts, required this.expandingKeys});

  static const empty = FeedMoveDiff(ghosts: [], expandingKeys: {});

  final List<FeedGhost> ghosts;
  final Set<String> expandingKeys;

  bool get isEmpty => ghosts.isEmpty && expandingKeys.isEmpty;
}

/// Diff [oldItems] → [newItems] for a state-change move animation.
///
/// [movedIds] are the threads whose state the user explicitly changed;
/// their rows are treated as removed-from-old + added-to-new even when
/// present in both lists. Every other item present in both lists is
/// "stable". When stable items don't preserve their relative order — or
/// the change is too large to be a state-change move ([maxAnimatedItems])
/// — the diff is ambiguous and [FeedMoveDiff.empty] is returned so the
/// caller snaps instead of animating.
FeedMoveDiff computeFeedMoveDiff(
  List<AgendaItem> oldItems,
  List<AgendaItem> newItems,
  Set<ThreadId> movedIds, {
  int maxAnimatedItems = 12,
}) {
  bool isMoved(AgendaItem item) =>
      item is AgendaThreadItem && movedIds.contains(item.thread.id);

  final oldKeys = [for (final i in oldItems) feedItemKey(i)];
  final newKeys = [for (final i in newItems) feedItemKey(i)];

  // Nothing repositioned (e.g. an in-place field edit) — no animation.
  if (oldKeys.length == newKeys.length) {
    var identical = true;
    for (var i = 0; i < oldKeys.length; i++) {
      if (oldKeys[i] != newKeys[i]) {
        identical = false;
        break;
      }
    }
    if (identical) return FeedMoveDiff.empty;
  }

  final oldKeySet = oldKeys.toSet();
  final newKeySet = newKeys.toSet();
  // Duplicate keys make identity ambiguous — snap.
  if (oldKeySet.length != oldKeys.length ||
      newKeySet.length != newKeys.length) {
    return FeedMoveDiff.empty;
  }

  // Ghosts: removed items plus the moved rows' old positions, each
  // anchored to the nearest stable item above it in the old list.
  final ghosts = <FeedGhost>[];
  final stableOld = <String>[];
  String? anchor;
  for (var i = 0; i < oldItems.length; i++) {
    if (!isMoved(oldItems[i]) && newKeySet.contains(oldKeys[i])) {
      anchor = oldKeys[i];
      stableOld.add(oldKeys[i]);
    } else {
      ghosts.add(FeedGhost(item: oldItems[i], anchorKey: anchor));
    }
  }

  // Expanders: added items plus the moved rows' new positions.
  final expanding = <String>{};
  final stableNew = <String>[];
  for (var i = 0; i < newItems.length; i++) {
    if (isMoved(newItems[i]) || !oldKeySet.contains(newKeys[i])) {
      expanding.add(newKeys[i]);
    } else {
      stableNew.add(newKeys[i]);
    }
  }

  if (ghosts.isEmpty && expanding.isEmpty) return FeedMoveDiff.empty;
  if (ghosts.length + expanding.length > maxAnimatedItems) {
    return FeedMoveDiff.empty;
  }

  // The size-transition invariant requires stable rows to keep their
  // relative order; bail out (snap) when they don't.
  if (stableOld.length != stableNew.length) return FeedMoveDiff.empty;
  for (var i = 0; i < stableOld.length; i++) {
    if (stableOld[i] != stableNew[i]) return FeedMoveDiff.empty;
  }

  return FeedMoveDiff(
    ghosts: List.unmodifiable(ghosts),
    expandingKeys: Set.unmodifiable(expanding),
  );
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `cd apps/plot && flutter test test/state/feed_move_diff_test.dart`
Expected: PASS (6 tests).

- [x] **Step 5: Commit**

```bash
git add apps/plot/lib/state/feed_move_diff.dart apps/plot/test/state/feed_move_diff_test.dart
git commit -m "feat(app): pure move-diff helper for feed reposition animation" -- apps/plot/lib/state/feed_move_diff.dart apps/plot/test/state/feed_move_diff_test.dart
```

---

### Task 5: PriorityBloc surgery — remove pins, immediate sticky removal, move generation

**Files:**
- Modify: `apps/plot/lib/state/priority.dart`
- Modify: `apps/plot/lib/state/activity_section.dart` (`ActivityFeedTabData`)
- Modify: `apps/plot/lib/state/priority_state.dart` (getters)

No new unit tests in this task (the sticky overlay is private bloc state driven
by Drift streams; behaviour is covered by the pure helpers above plus
`flutter analyze` and the existing state suites). Steps:

- [x] **Step 1: Trim `_Overlay`**

In `apps/plot/lib/state/priority.dart` replace the `_Overlay` class
(constructor params, `stickyTodo` factory, fields) so only these remain:

```dart
class _Overlay {
  const _Overlay({
    required this.expected,
    this.watched = _OptimisticOverride._defaultWatched,
    this.catchUpSortKeys,
    this.sticky = false,
  });

  /// Expect the thread to drop out of the active tab. Settled when the
  /// stream no longer returns it.
  const _Overlay.drop({
    Set<_OverrideField> watched = _OptimisticOverride._defaultWatched,
  }) : this(expected: null, watched: watched);

  /// Sticky-unread: a Catch up thread the user just opened should remain
  /// visible at its pre-read sort position while it is open. The snapshot
  /// is frozen as *read* (`unread: false`) so the unread dot clears the
  /// moment the thread is opened, while the entry's presence (matched via
  /// [PriorityBloc._isStickyPinned]) keeps the row pinned in the unread
  /// cluster regardless of that flag. Never auto-settles — cleared the
  /// moment the user navigates away ([PriorityBloc._removeSticky]) or by
  /// explicit triggers (tab switch, archive, drop-to-Done).
  factory _Overlay.stickyUnread(
    Thread thread, {
    required ({int urgent, int importance, DateTime activityAt}) sortKeys,
  }) => _Overlay(
    expected: thread.copyWith(unread: false),
    watched: const <_OverrideField>{},
    catchUpSortKeys: sortKeys,
    sticky: true,
  );

  final Thread? expected;
  final Set<_OverrideField> watched;
  final ({int urgent, int importance, DateTime activityAt})? catchUpSortKeys;
  final bool sticky;

  /// True when [actual] (the stream's copy, or null) makes this overlay
  /// safe to drop. Sticky entries never settle implicitly.
  bool settled(Thread? actual) {
    if (sticky) return false;
    if (expected == null) return actual == null;
    if (actual == null) return false;
    for (final field in watched) {
      if (!_OptimisticOverride._matches(field, actual, expected!)) return false;
    }
    return true;
  }
}
```

(Delete the `stickyTodo` factory, `pinnedSection`, `pinnedInUnread`, and the
class-doc sentences about the post-unfocus grace window.)

- [x] **Step 2: Remove pin fields/methods; add move-generation fields**

Around the bloc fields (current ~lines 699–768):
- Delete `static const _stickyMoveDelay = ...`, `_stickyRemovalTimers`,
  `_toggleOriginal`, `toggleOriginalFor`, `_pinnedSectionFor`,
  `_isPinnedInUnread`.
- Simplify `_isStickyPinned` to:

```dart
  /// Whether [id] has a sticky-unread overlay entry — the open thread the
  /// user just read holds its position (with the dot already cleared)
  /// until they navigate away.
  bool _isStickyPinned(ThreadId id) => _overlay[id]?.sticky ?? false;
```

- Add the move-generation fields next to `_overlay`:

```dart
  /// Monotonic generation for explicit user state-change rebuilds of the
  /// sectioned feed. Stamped onto [ActivityFeedTabData.moveGen]; the page
  /// animates the items diff (collapse at source / expand at destination)
  /// when it advances. Stream-driven rebuilds never advance it.
  int _feedMoveGen = 0;

  /// Threads whose state the user explicitly changed since the last
  /// sectioned-feed rebuild; consumed (and cleared) by
  /// [_rebuildActiveTabSection].
  final Set<ThreadId> _pendingMoveIds = {};

  /// Flag [id] as explicitly state-changed by the user so the next
  /// sectioned-feed rebuild animates its repositioning. Flat feeds
  /// (Everything / search / filter) never reposition on state changes, so
  /// this is a no-op there. Drag-and-drop deliberately does NOT mark —
  /// the drag's own visuals already animate the move.
  void markFeedMove(ThreadId id) {
    if (_activeTabFlatMode) return;
    _pendingMoveIds.add(id);
  }
```

- [x] **Step 3: Immediate sticky removal in `setThread`; delete `_scheduleStickyRemoval`, `pinTodoInPlace`, `_renderedSectionFor`**

Replace the navigate-away block in `setThread` (current ~3069–3099) with:

```dart
    // Sticky-unread tracking: when navigating away from a thread, drop its
    // overlay entry immediately so the just-read thread settles into its
    // natural section right away (the page animates the move). When
    // selecting an unread thread, pin it via the overlay so the per-tab
    // Catch up subscription keeps it visible at its pre-read position; the
    // snapshot is frozen as read so the unread dot clears immediately on
    // open. The thread's own unread → read DB write happens in
    // `page/thread.dart`.
    final oldThread = state.thread;
    if (oldThread != null && thread?.id != oldThread.id) {
      _removeSticky(oldThread.id);
    }
    if (thread != null &&
        thread.unread &&
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

Replace `_scheduleStickyRemoval` (and delete `pinTodoInPlace` +
`_renderedSectionFor`) with:

```dart
  /// Drop a sticky-unread overlay the moment the user navigates away so
  /// the just-read thread settles into its natural section immediately
  /// (animated via [markFeedMove]). No-op when the thread has no live
  /// sticky entry — e.g. its overlay was already replaced by an explicit
  /// state change, which manages its own move.
  void _removeSticky(ThreadId id) {
    final overlay = _overlay[id];
    if (overlay == null || !overlay.sticky) return;
    _overlay.remove(id);
    markFeedMove(id);
    if (_activeTabSubscriptionTab == ActivityTab.catchUp) {
      _rebuildActiveTabSection();
    }
  }
```

- [x] **Step 4: Clean the feed builder, comparator, and optimistic paths**

(a) `_buildUnifiedFeedItems`: delete the leading pinned-section branch
(`final pinned = _pinnedSectionFor(t.id); if (pinned != null) { ... }`) from
the bucketing loop, leaving the `if (t.unread || _isStickyPinned(t.id))`
branch and the `primarySectionFor` switch.

(b) `_catchUpCompare`: drop the `_isPinnedInUnread` terms:

```dart
    final aUn = (a.unread || _isStickyPinned(a.id)) ? 1 : 0;
    final bUn = (b.unread || _isStickyPinned(b.id)) ? 1 : 0;
```

(c) `optimisticallyRemoveThread`: delete the `keepStickyTodo` local and its
uses (overlay writes become unconditional). The two write sites become:

```dart
        _overlay[id] = _activeTabSubscriptionTab?.isActionTab == true
            ? const _Overlay.drop()
            : _Overlay(
                expected: finished,
                watched: const {_OverrideField.todo},
              );
```
and
```dart
        _overlay[id] = const _Overlay.drop();
```

(d) `optimisticallyUpdateThread`: replace the pinned-section guard around the
overlay write with sticky preservation for position-neutral updates (keeps
rule 1's unread→read exception intact when the open, sticky-pinned thread is
edited without changing its position):

```dart
    // Mirror in the per-tab activity-feed overlay so the active tab shows
    // the optimistic state in the same frame as the edit. A sticky-unread
    // pin (the open thread the user just read) survives position-neutral
    // updates — the row must hold its cluster spot while open — but an
    // update that changes positioning state (to-do/done, schedule, move)
    // replaces the pin so the row relocates immediately.
    final existing = _overlay[updatedThread.id];
    final keepSticky =
        existing != null &&
        existing.sticky &&
        existing.expected != null &&
        _samePosition(existing.expected!, updatedThread);
    _overlay[updatedThread.id] = keepSticky
        ? _Overlay(
            expected: updatedThread.copyWith(unread: false),
            watched: const <_OverrideField>{},
            catchUpSortKeys: existing.catchUpSortKeys,
            sticky: true,
          )
        : _Overlay(
            expected: updatedThread,
            watched: fields ?? _OptimisticOverride._defaultWatched,
          );
```

Add the position comparator next to `_isStickyPinned`:

```dart
  /// Whether two snapshots of a thread occupy the same feed position
  /// (section + slot): used to decide if an optimistic update may keep a
  /// sticky-unread pin alive.
  static bool _samePosition(Thread a, Thread b) =>
      a.todo == b.todo &&
      a.active == b.active &&
      a.on == b.on &&
      a.at == b.at &&
      a.order.compareTo(b.order) == 0 &&
      a.priority.id == b.priority.id &&
      a.archivedAt == b.archivedAt;
```

(e) `close()` and every `_overlay.clear()` site: delete the
`_stickyRemovalTimers` loop/clear and `_toggleOriginal.clear()` lines; add
`_pendingMoveIds.clear();` beside each `_overlay.clear()` (find them with
`grep -n "_overlay.clear()" apps/plot/lib/state/priority.dart`).

- [x] **Step 5: Stamp the generation in `_rebuildActiveTabSection`**

In the emit block of `_rebuildActiveTabSection` (current ~1197–1219):

```dart
    // Consume pending explicit-state-change marks: advance the move
    // generation so the page animates this rebuild's diff. Flat feeds
    // never reposition on state changes (rule 7), so marks are dropped
    // there.
    var movedIds = const <ThreadId>{};
    if (_pendingMoveIds.isNotEmpty) {
      if (!_activeTabFlatMode) {
        _feedMoveGen++;
        movedIds = Set.unmodifiable(Set.of(_pendingMoveIds));
      }
      _pendingMoveIds.clear();
    }
    byTab[tab] = ActivityFeedTabData(
      items: items,
      everythingFeed: everythingFeed,
      context: state.context,
      moveGen: _feedMoveGen,
      movedIds: movedIds,
    );
```

In `apps/plot/lib/state/activity_section.dart` extend `ActivityFeedTabData`:

```dart
class ActivityFeedTabData {
  const ActivityFeedTabData({
    required this.items,
    this.everythingFeed = false,
    this.context,
    this.moveGen = 0,
    this.movedIds = const {},
  });

  final List<AgendaItem> items;

  /// Generation counter advanced when this rebuild was caused by an
  /// explicit user state change in the sectioned feed; the page animates
  /// the items diff when it advances. Unchanged for stream-driven
  /// rebuilds.
  final int moveGen;

  /// The threads whose explicit state change produced this generation.
  final Set<ThreadId> movedIds;
  ...
```

(`ThreadId` comes from `package:plot/store/store.dart`, already imported.)

In `apps/plot/lib/state/priority_state.dart`, next to the
`activityFeedItems` getter, add (mirroring its tab lookup expression):

```dart
  /// Move-animation generation of the active feed (see
  /// [ActivityFeedTabData.moveGen]).
  int get feedMoveGen =>
      activityFeedByTab[activeTab]?.moveGen ?? 0;

  /// Threads whose explicit state change produced [feedMoveGen].
  Set<ThreadId> get feedMovedIds =>
      activityFeedByTab[activeTab]?.movedIds ?? const {};
```

- [x] **Step 6: Public navigation + flatness accessors**

Next to `resolveThreadListSource()` add (import
`package:plot/state/feed_navigation.dart`):

```dart
  /// True when the active feed renders as a flat list (Everything, search,
  /// or filters) — state changes never reposition rows there.
  bool get activeFeedIsFlat => _activeTabFlatMode;

  /// Rule 2/3 navigation decision for an explicit state change on the
  /// open thread. Computed against the CURRENT feed items — call BEFORE
  /// applying the optimistic update.
  StateChangeNav threadAfterStateChange(ThreadId changedId) {
    if (_activeTabFlatMode) return (open: null, stay: true);
    return nextThreadAfterStateChange(state.activityFeedItems, changedId);
  }
```

- [x] **Step 7: Verify no stragglers, analyze, run state suites**

Run:
```bash
grep -rn "pinTodoInPlace\|stickyTodo\|pinnedSection\|pinnedInUnread\|_toggleOriginal\|toggleOriginalFor\|_stickyMoveDelay\|_stickyRemovalTimers\|_scheduleStickyRemoval\|_renderedSectionFor\|_isPinnedInUnread" apps/plot/lib apps/plot/test
```
Expected: only hits in `apps/plot/lib/command/thread.dart` (fixed in Task 6).
Then: `cd apps/plot && flutter analyze lib/state/priority.dart lib/state/priority_state.dart lib/state/activity_section.dart` — expect errors ONLY in `command/thread.dart` callers (Task 6); if analyze of these three files reports issues, fix before continuing.
Then: `cd apps/plot && flutter test test/state/` — expect existing suites green.

- [x] **Step 8: Commit** (held until Task 6 makes the tree analyze-clean; commit both together if commands are done in the same session, otherwise commit with `--no-verify` noting the WIP pairing)

```bash
git add apps/plot/lib/state/priority.dart apps/plot/lib/state/priority_state.dart apps/plot/lib/state/activity_section.dart
git commit -m "feat(app): immediate thread repositioning — remove sticky-todo pins and read-move delay" -- apps/plot/lib/state/priority.dart apps/plot/lib/state/priority_state.dart apps/plot/lib/state/activity_section.dart
```

---

### Task 6: Command rewiring (Done / To do / Do later / Move / Mute)

**Files:**
- Modify: `apps/plot/lib/command/thread.dart` (`ToggleThreadActive`,
  `FinishThread`, `ScheduleThread`, `RescheduleAllInBlock`,
  `MuteSimilarThreads`, `_UpdateThreadCommand.saveOptimistically`)

- [x] **Step 1: Mark moves in `saveOptimistically`**

In `_UpdateThreadCommand.saveOptimistically`, immediately before
`bloc?.optimisticallyUpdateThread(...)`:

```dart
    // Every save through this path is an explicit user action; flag it so
    // the sectioned feed animates any resulting reposition.
    bloc?.markFeedMove(updatedThread.id);
    bloc?.optimisticallyUpdateThread(
      updatedThread,
      watchScheduleAction: watchScheduleAction,
    );
```

- [x] **Step 2: Rewrite `ToggleThreadActive.run`**

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final markingDone = thread.todo;
    final priorityBloc = context.read<PriorityBloc?>();
    final isCurrentThread = priorityBloc?.state.thread?.id == thread.id;
    // Rule 2/3: decide navigation against pre-change feed positions. When
    // re-activating from Done the helper returns stay (no navigation) and
    // the thread moves to the bottom of Active while remaining open.
    final nav = isCurrentThread
        ? priorityBloc?.threadAfterStateChange(thread.id)
        : null;
    final updated = thread.copyWith(
      todo: !thread.todo,
      unread: false,
      readAt: thread.unread
          ? Value(thread.contentTimestamp)
          : const Value.absent(),
    );
    await saveOptimistically(context, updated);
    // Marking the thread done also completes the user's todo notes on it
    // (matches FinishThread). Flipping back to todo leaves notes untouched.
    if (markingDone) {
      await _completeUserTodoNotes(thread.id, Base.actorId);
    }
    if (nav?.open != null && context.mounted) {
      await ChangeCurrentThread(nav!.open!).run(context);
    }
    return const CommandDone();
  }
```

(The `restoreOrder` / `toggleOriginalFor` logic is gone: re-activation lands
at the bottom of Active via the Task 2 `copyWith` default.)

- [x] **Step 3: Rewrite the navigation block in `FinishThread.run`**

Replace from the `isAgenda` declaration through the `navigationResult`
assignment block with:

```dart
    final priorityBloc = context.read<PriorityBloc?>();
    final isCurrentThread = priorityBloc?.state.thread?.id == thread.id;
    final finished = thread.copyWith(
      todo: false,
      bump: bump,
      unread: false,
      readAt: thread.unread
          ? Value(thread.contentTimestamp)
          : const Value.absent(),
    );
    // Rule 2/3 navigation, decided against pre-change feed positions. In
    // the Done section (or a flat feed) the thread stays open; when the
    // feed has nothing else to open, fall back to the compose page.
    CommandReturn? navigationResult;
    if (isCurrentThread) {
      final nav = priorityBloc?.threadAfterStateChange(thread.id);
      if (nav?.open != null) {
        navigationResult = await ChangeCurrentThread(nav!.open!).run(context);
      } else if (nav != null && !nav.stay) {
        if (!context.mounted) return const CommandDone();
        navigationResult = await NewThread().run(context);
      }
    }
```

Also: delete the `original` / `effectiveBump` lines (use plain `bump` in
`finished` above), delete the `pinTodoInPlace` call, and add a move mark just
before the optimistic removal fallback further down:

```dart
    priorityBloc?.markFeedMove(thread.id);
    if (onBeforeRun != null) {
      // Animation layer handles optimistic removal
      await onBeforeRun!(context);
    } else {
      priorityBloc?.optimisticallyRemoveThread(thread.id, finishTodo: true);
    }
```

- [x] **Step 4: Rewrite `ScheduleThread.run` (bottom of target day + navigation)**

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    PriorityBloc? bloc = priorityBloc;
    if (bloc == null) {
      try {
        bloc = context.read<PriorityBloc>();
      } catch (_) {}
    }
    final isCurrentThread = bloc?.state.thread?.id == thread.id;
    final nav =
        isCurrentThread ? bloc?.threadAfterStateChange(thread.id) : null;
    var updated = thread;
    // Ensure thread is a todo (creates per-user schedule if needed)
    if (!updated.todo) {
      updated = updated.copyWith(todo: true);
    }
    // Move to the target date on the per-user schedule only, appending to
    // the BOTTOM of the destination day (rule 4).
    updated = updated.reorderTo(
      Order.last(),
      date: when == Thread.todoNowDate ? null : when,
    );
    await saveOptimistically(context, updated);
    if (nav?.open != null && context.mounted) {
      await ChangeCurrentThread(nav!.open!).run(context);
    }
    return const CommandDone();
  }
```

- [x] **Step 5: Bottom-append chain in `RescheduleAllInBlock`**

Replace the `updates` construction:

```dart
    final date = picked.value == Thread.todoNowDate ? null : picked.value;
    // Append the block to the BOTTOM of the target day preserving its
    // relative order: a strictly-increasing order chain (plain
    // Order.last() per item could tie-break randomly within the same
    // millisecond).
    Order? prev;
    final updates = threads.map((thread) {
      final asTodo = thread.todo ? thread : thread.copyWith(todo: true);
      final order = prev == null ? Order.last() : Order.between(prev, null);
      prev = order;
      return asTodo.reorderTo(order, date: date);
    }).toList();
```

And flag the moves before the optimistic loop:

```dart
    for (final updated in updates) {
      bloc?.markFeedMove(updated.id);
      bloc?.optimisticallyUpdateThread(updated);
    }
```

- [x] **Step 6: `MuteSimilarThreads` set-branch**

Replace the set branch (drop `pinTodoInPlace`):

```dart
    } else {
      // Set: mark the seed read + inactive (move to Done) and stamp it as
      // the rule anchor. Server-side apply_mute fans out to matching peers;
      // clients see the additional reads + inactives on the next sync pull.
      final muted = _thread.asInactive().copyWith(
        muteByThreadId: Value(_thread.id),
      );
      // Rule 2: muting the open thread moves it to Done immediately and
      // opens the next thread (decided against pre-change positions).
      final isCurrentThread = priorityBloc?.state.thread?.id == _thread.id;
      final nav = isCurrentThread
          ? priorityBloc?.threadAfterStateChange(_thread.id)
          : null;
      priorityBloc?.markFeedMove(_thread.id);
      priorityBloc?.optimisticallyUpdateThread(muted);
      await muted.save();
      if (nav?.open != null && context.mounted) {
        await ChangeCurrentThread(nav!.open!).run(context);
      }
    }
```

- [x] **Step 7: `MoveToPriority` — leave-context removal + navigation**

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc?>();
    final contextPriority = priorityBloc?.state.context;
    // Moving the thread outside the current focus subtree removes it from
    // this feed (open the next thread, rule 2); a move within the subtree
    // (or in a flat feed) keeps it visible in place.
    final sectioned = !(priorityBloc?.activeFeedIsFlat ?? true);
    final leavesContext =
        sectioned &&
        contextPriority != null &&
        !contextPriority.root &&
        priority!.id != contextPriority.id &&
        !priority!.path.isChild(contextPriority.path);
    final isCurrentThread = priorityBloc?.state.thread?.id == thread.id;
    final nav = (isCurrentThread && leavesContext)
        ? priorityBloc?.threadAfterStateChange(thread.id)
        : null;
    final updated = thread.copyWith(priority: priority!);
    priorityBloc?.markFeedMove(thread.id);
    if (leavesContext) {
      // Collapse the row out of this focus immediately; the stream stops
      // returning it once the move lands.
      priorityBloc?.optimisticallyRemoveThread(thread.id);
    } else {
      priorityBloc?.optimisticallyUpdateThread(updated);
    }
    unawaited(_persistPriorityMove(updated, priority!));
    if (nav?.open != null && context.mounted) {
      await ChangeCurrentThread(nav!.open!).run(context);
    }
    return const CommandDone();
  }
```

- [x] **Step 8: Analyze + run command/state suites**

Run:
```bash
cd apps/plot && flutter analyze
cd apps/plot && flutter test test/command/ test/state/ test/store/
```
Expected: analyze clean; suites green (fix any expectation still assuming
top-insertion or pin behaviour).

- [x] **Step 9: Commit (with Task 5 files if still uncommitted)**

```bash
git add apps/plot/lib/command/thread.dart
git commit -m "feat(app): open-next navigation and bottom-of-day placement for thread state changes" -- apps/plot/lib/command/thread.dart
```

---

### Task 7: Page-side move animation (rule 6)

**Files:**
- Modify: `apps/plot/lib/page/priority.dart` (`_PriorityPageState`,
  `_buildActivityFeed`, `_buildSeparator`)

- [x] **Step 1: Add animation state to `_PriorityPageState`**

`_PriorityPageState` already mixes in `TickerProviderStateMixin`. Add fields:

```dart
  // ---- Feed move animation (collapse at source / expand at destination).
  // Driven by PriorityState.feedMoveGen: explicit user state changes bump
  // the generation; the diff between the previous and current item lists
  // is animated with one controller so heights stay synchronized and rows
  // outside the moved range never shift.
  int _lastMoveGen = 0;
  List<AgendaItem> _lastFeedItems = const [];
  FeedMoveDiff _activeMoveDiff = FeedMoveDiff.empty;
  AnimationController? _moveController;
  Animation<double>? _moveAnimation;
```

Add to `dispose()`:

```dart
    _moveController?.dispose();
```

Add methods:

```dart
  /// Start (or replace) the move animation for [diff]. A new move while
  /// one is in flight completes the old one instantly.
  void _startMoveAnimation(FeedMoveDiff diff) {
    _moveController?.dispose();
    _moveController = null;
    _moveAnimation = null;
    _activeMoveDiff = diff;
    if (diff.isEmpty) return;
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _moveController = controller;
    _moveAnimation = CurvedAnimation(
      parent: controller,
      curve: Curves.easeInOutCubic,
    );
    controller.forward().whenComplete(() {
      if (!mounted || _moveController != controller) return;
      setState(() {
        _activeMoveDiff = FeedMoveDiff.empty;
        _moveController = null;
        _moveAnimation = null;
      });
      controller.dispose();
    });
  }

  /// Splice the active move's collapsing ghosts into [items] after their
  /// anchor rows. A ghost whose anchor vanished is dropped (snaps).
  List<_FeedEntry> _spliceGhosts(List<AgendaItem> items) {
    final diff = _activeMoveDiff;
    if (diff.ghosts.isEmpty) {
      return [for (final item in items) _FeedEntry(item)];
    }
    final byAnchor = <String?, List<AgendaItem>>{};
    for (final g in diff.ghosts) {
      byAnchor.putIfAbsent(g.anchorKey, () => []).add(g.item);
    }
    final entries = <_FeedEntry>[
      for (final g in byAnchor[null] ?? const <AgendaItem>[])
        _FeedEntry(g, ghost: true),
    ];
    for (final item in items) {
      entries.add(_FeedEntry(item));
      final ghosts = byAnchor[feedItemKey(item)];
      if (ghosts != null) {
        entries.addAll([for (final g in ghosts) _FeedEntry(g, ghost: true)]);
      }
    }
    return entries;
  }
```

Add the entry type at file scope (near `_SectionHeaderWithRescheduleAll`):

```dart
/// A row in the rendered activity feed: a live [AgendaItem], or a
/// collapsing ghost of one (the source side of a move animation).
class _FeedEntry {
  const _FeedEntry(this.item, {this.ghost = false});
  final AgendaItem item;
  final bool ghost;
}
```

Import `package:plot/state/feed_move_diff.dart`.

- [x] **Step 2: Detect generation changes and splice ghosts in `_buildActivityFeed`**

After `displayItems` is finalized (after the `displayItems = items;` else
branch) and before the footer/boundary logic:

```dart
    // Move animation: an advanced generation means this rebuild was caused
    // by an explicit user state change — animate the diff. Stream-driven
    // rebuilds (same generation) snap as before.
    if (state.feedMoveGen != _lastMoveGen) {
      _lastMoveGen = state.feedMoveGen;
      _startMoveAnimation(
        computeFeedMoveDiff(_lastFeedItems, displayItems, state.feedMovedIds),
      );
    }
    _lastFeedItems = displayItems;

    final renderItems = _spliceGhosts(displayItems);
```

Then update the downstream code to use `renderItems`:
- `footerIndex`: `showFooter ? renderItems.length : -1`
- `totalCount`: `renderItems.length + (showFooter ? 1 : 0)`
- Drop boundaries — compute over the projected items when ghosts are present
  (without polluting the identity cache):

```dart
    final ({Map<int, FeedDropSlot> before, FeedDropSlot? afterList}) boundaries;
    final hasGhosts = renderItems.length != displayItems.length;
    if (hasGhosts) {
      boundaries = computeActivityFeedDropBoundaries(
        items: [for (final e in renderItems) e.item],
      );
    } else if (identical(_cachedDropBoundaryItems, displayItems) &&
        _cachedDropBoundaries != null) {
      boundaries = _cachedDropBoundaries!;
    } else {
      boundaries = computeActivityFeedDropBoundaries(items: displayItems);
      _cachedDropBoundaryItems = displayItems;
      _cachedDropBoundaries = boundaries;
    }
```

- `separatorBuilder`: `(context, index) => _buildSeparator(context, renderItems, index, state, controller)`

- [x] **Step 3: Ghost/expander rendering in the item builder**

Rewrite the `builder:` closure of the `InfiniteList`:

```dart
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= totalCount) {
          return null;
        }
        if (index == footerIndex) {
          return SearchFooter(state: state);
        }
        final entry = renderItems[index];
        final current = entry.item;
        final dropAbove = entry.ghost ? null : boundaries.before[index];
        // Trailing boundary attached to the last list item (skip when the
        // search footer occupies the last index).
        final isLast = !showFooter && index == renderItems.length - 1;
        final tail = isLast ? boundaries.afterList : null;
        final itemKey = feedItemKey(current);

        var children = current.when<List<Widget>>(
          header: (header) {
            // ... existing header branch UNCHANGED except the
            // sectionThreads scan, which now walks renderItems and skips
            // ghosts:
            //   for (var j = index + 1; j < renderItems.length; j++) {
            //     final nextEntry = renderItems[j];
            //     if (nextEntry.ghost) continue;
            //     final next = nextEntry.item;
            //     if (next is AgendaHeaderItem) break;
            //     if (next is AgendaThreadItem) {
            //       sectionThreads.add(next.thread);
            //     }
            //   }
          },
          activity: (agendaActivity) {
            final baseThread = agendaActivity.thread;
            final rowKey = entry.ghost
                ? ValueKey('feed_ghost_row_$itemKey')
                : agendaActivity.isAssociated
                ? ValueKey(
                    'feed_activitywidget_${baseThread.id}_assoc_${agendaActivity.associationParentId ?? ''}',
                  )
                : ValueKey('feed_activitywidget_${baseThread.id}');
            final item = ActivityFeedThreadRow(
              key: rowKey,
              baseThread: baseThread,
              selected: !entry.ghost &&
                  state.thread != null &&
                  baseThread.id == state.thread!.id,
              now: agendaActivity.now,
              focusNode: focusNode,
              priorityContext: state.activeTabContext ?? state.context,
              isAssociated: agendaActivity.isAssociated,
              isSearch: isSearching,
            );
            if (agendaActivity.pinned || entry.ghost) {
              // Ghosts are non-interactive copies — never draggable.
              return [item];
            }
            return [
              ActivityFeedDraggableRow(
                threadId: baseThread.id,
                priorityContext: state.context,
                child: item,
              ),
            ];
          },
        );

        // Move animation wrappers: ghosts collapse 1→0 at the source while
        // destination rows expand 0→1, driven by one shared controller so
        // total height between source and destination stays constant.
        final anim = _moveAnimation;
        if (anim != null) {
          if (entry.ghost) {
            children = [
              SizeTransition(
                sizeFactor: ReverseAnimation(anim),
                axisAlignment: -1.0,
                child: ExcludeFocus(
                  child: IgnorePointer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ),
            ];
          } else if (_activeMoveDiff.expandingKeys.contains(itemKey)) {
            children = [
              SizeTransition(
                sizeFactor: anim,
                axisAlignment: -1.0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ];
          }
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          key: ValueKey(
            entry.ghost
                ? 'feed_ghost_${_lastMoveGen}_$itemKey'
                : current.when(
                    header: (h) => h.date != null
                        ? 'feed_header_date_${h.date}'
                        : 'feed_header_${h.text}',
                    activity: (a) => 'feed_activity_${a.thread.id}',
                  ),
          ),
          children: [
            if (dropAbove != null && !state.everything)
              BlockDropZone(
                target: dropAbove.target,
                silent: dropAbove.silent,
                slotKey: 'feed_drop_above_$index',
                dividerBelow: true,
              ),
            ...children,
            if (tail != null && !state.everything)
              BlockDropZone(
                target: tail.target,
                silent: tail.silent,
                slotKey: 'feed_drop_tail',
              ),
          ],
        );
      },
```

(Preserve the existing comments around the header branch and drop zones when
editing; only the mechanics shown change.)

- [x] **Step 4: Ghost-aware `_buildSeparator`**

Change the signature to take entries and suppress the selection accent next
to ghosts (a moved selected row would otherwise paint two rings):

```dart
  Widget _buildSeparator(
    BuildContext context,
    List<_FeedEntry> listItems,
    int index,
    PriorityState state,
    InfiniteListController controller,
  ) {
    final selectedId = state.thread?.id;
    final prevEntry = index > 0 && index - 1 < listItems.length
        ? listItems[index - 1]
        : null;
    final nextEntry = index < listItems.length ? listItems[index] : null;
    final rawPrev = prevEntry?.item;
    final rawNext = nextEntry?.item;
    final adjacentGhost =
        (prevEntry?.ghost ?? false) || (nextEntry?.ghost ?? false);
    if (rawPrev == null && context.isMultiPanel) {
      return const SizedBox.shrink();
    }
    return BlockListSeparator(
      prev: rawPrev,
      next: rawNext,
      controller: controller,
      dragController: _activityFeedDragController,
      index: index,
      selectedAccent: (item) {
        if (adjacentGhost) return null;
        if (item is AgendaThreadItem && item.thread.id == selectedId) {
          return context.colour.colours.borderFromTheme(
            item.thread.priority.displayColor,
          );
        }
        return null;
      },
      canHighlight: (item) => item is AgendaThreadItem,
      dragSourceId: (item) =>
          item is AgendaThreadItem ? item.thread.id.toString() : null,
    );
  }
```

(Keep the existing explanatory comments.)

- [x] **Step 5: Analyze + page/widget tests**

Run:
```bash
cd apps/plot && flutter analyze
cd apps/plot && flutter test test/page/ test/widget/ test/state/
```
Expected: clean / green.

- [x] **Step 6: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "feat(app): synchronized collapse/expand animation for thread repositioning" -- apps/plot/lib/page/priority.dart
```

---

### Task 8: Full verification + docs + finalize

- [x] **Step 1: Full app test suite + analyze**

Run:
```bash
cd apps/plot && flutter analyze
cd apps/plot && flutter test
```
Expected: analyze clean; suite green except the 3 known pre-existing failures
(`actor_authored_threads_integration_test` and two migration tests). Fix any
new failure.

- [x] **Step 2: docs/updates.md**

Read the top of `docs/updates.md`; under `## Next release` add to the
existing thread-behaviour section if one fits, else create `### Working
through threads` (above `### Fixes`):

```markdown
### Working through threads

- Changing a thread's state (to do, done, do later, move, mute) now moves it
  to its new spot in the focus list right away, with a smooth animation.
- When you change the open thread, the next thread below opens automatically
  (or the one above if you're working from the bottom) — so you can work
  through your list without extra clicks. Threads in Done stay open.
- New to-dos are added at the bottom of Active, and newly scheduled threads
  at the bottom of their day.
```

- [x] **Step 3: Run the finalize checklist**

Invoke the `/finalize` skill (lint already covered; backwards compatibility:
Flutter-only, no API/schema changes; no new catch blocks expected — verify;
public submodule untouched).

- [x] **Step 4: Commit docs**

```bash
git add docs/updates.md
git commit -m "docs: update notes for immediate thread repositioning" -- docs/updates.md
```

---

### Task 9: run-app verification (manual, via `run-app` skill)

> Outcome 2026-06-12: verified live via flutter_driver — rule-1 exception
> (open unread holds position, dot clears), rule 5 (instant move on
> navigate-away), rules 1+2 (To do on the open thread moved it instantly
> and auto-opened the thread below), rule 4 (DB check: both activated
> threads got positive Order.last values sorting at the bottom of Active),
> rule 7 (Everything: state change held the row in place, thread stayed
> open). Zero app runtime errors across all interactions. The Done section
> was unreachable by driver scrolling (row drags are captured by the
> drag-and-drop recognizer), so rule 3 and the last-before-Done exception
> rest on the feed_navigation unit tests, which exercise the same shared
> code path as the verified open-next flow.

- [x] Launch via the `run-app` skill and verify in a focus:
  1. Mark an Active thread done from its row → it animates to the top of
     Done; rows below Done's top do not shift mid-animation.
  2. Open an Active thread, mark done (header button) → next thread below
     opens; the row animates out of Active into Done.
  3. Mark the LAST thread before Done done while open → the thread ABOVE
     opens.
  4. In Done, mark a thread to-do → it stays open and animates to the
     BOTTOM of Active.
  5. "Do later" on an open Active thread → lands at the BOTTOM of the
     chosen day; next thread opens.
  6. Mute an open thread → moves to Done, next opens.
  7. Move an open thread to another focus → collapses out, next opens.
  8. Open an unread thread → dot clears, row holds; click another thread →
     the first thread immediately animates to its natural section (no 1.5s
     wait).
  9. In Everything and in search results: mark done / to-do → row does NOT
     move; thread stays open.
- [x] Note any deviation and fix before declaring done. (No deviations
  observed in the verified flows.)

---

## Self-review notes

- Spec coverage: rule 1 → Tasks 5–6 (pins removed, immediate optimistic
  moves); rule 2/3 → Tasks 3, 5 (bloc accessor), 6 (command wiring); rule 4 →
  Tasks 1–2, 6 (ScheduleThread/RescheduleAllInBlock); rule 5 → Task 5
  (`_removeSticky`); rule 6 → Tasks 4, 5 (moveGen), 7; rule 7 → flat-mode
  gates in `markFeedMove`, `_rebuildActiveTabSection`,
  `threadAfterStateChange`, and `MoveToPriority`'s `sectioned` guard.
- `OpenNextThread`/`OpenPreviousThread` (arrow keys) intentionally unchanged.
- `page/thread.dart`'s zero-delay mark-as-read already satisfies rule 5's
  read-marking side; no change there.
- Known acceptable transients during the 300 ms animation: drop-slot indexes
  include ghosts; "Do all later" header counts skip ghosts; a 1 px separator
  above a fully-collapsed ghost until cleanup.
