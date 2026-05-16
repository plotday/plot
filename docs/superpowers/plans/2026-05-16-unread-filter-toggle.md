# Unread Filter Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a conditional header toggle that filters a priority's activity feed to unread threads only, preserving existing section grouping.

**Architecture:** New `bool unreadFilterActive` on `PriorityState`. `activityFeedViewItems` getter returns either the unfiltered list or a filtered subset (unread threads + the section/sub-section headers immediately preceding them). The bloc's single agenda/feed rebuild helper (`_rebuildAgendaModel`) auto-disables the filter when the recomputed feed has zero unread. A new `ToggleUnreadFilter` command exposes the action via a header `Button.icon` and the `⌘⇧U` / `Ctrl+Shift+U` shortcut. The button renders only when the priority feed has unread items.

**Tech Stack:** Flutter / Dart, `flutter_bloc`, forui, project's `Command` + `Button.icon` patterns, `platformSingleActivator` helper.

**Spec:** `docs/superpowers/specs/2026-05-16-unread-filter-toggle-design.md`

---

## File map

- **Modify** `apps/plot/lib/state/priority_state.dart` — add `unreadFilterActive` field, `hasUnreadInFeed` getter, `activityFeedViewItems` getter, propagate through factory / `_` ctor / `copyWith` / `props`.
- **Modify** `apps/plot/lib/state/priority.dart` — add `toggleUnreadFilter()` to `PriorityBloc`; enforce auto-off in `_rebuildAgendaModel`; reset filter when context priority changes.
- **Create** `apps/plot/lib/command/unread_filter.dart` — defines `ToggleUnreadFilter` command (title, icon, hoverIcon, shortcut, `on`, `enabled`, `run`) and exports a `unreadFilterShortcut` `SingleActivator`.
- **Modify** `apps/plot/lib/page/priority.dart` — change activity-feed rendering to consume `state.activityFeedViewItems` instead of `state.activityFeedItems` in the body builder and the notification-scroll listener; bind the command shortcut into the priority `CommandScope`.
- **Modify** `apps/plot/lib/widget/unified_header.dart` — insert the `Button.icon(ToggleUnreadFilter(...))` between the priority title and the tracking-pill control in `_buildTitleSection`'s `withTrackingPill`, gated on `state.hasUnreadInFeed`.
- **Create** `apps/plot/test/state/priority_state_unread_filter_test.dart` — unit tests for the new getters and copyWith propagation.
- **Create** `apps/plot/test/command/unread_filter_test.dart` — lightweight smoke test for the command's metadata (title, shortcut, icons) so the file is referenced by the build.

---

## Conventions / shared snippets

These are referenced by multiple tasks. Re-quoted in each task that uses them so steps stand alone.

**Icons:** `FontAwesomeIcons.envelope` (outline, inactive) and `FontAwesomeIcons.solidEnvelope` (filled, active hover/selected). Matches existing inbox/mail usage in `command/settings.dart`.

**Shortcut:** `platformSingleActivator(LogicalKeyboardKey.keyU, shift: true)` — resolves to `⌘⇧U` on macOS, `Ctrl+Shift+U` on other platforms. Same helper used by `Shift+T`, `Shift+D`, `Shift+I` elsewhere.

**Section-header detection** (for filtering): an `AgendaHeaderItem` whose `text` is non-null and decodable via `ActivitySectionMarker.tryDecode(...)` is a top-level section header (Doing / Scheduled / New / Done / Event Agenda). Non-section headers (date sub-headers like "Tomorrow") have `date != null` or `dateTimeRange != null` and either null `text` or a `text` that does not decode.

**Filter algorithm** (for `activityFeedViewItems`):

```dart
List<AgendaItem> _filterToUnread(List<AgendaItem> items) {
  final result = <AgendaItem>[];
  final pendingHeaders = <AgendaHeaderItem>[];
  for (final item in items) {
    if (item is AgendaHeaderItem) {
      final isSectionHeader = item.text != null &&
          ActivitySectionMarker.tryDecode(item.text!) != null;
      if (isSectionHeader) pendingHeaders.clear();
      pendingHeaders.add(item);
    } else if (item is AgendaThreadItem && item.thread.unread) {
      result.addAll(pendingHeaders);
      pendingHeaders.clear();
      result.add(item);
    }
  }
  return result;
}
```

Rationale: section headers reset the pending queue (so a section with no surviving threads doesn't leak its header onto the next section's first item); sub-headers (date headers under Scheduled) accumulate so a kept thread carries both its section and its day label.

**Has-unread check** (for `hasUnreadInFeed`):

```dart
for (final item in activityFeedItems) {
  if (item is AgendaThreadItem && item.thread.unread) return true;
}
return false;
```

Operates on `activityFeedItems` (the storage), not the filtered view.

---

## Task 1: Add filter state and getters to `PriorityState`

**Files:**
- Modify: `apps/plot/lib/state/priority_state.dart`
- Test: `apps/plot/test/state/priority_state_unread_filter_test.dart`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/state/priority_state_unread_filter_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';

Priority _testPriority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: const Order(0),
    root: false,
    unread: false,
    role: 'member',
    attentionWindowSet: false,
    seeWithinRequestsSet: false,
    seeWithinUpdatesSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

PriorityState _stateWith({
  required Priority priority,
  required List<AgendaItem> activityFeedItems,
  bool unreadFilterActive = false,
}) {
  final draft = Thread(priority: priority, draft: true);
  final draftNote = Note(
    id: Uuid.generate(),
    threadId: draft.id,
    authorId: ActorId(Uuid.generate()),
    draft: true,
    createdAt: DateTime(2026, 1, 1),
    sourceCreatedAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
  return PriorityState(
    context: priority,
    draft: draft,
    draftNote: draftNote,
    activityFeedItems: activityFeedItems,
    unreadFilterActive: unreadFilterActive,
  );
}

Thread _thread(Priority p, {required bool unread, String title = 't'}) {
  return Thread(priority: p, title: title).copyWith(unread: unread);
}

AgendaHeaderItem _sectionHeader(ActivitySection section) {
  return AgendaHeaderItem(text: ActivitySectionMarker.encode(section));
}

void main() {
  group('PriorityState unread filter', () {
    test('hasUnreadInFeed is false when no thread item is unread', () {
      final p = _testPriority();
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.today),
          AgendaThreadItem(_thread(p, unread: false, title: 'a')),
        ],
      );
      expect(state.hasUnreadInFeed, isFalse);
    });

    test('hasUnreadInFeed is true when any thread item is unread', () {
      final p = _testPriority();
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.today),
          AgendaThreadItem(_thread(p, unread: false, title: 'a')),
          _sectionHeader(ActivitySection.newSection),
          AgendaThreadItem(_thread(p, unread: true, title: 'b')),
        ],
      );
      expect(state.hasUnreadInFeed, isTrue);
    });

    test('activityFeedViewItems returns full list when filter inactive', () {
      final p = _testPriority();
      final items = <AgendaItem>[
        _sectionHeader(ActivitySection.today),
        AgendaThreadItem(_thread(p, unread: false)),
        AgendaThreadItem(_thread(p, unread: true)),
      ];
      final state = _stateWith(priority: p, activityFeedItems: items);
      expect(state.activityFeedViewItems, equals(items));
    });

    test('activityFeedViewItems drops read threads when filter active', () {
      final p = _testPriority();
      final readT = AgendaThreadItem(_thread(p, unread: false, title: 'r'));
      final unreadT = AgendaThreadItem(_thread(p, unread: true, title: 'u'));
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.today),
          readT,
          unreadT,
        ],
        unreadFilterActive: true,
      );
      final view = state.activityFeedViewItems;
      expect(view.length, 2);
      expect(view[0], isA<AgendaHeaderItem>());
      expect(view[1], same(unreadT));
    });

    test('activityFeedViewItems drops empty section headers', () {
      final p = _testPriority();
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.today),
          AgendaThreadItem(_thread(p, unread: false, title: 'r1')),
          _sectionHeader(ActivitySection.scheduled),
          AgendaThreadItem(_thread(p, unread: false, title: 'r2')),
          _sectionHeader(ActivitySection.newSection),
          AgendaThreadItem(_thread(p, unread: true, title: 'u')),
        ],
        unreadFilterActive: true,
      );
      final view = state.activityFeedViewItems;
      // Only the New header + the unread thread should survive.
      expect(view.length, 2);
      expect(view[0], isA<AgendaHeaderItem>());
      final header = view[0] as AgendaHeaderItem;
      final decoded = ActivitySectionMarker.tryDecode(header.text!);
      expect(decoded?.section, ActivitySection.newSection);
    });

    test('activityFeedViewItems keeps date sub-header above kept thread', () {
      final p = _testPriority();
      final tomorrow = Date.today().addDays(1);
      final unreadT = AgendaThreadItem(_thread(p, unread: true, title: 'u'));
      final state = _stateWith(
        priority: p,
        activityFeedItems: [
          _sectionHeader(ActivitySection.scheduled),
          AgendaHeaderItem(date: tomorrow),
          unreadT,
        ],
        unreadFilterActive: true,
      );
      final view = state.activityFeedViewItems;
      // Section header + date sub-header + unread thread.
      expect(view.length, 3);
      expect(view[0], isA<AgendaHeaderItem>());
      expect(view[1], isA<AgendaHeaderItem>());
      expect(view[2], same(unreadT));
    });

    test('copyWith propagates unreadFilterActive', () {
      final p = _testPriority();
      final state = _stateWith(priority: p, activityFeedItems: const []);
      expect(state.unreadFilterActive, isFalse);
      expect(state.copyWith(unreadFilterActive: true).unreadFilterActive,
          isTrue);
      expect(
        state
            .copyWith(unreadFilterActive: true)
            .copyWith()
            .unreadFilterActive,
        isTrue,
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/priority_state_unread_filter_test.dart`
Expected: compile errors — `unreadFilterActive` is not a known parameter, `hasUnreadInFeed` / `activityFeedViewItems` do not exist.

- [ ] **Step 3: Add the field and getters to PriorityState**

Edit `apps/plot/lib/state/priority_state.dart`. Apply four small changes inside the existing `PriorityState` class.

1. Factory constructor signature — add the named parameter (insert after `hideSubPriorities` near line 36):

```dart
    bool hideSubPriorities = true,
    bool unreadFilterActive = false,
  }) {
```

And pass it through to the private constructor at the bottom of the factory body (after `hideSubPriorities: hideSubPriorities,`):

```dart
      hideSubPriorities: hideSubPriorities,
      unreadFilterActive: unreadFilterActive,
    );
  }
```

2. Private constructor — add the parameter (after `this.hideSubPriorities = true,`):

```dart
    this.hideSubPriorities = true,
    this.unreadFilterActive = false,
  });
```

3. Field declaration — add after the `hideSubPriorities` final field (around line 177):

```dart
  final bool hideSubPriorities;

  /// True while the user has the unread-only filter toggled on for this
  /// priority's activity feed. In-memory only; resets when the bloc
  /// recomputes the feed with zero unread items, or when the context
  /// priority changes.
  final bool unreadFilterActive;
```

4. Getters — add immediately after `doneStart` / `doneEnd` (around line 181, before `agendaViewItems`):

```dart
  /// Any unread thread anywhere in the activity feed. Drives the
  /// header button's visibility and the auto-off invariant.
  bool get hasUnreadInFeed {
    for (final item in activityFeedItems) {
      if (item is AgendaThreadItem && item.thread.unread) return true;
    }
    return false;
  }

  /// The activity feed items as the user should see them — equal to
  /// [activityFeedItems] when [unreadFilterActive] is false, otherwise
  /// only the unread threads plus the section/sub-section headers that
  /// immediately precede them. Read threads that the user is currently
  /// viewing remain unread until the bloc recomputes the feed, so the
  /// "sticky unread" behavior of the New section carries over here for
  /// free.
  List<AgendaItem> get activityFeedViewItems {
    if (!unreadFilterActive) return activityFeedItems;
    final result = <AgendaItem>[];
    final pendingHeaders = <AgendaHeaderItem>[];
    for (final item in activityFeedItems) {
      if (item is AgendaHeaderItem) {
        final isSectionHeader = item.text != null &&
            ActivitySectionMarker.tryDecode(item.text!) != null;
        if (isSectionHeader) pendingHeaders.clear();
        pendingHeaders.add(item);
      } else if (item is AgendaThreadItem && item.thread.unread) {
        result.addAll(pendingHeaders);
        pendingHeaders.clear();
        result.add(item);
      }
    }
    return result;
  }
```

5. `copyWith` — add the parameter (in the signature near line 1157):

```dart
    bool? hideSubPriorities,
    bool? unreadFilterActive,
  }) {
```

And in the body (after `hideSubPriorities: hideSubPriorities ?? this.hideSubPriorities,`):

```dart
      hideSubPriorities: hideSubPriorities ?? this.hideSubPriorities,
      unreadFilterActive: unreadFilterActive ?? this.unreadFilterActive,
    );
  }
```

6. `props` — add `unreadFilterActive` at the end of the list (around line 1244):

```dart
    hideSubPriorities,
    unreadFilterActive,
  ];
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/state/priority_state_unread_filter_test.dart`
Expected: all tests pass.

- [ ] **Step 5: Verify lint**

Run: `cd apps/plot && flutter analyze lib/state/priority_state.dart test/state/priority_state_unread_filter_test.dart`
Expected: no issues found.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/priority_state.dart apps/plot/test/state/priority_state_unread_filter_test.dart
git commit -m "Add unread filter state and view-items getter to PriorityState"
```

---

## Task 2: Add toggle method and auto-off invariant to `PriorityBloc`

**Files:**
- Modify: `apps/plot/lib/state/priority.dart`

- [ ] **Step 1: Add `toggleUnreadFilter` method to `PriorityBloc`**

Open `apps/plot/lib/state/priority.dart`. Find a stable insertion point near other public mutators (the file is ~3800 lines; any method that calls `emit(state.copyWith(...))` is fine — group with the section-toggle / scope-toggle methods near `_rebuildAgendaModel` if there's a natural cluster, otherwise insert directly above `_rebuildAgendaModel` at line 510):

```dart
  /// Toggle the unread-only filter for the activity feed. No-op when
  /// there are no unread threads in the feed (the header button is
  /// already hidden in that case; the shortcut path falls through).
  void toggleUnreadFilter() {
    if (!state.hasUnreadInFeed) {
      if (state.unreadFilterActive) {
        emit(state.copyWith(unreadFilterActive: false));
      }
      return;
    }
    emit(state.copyWith(unreadFilterActive: !state.unreadFilterActive));
  }
```

- [ ] **Step 2: Add auto-off enforcement inside `_rebuildAgendaModel`**

In the same file, modify `_rebuildAgendaModel` (line 510). After the `AgendaBuilder.build(...)` call and before `emit(...)`, compute whether the recomputed feed still has any unread thread and force-off the filter when it doesn't.

Replace the current emit block (lines 523-531) with:

```dart
    // Auto-off: if the recomputed feed has no unread threads, drop the
    // filter so the user does not land on an empty filtered view next
    // time they return to the priority. The header button hides in the
    // same frame because [hasUnreadInFeed] is now false.
    bool? unreadFilterOverride;
    if (state.unreadFilterActive && activityFeedItems != null) {
      bool anyUnread = false;
      for (final item in activityFeedItems) {
        if (item is AgendaThreadItem && item.thread.unread) {
          anyUnread = true;
          break;
        }
      }
      if (!anyUnread) unreadFilterOverride = false;
    }
    emit(
      state.copyWith(
        thread: thread,
        agenda: agenda,
        agendaItems: agenda.flatItems(),
        activityFeedItems: activityFeedItems,
        activityFeedNativesByDate: activityFeedNativesByDate,
        unreadFilterActive: unreadFilterOverride,
      ),
    );
  }
```

Note: `unreadFilterOverride` stays `null` (no change) when the filter is off or the feed isn't being recomputed in this emit; it goes to `false` only when auto-off triggers. `copyWith` interprets `null` as "keep current".

- [ ] **Step 3: Reset filter on context-priority change**

Find the existing emit site that resets state when the priority context changes — the most obvious tell is `activityFeedItems: const [],` (search for that literal). The matching block is around line 1704:

```dart
        activityFeedItems: const [],
```

Add `unreadFilterActive: false,` immediately after that line so opening a new priority always starts with the filter off:

```dart
        activityFeedItems: const [],
        unreadFilterActive: false,
```

If the search reveals multiple matches that reset the feed on context change, add `unreadFilterActive: false,` to every one of them (search for `activityFeedItems: const [],` to find them all).

- [ ] **Step 4: Verify lint**

Run: `cd apps/plot && flutter analyze lib/state/priority.dart`
Expected: no issues found.

- [ ] **Step 5: Re-run state tests**

Run: `cd apps/plot && flutter test test/state/`
Expected: all state-layer tests still pass (the unread-filter tests from Task 1 and any pre-existing tests).

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/priority.dart
git commit -m "Add toggleUnreadFilter and auto-off invariant to PriorityBloc"
```

---

## Task 3: Add the `ToggleUnreadFilter` command

**Files:**
- Create: `apps/plot/lib/command/unread_filter.dart`
- Test: `apps/plot/test/command/unread_filter_test.dart`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/command/unread_filter_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/unread_filter.dart';

void main() {
  group('ToggleUnreadFilter command', () {
    test('inactive form exposes the shortcut and envelope icons', () {
      final cmd = ToggleUnreadFilter(active: false);
      expect(cmd.title, 'Show unread only');
      expect(cmd.icon, FontAwesomeIcons.envelope);
      expect(cmd.hoverIcon, FontAwesomeIcons.solidEnvelope);
      expect(cmd.on, isFalse);
      expect(cmd.shortcut, isA<SingleActivator>());
      final s = cmd.shortcut as SingleActivator;
      expect(s.trigger, LogicalKeyboardKey.keyU);
      expect(s.shift, isTrue);
      // platformSingleActivator sets either meta or control, never both.
      expect(s.meta || s.control, isTrue);
    });

    test('active form flips title and on flag', () {
      final cmd = ToggleUnreadFilter(active: true);
      expect(cmd.title, 'Showing unread only');
      expect(cmd.on, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/command/unread_filter_test.dart`
Expected: compile error — `package:plot/command/unread_filter.dart` does not exist.

- [ ] **Step 3: Create the command**

Create `apps/plot/lib/command/unread_filter.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/util/shortcut.dart';

import 'base.dart';

/// Toggle the unread-only filter on the current priority's activity
/// feed. Bound to the header [Button.icon] and to a global shortcut
/// scoped to the priority page so the user can switch into and out of
/// a triage view without leaving the editor.
final SingleActivator unreadFilterShortcut =
    platformSingleActivator(LogicalKeyboardKey.keyU, shift: true);

class ToggleUnreadFilter extends Command {
  ToggleUnreadFilter({required bool active})
      : super(
          title: active ? 'Showing unread only' : 'Show unread only',
          icon: FontAwesomeIcons.envelope,
          hoverIcon: FontAwesomeIcons.solidEnvelope,
          eventObject: EventObject.priority,
          eventAction: EventAction.updated,
          shortcut: unreadFilterShortcut,
          on: active,
        );

  /// Used by the priority command list builder, which doesn't otherwise
  /// know the current filter state. Mirrors [ToggleArchivedVisibility]'s
  /// factory pattern: read the bloc once at construction so the command
  /// bar label and the `on` flag reflect live state.
  factory ToggleUnreadFilter.fromContext(BuildContext context) {
    final active =
        context.read<PriorityBloc?>()?.state.unreadFilterActive ?? false;
    return ToggleUnreadFilter(active: active);
  }

  @override
  bool enabled(BuildContext context) {
    final bloc = context.read<PriorityBloc?>();
    if (bloc == null) return false;
    // Allow toggling off even when nothing is unread, so the command
    // is always actionable when the user is in the active state. The
    // bloc handles the no-op case.
    return bloc.state.hasUnreadInFeed || bloc.state.unreadFilterActive;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().toggleUnreadFilter();
    return const CommandDone();
  }
}
```

- [ ] **Step 4: Run the command test to verify it passes**

Run: `cd apps/plot && flutter test test/command/unread_filter_test.dart`
Expected: both tests pass.

- [ ] **Step 5: Verify lint**

Run: `cd apps/plot && flutter analyze lib/command/unread_filter.dart test/command/unread_filter_test.dart`
Expected: no issues found.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/command/unread_filter.dart apps/plot/test/command/unread_filter_test.dart
git commit -m "Add ToggleUnreadFilter command"
```

---

## Task 4: Render the filtered view in the activity feed

**Files:**
- Modify: `apps/plot/lib/page/priority.dart`

- [ ] **Step 1: Switch the body builder to read from `activityFeedViewItems`**

Open `apps/plot/lib/page/priority.dart`. Find `_buildBody` (line 874) and the immediately-following block (line 877):

```dart
        final items = state.activityFeedItems;
```

Replace with:

```dart
        final items = state.activityFeedViewItems;
```

This is the only feed-render read site that needs the filtered view; the others (lines 380, 398, 454) are navigation helpers that walk the full feed to find the next/previous thread, and they should keep operating on `state.activityFeedItems` so up/down navigation does not change semantics when the filter is on.

- [ ] **Step 2: Make the notification-scroll listener tolerate the filter**

Find the `BlocListener<PriorityBloc, PriorityState>` near line 814 (`PendingNotificationScroll`). Its `listenWhen` compares `previous.activityFeedItems != current.activityFeedItems`. That's fine — the notification scroll always targets the unfiltered feed. No change needed in that listener. (Documenting here so the implementer doesn't second-guess.)

- [ ] **Step 3: Verify lint**

Run: `cd apps/plot && flutter analyze lib/page/priority.dart`
Expected: no issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "Render activity feed from activityFeedViewItems"
```

---

## Task 5: Render the toggle button in the unified header

**Files:**
- Modify: `apps/plot/lib/widget/unified_header.dart`

- [ ] **Step 1: Add the command import**

Open `apps/plot/lib/widget/unified_header.dart`. Add the import alongside the existing command imports (around line 13):

```dart
import 'package:plot/command/command.dart';
import 'package:plot/command/unread_filter.dart';
```

- [ ] **Step 2: Insert the button into `withTrackingPill`**

Find `withTrackingPill` inside `_buildTitleSection` (around line 589):

```dart
    Widget withTrackingPill(Widget title) {
      if (state.context.isTwistDev) return title;
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(child: _tightTextBox(child: title)),
          const SizedBox(width: 8),
          _PriorityHeaderTrackingControl(priority: state.context),
        ],
      );
    }
```

Replace the body of `Row.children` with one that conditionally includes the toggle button between the title and the tracking control:

```dart
    Widget withTrackingPill(Widget title) {
      if (state.context.isTwistDev) return title;
      final showUnreadToggle = state.hasUnreadInFeed || state.unreadFilterActive;
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(child: _tightTextBox(child: title)),
          if (showUnreadToggle) ...[
            const SizedBox(width: 8),
            Button.icon(
              ToggleUnreadFilter(active: state.unreadFilterActive),
              selected: state.unreadFilterActive,
            ),
          ],
          const SizedBox(width: 8),
          _PriorityHeaderTrackingControl(priority: state.context),
        ],
      );
    }
```

Notes:
- `state` is the `PriorityState` already passed into `_buildTitleSection`.
- `Button.icon`'s `selected` flag drives the forui `selected` styling. The command's `on` field is what surface-level command lists (menus) read.
- We also show the button when `unreadFilterActive` is true even if (somehow) the unread count hits zero between bloc emits — that lets the user toggle off without waiting for the next feed recompute. The auto-off invariant from Task 2 covers the steady state.

- [ ] **Step 3: Verify lint**

Run: `cd apps/plot && flutter analyze lib/widget/unified_header.dart`
Expected: no issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/unified_header.dart
git commit -m "Add unread filter toggle button to priority header"
```

---

## Task 6: Bind the shortcut into the priority command list

**Files:**
- Modify: `apps/plot/lib/command/priority.dart`

Goal: `⌘⇧U` / `Ctrl+Shift+U` triggers `ToggleUnreadFilter` anywhere on the priority page, including with the NoteEditor focused. The page already mounts `currentPriorityCommandGroups(...)` into a `CommandScope` (see `unified_header.dart` lines 903 and 925, and the timer-shortcut pattern in `lib/command/timer.dart`), so adding the command to that list is enough.

- [ ] **Step 1: Add the import**

In `apps/plot/lib/command/priority.dart`, add alongside other command imports near the top:

```dart
import 'package:plot/command/unread_filter.dart';
```

- [ ] **Step 2: Add the command to `currentPriorityCommands`**

Find `currentPriorityCommands` (line 548 in the current file). The body is:

```dart
List<Command> currentPriorityCommands(
  Priority priority, {
  BuildContext? context,
  NowState? nowState,
}) => [
  ...prioritySecondaryCommands(priority),
  if (context != null) ToggleArchivedVisibility(context: context),
  NewThread(),
  OpenNextThread(),
  OpenPreviousThread(),
  if (nowState != null) ...timerCommands(nowState),
];
```

Add `ToggleUnreadFilter.fromContext(context)` right after `ToggleArchivedVisibility` so the two page-level toggles sit together:

```dart
List<Command> currentPriorityCommands(
  Priority priority, {
  BuildContext? context,
  NowState? nowState,
}) => [
  ...prioritySecondaryCommands(priority),
  if (context != null) ToggleArchivedVisibility(context: context),
  if (context != null) ToggleUnreadFilter.fromContext(context),
  NewThread(),
  OpenNextThread(),
  OpenPreviousThread(),
  if (nowState != null) ...timerCommands(nowState),
];
```

The `enabled()` override gates the shortcut: it is a no-op when the priority has no unread threads and the filter is already off. The `fromContext` factory reads `PriorityBloc.state.unreadFilterActive` so the command bar shows the live label.

- [ ] **Step 3: Verify lint**

Run: `cd apps/plot && flutter analyze lib/command/priority.dart`
Expected: no issues found.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/priority.dart
git commit -m "Bind unread filter shortcut into priority command list"
```

---

## Task 7: End-to-end verification

**Files:** none (manual + repo-wide check).

- [ ] **Step 1: Repo-wide analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no issues found anywhere in the app.

- [ ] **Step 2: Full state-layer tests**

Run: `cd apps/plot && flutter test test/state/ test/command/`
Expected: all tests pass.

- [ ] **Step 3: Manual smoke (hot reload)**

In the running app (hot reload is on per project conventions):

1. Open a priority that currently has at least one unread thread.
   - Verify: envelope button appears in the header between the title and the timer pill.
2. Click the button.
   - Verify: feed collapses to unread items only, grouped under their existing section headers (Doing / Scheduled / New, plus any date sub-headers under Scheduled).
   - Verify: button shows its `selected` styling.
3. Open one of the visible unread threads, then go back to the priority.
   - Verify: that thread is gone from the filtered view (because the feed has been recomputed on return).
4. Open and read every remaining unread thread the same way.
   - Verify: when the last unread is read and you return to the priority, the filter turns itself off and the button disappears in the same frame.
5. Click the button to enable the filter again, then switch to a different priority and back.
   - Verify: the filter is off on return (per-priority, in-memory state).
6. Press `⌘⇧U` (Mac) / `Ctrl+Shift+U` (Win/Linux) while the NoteEditor is focused.
   - Verify: toggle activates exactly as the button does, even without leaving the editor.
7. Open a priority with **no** unread threads.
   - Verify: no envelope button appears, and the shortcut is a no-op.

- [ ] **Step 4: Commit any cleanup**

If the manual pass reveals only fine-tuning (icon size, spacing), make the smallest possible adjustment in `unified_header.dart` and commit:

```bash
git add apps/plot/lib/widget/unified_header.dart
git commit -m "Tighten unread filter button spacing"
```

If no cleanup is needed, skip this step.

- [ ] **Step 5: Update docs**

Per `AGENTS.md`:
- Add a one-line user-facing bullet to the top section of `docs/updates.md`:

```markdown
- Quickly see only unread threads in a priority by toggling the new envelope button (or pressing ⌘⇧U / Ctrl+Shift+U) in the priority header.
```

- Add a corresponding mention under the appropriate section of `docs/features.md` (look for the "Priorities" or "Activity feed" subsection — add a short bullet describing the unread filter capability).

Commit:

```bash
git add docs/updates.md docs/features.md
git commit -m "Document unread filter toggle in updates and features"
```

- [ ] **Step 6: Run `/finalize`**

Per project conventions, finalize before declaring done:

Run: `/finalize`

The skill runs the full checklist (lint, backwards compatibility, error capture, documentation, public submodule). No public-submodule changes are expected for this feature.

---
