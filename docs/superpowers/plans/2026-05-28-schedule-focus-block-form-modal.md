# Keyboard-navigable "Schedule focus block" FormModal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document the "modals must be keyboard-navigable, use the tuned variants" mandate, then rebuild the bespoke "Schedule focus block" modal as a `FormModal` whose date/time/duration fields can be adjusted with the Left/Right cursor keys (Shift for the large jump) while still supporting typing and mouse chevrons.

**Architecture:** A new composite `FormScheduler` form item exposes three focusable sub-slots (date, time-range, duration) and reuses the existing `DurationInput`/`DateInput`/`TimeRangeInput` widgets. A tiny `StepController` (mirroring the existing `FormChannelListController` hook pattern) lets each input expose its chevron actions; a reusable `StepperRow` wrapper maps `←`/`→`/`Shift+←`/`Shift+→` to those actions when the row holds form focus. Range coordination math is extracted into a pure, unit-tested `schedule_range.dart`. The modal definition moves into `command/focus_block.dart` (next to its commands), and `schedule_focus_modal.dart` is deleted.

**Tech Stack:** Flutter (forui only, no material), Drift, the project's `FormModal`/`FormItem` framework (`lib/widget/form.dart`, `lib/widget/form_modal.dart`).

---

## File Structure

- **Create** `apps/plot/lib/widget/step_controller.dart` — `StepController` value holder (no deps; imported by the three input widgets and `form_scheduler.dart`).
- **Create** `apps/plot/lib/widget/schedule_range.dart` — pure date/time/duration range-coordination helpers (`withDate`, `withStart`, `withEnd`, `withDuration`, `shiftedBy`, `clampScheduleRange`).
- **Create** `apps/plot/lib/widget/form_scheduler.dart` — `StepperRow` wrapper + `FormScheduler` form item + its private body widget.
- **Modify** `apps/plot/lib/widget/duration_input.dart`, `date_input.dart`, `time_range_input.dart` — add optional `StepController? stepController` and populate it.
- **Modify** `apps/plot/lib/command/focus_block.dart` — add `scheduleFocusBlockForm(...)` (builds `FormData`) and `openScheduleFocusModal(...)` (builds groups + runs `FormModal`); rewire `OpenScheduleFocusModal`.
- **Modify** `apps/plot/lib/widget/agenda.dart` — call `openScheduleFocusModal(...)` instead of constructing `ScheduleFocusModal` + bare `Modal`.
- **Delete** `apps/plot/lib/widget/schedule_focus_modal.dart`.
- **Modify** `apps/plot/AGENTS.md` — strengthen the "Modals & dialogs" mandate.
- **Modify** memory `feedback_plot_modals.md` + `MEMORY.md` — capture the keyboard-navigability rule.
- **Create tests** `apps/plot/test/widget/schedule_range_test.dart`, `apps/plot/test/widget/stepper_row_test.dart`.

> **Worktree/test note:** Full widget tests that pump a `FormModal` need the app's generated `.g.dart` files and a themed/Store-backed harness, which is heavy and flaky. This plan unit-tests the two extractable, dependency-light units (`schedule_range.dart` pure functions and `StepperRow` key→callback mapping). The composite `FormScheduler`, the form wiring, and the end-to-end keyboard nav are verified by `flutter analyze` + a manual `run-app` pass (Task 8). Run tests with `cd apps/plot && flutter test test/widget/<file>`.

---

## Task 1: Documentation mandate

**Files:**
- Modify: `apps/plot/AGENTS.md` (the "Modals & dialogs" bullet under "Code Style Guidelines")
- Modify: `/Users/kris.braun/.claude/projects/-Users-kris-braun-code-plot/memory/feedback_plot_modals.md`
- Modify: `/Users/kris.braun/.claude/projects/-Users-kris-braun-code-plot/memory/MEMORY.md` (line 33 pointer)

- [ ] **Step 1: Strengthen the AGENTS.md mandate**

In `apps/plot/AGENTS.md`, replace the existing `- **Modals & dialogs**: ...` bullet with:

```markdown
- **Modals & dialogs**: Every modal MUST be fully keyboard-navigable. Always use the project's `Modal` widget (`lib/widget/modal.dart`) or one of its tuned variants — `FormModal` (labeled fields with Tab/↑/↓/Enter/Esc navigation, focus management, and validation), `CommandModal`, `ConfirmModal`, `SelectModal`, `EditorLinkModal`. These encode consistent focus order, highlight, Enter-to-submit, and Esc-to-dismiss; a bespoke `Modal` with hand-rolled focus does not and is not allowed. When a form needs an interaction the built-ins don't cover (e.g. cursor-key value stepping), **extend the framework** — add a new `FormItem` subclass (see `FormScheduler` in `lib/widget/form_scheduler.dart`) — rather than dropping to a raw `Modal` + ad-hoc widgets. Never call `showFDialog` or `showDialog` directly and never render `FDialog` as the outermost modal — those bypass `ModalProvider`, so they render behind existing Plot modals and don't route through `Modal.handleCommandResult`. For yes/no confirmations, use `ConfirmModal(...).run(context)`.
```

- [ ] **Step 2: Update the memory note**

Overwrite `/Users/kris.braun/.claude/projects/-Users-kris-braun-code-plot/memory/feedback_plot_modals.md` with:

```markdown
---
name: feedback_plot_modals
description: All modals must be keyboard-navigable and use the tuned Modal variants (FormModal/CommandModal/etc.), extending rather than bypassing them
metadata:
  type: feedback
---

All dialogs must use `Modal` (`lib/widget/modal.dart`) or a tuned subclass — `FormModal`, `CommandModal`, `ConfirmModal`, `SelectModal`, `EditorLinkModal`. Raw `showFDialog`/`showDialog`/outermost `FDialog` render behind existing Plot modals and skip `ModalProvider`/`Modal.handleCommandResult`.

Every modal MUST be fully keyboard-navigable. Prefer `FormModal` for anything with fields — it provides Tab/↑/↓/Enter/Esc nav, focus management, and validation for free. Do NOT hand-roll focus in a bespoke `Modal`.

**Why:** A bespoke modal (e.g. the old `ScheduleFocusModal`) silently loses keyboard navigation, consistent highlight, Enter-to-submit, and Esc-to-dismiss.

**How to apply:** When an interaction isn't covered by a built-in `FormItem`, extend the framework — add a new `FormItem` subclass (e.g. `FormScheduler` in `lib/widget/form_scheduler.dart`, which adds Left/Right cursor-key value stepping) — instead of dropping to a raw `Modal` + ad-hoc widgets.
```

Then update the matching pointer line in `MEMORY.md` (the `[Use Plot Modal, never FDialog directly]` bullet) to read:

```markdown
- [Modals: keyboard-navigable, use tuned variants](feedback_plot_modals.md): All dialogs use `Modal`/`FormModal`/`CommandModal`/etc. — keyboard-navigable, never bespoke focus, never raw `FDialog`. Extend with new `FormItem`s.
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/AGENTS.md
git commit -m "docs(flutter): mandate keyboard-navigable modals via tuned variants"
```

---

## Task 2: `StepController` + `StepperRow` + tests

**Files:**
- Create: `apps/plot/lib/widget/step_controller.dart`
- Create: `apps/plot/lib/widget/form_scheduler.dart` (StepperRow portion; FormScheduler added in Task 5)
- Test: `apps/plot/test/widget/stepper_row_test.dart`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/widget/stepper_row_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/form_scheduler.dart';

void main() {
  group('StepperRow key handling', () {
    late FocusNode node;
    setUp(() => node = FocusNode());
    tearDown(() => node.dispose());

    Future<void> pump(WidgetTester tester, List<String> log) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StepperRow(
            focusNode: node,
            onStepBack: () => log.add('back'),
            onStepForward: () => log.add('forward'),
            onJumpBack: () => log.add('jumpBack'),
            onJumpForward: () => log.add('jumpForward'),
            child: const SizedBox(width: 100, height: 20),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
    }

    testWidgets('Left/Right step; Shift+Left/Right jump', (tester) async {
      final log = <String>[];
      await pump(tester, log);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(log, ['back', 'forward']);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(log, ['back', 'forward', 'jumpBack', 'jumpForward']);
    });

    testWidgets('Up/Down/Tab do not trigger step callbacks', (tester) async {
      final log = <String>[];
      await pump(tester, log);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      // StepperRow returns `ignored` for these, so none of its step/jump
      // callbacks fire (FormModal handles them at a higher level in the app).
      expect(log, isEmpty);
    });

    testWidgets('paints highlightColor behind the child when provided',
        (tester) async {
      const hl = Color(0xFF123456);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StepperRow(
            focusNode: node,
            highlightColor: hl,
            child: const SizedBox(width: 100, height: 20),
          ),
        ),
      );
      final boxes = tester.widgetList<ColoredBox>(find.byType(ColoredBox));
      expect(boxes.any((b) => b.color == hl), isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/stepper_row_test.dart`
Expected: FAIL — `form_scheduler.dart` / `StepperRow` does not exist (compile error).

- [ ] **Step 3: Create `StepController`**

Create `apps/plot/lib/widget/step_controller.dart`:

```dart
import 'package:flutter/widgets.dart';

/// Bridges a compound input widget's existing increment/decrement actions to a
/// parent that drives them by other means (e.g. cursor keys at the form-row
/// level). Mirrors the `FormChannelListController` hook pattern: the child
/// widget populates the callbacks during build; the parent invokes them.
///
/// All callbacks are null until the child assigns them.
class StepController {
  /// Small decrement (e.g. -15 minutes / -1 day). Bound to `←`.
  VoidCallback? stepBack;

  /// Small increment (e.g. +15 minutes / +1 day). Bound to `→`.
  VoidCallback? stepForward;

  /// Large decrement (e.g. -1 hour / -1 week). Bound to `Shift+←`.
  VoidCallback? jumpBack;

  /// Large increment (e.g. +1 hour / +1 week). Bound to `Shift+→`.
  VoidCallback? jumpForward;

  /// Move keyboard focus into the child's inner editable field so the user can
  /// type a value. Invoked when the form row is activated (Enter / tap).
  VoidCallback? focusEditor;
}
```

- [ ] **Step 4: Create `StepperRow` in `form_scheduler.dart`**

Create `apps/plot/lib/widget/form_scheduler.dart` with (for now) just the imports and `StepperRow`. `StepperRow` is theme-agnostic — it takes a `Color? highlightColor` (the caller, which has the theme, supplies it) so the widget is independently testable and never reaches into `context.theme`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// Wraps a single scheduler row so the Left/Right cursor keys adjust its value
/// when the row holds form focus. Plain `←`/`→` do the small step;
/// `Shift+←`/`Shift+→` do the large jump. Every other key (↑/↓/Tab/Enter/Esc)
/// is returned as ignored so [FormModal]'s own navigation handles it.
///
/// Implicit edit-mode: these handlers only fire when [focusNode] (the row) has
/// focus. When the user clicks into an inner editable field, that field owns
/// focus and consumes `←`/`→` for its text cursor, so typing still works.
///
/// [highlightColor] is painted behind [child] when non-null (the caller decides
/// the row is active and supplies the themed color); null = no background.
class StepperRow extends StatelessWidget {
  const StepperRow({
    required this.focusNode,
    required this.child,
    this.highlightColor,
    this.onStepBack,
    this.onStepForward,
    this.onJumpBack,
    this.onJumpForward,
    super.key,
  });

  final FocusNode focusNode;
  final Widget child;
  final Color? highlightColor;
  final VoidCallback? onStepBack;
  final VoidCallback? onStepForward;
  final VoidCallback? onJumpBack;
  final VoidCallback? onJumpForward;

  bool get _shiftPressed =>
      HardwareKeyboard.instance.logicalKeysPressed
          .contains(LogicalKeyboardKey.shiftLeft) ||
      HardwareKeyboard.instance.logicalKeysPressed
          .contains(LogicalKeyboardKey.shiftRight);

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      final cb = _shiftPressed ? onJumpBack : onStepBack;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      final cb = _shiftPressed ? onJumpForward : onStepForward;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final color = highlightColor;
    return Focus(
      focusNode: focusNode,
      onKeyEvent: _onKey,
      child: color != null ? ColoredBox(color: color, child: child) : child,
    );
  }
}
```

> Design: `StepperRow` only returns `handled` when a callback actually fires (so a missing callback doesn't swallow the key), and it does the highlight via an injected `Color?` rather than a theme lookup — keeping it pure and testable. The themed `editableBackground` color (the same highlight the old modal used, `schedule_focus_modal.dart:204`) is supplied by `FormScheduler` in Task 5.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/stepper_row_test.dart`
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/step_controller.dart apps/plot/lib/widget/form_scheduler.dart apps/plot/test/widget/stepper_row_test.dart
git commit -m "flutter(scheduler): add StepController hook + StepperRow cursor-key wrapper"
```

---

## Task 3: Expose chevron actions on the three input widgets via `StepController`

Each widget gains an optional `StepController? stepController`; in `build()` it assigns its existing private step methods + a `focusEditor`. No behavior change when `stepController` is null (the `Scheduler`/reschedule-modal path).

**Files:**
- Modify: `apps/plot/lib/widget/duration_input.dart`
- Modify: `apps/plot/lib/widget/date_input.dart`
- Modify: `apps/plot/lib/widget/time_range_input.dart`

- [ ] **Step 1: DurationInput — add the param**

In `apps/plot/lib/widget/duration_input.dart`, add the import near the top:

```dart
import 'package:plot/widget/step_controller.dart';
```

Add the field + constructor param (in the `DurationInput` widget, alongside `backgroundColor`):

```dart
  /// Optional hook exposing the +/- step actions for external (keyboard) drivers.
  final StepController? stepController;
```

```dart
  const DurationInput({
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.minutesFocusNode,
    this.autofocus = false,
    this.backgroundColor,
    this.stepController,
    super.key,
  });
```

- [ ] **Step 2: DurationInput — populate the controller**

At the very start of `_DurationInputState.build` (before `final theme = context.theme;`), add:

```dart
    widget.stepController
      ?..stepBack = _decrement15Minutes
      ..stepForward = _increment15Minutes
      ..jumpBack = _decrementHour
      ..jumpForward = _incrementHour
      ..focusEditor = _hoursFocusNode.requestFocus;
```

- [ ] **Step 3: DateInput — add the param**

In `apps/plot/lib/widget/date_input.dart`, add:

```dart
import 'package:plot/widget/step_controller.dart';
```

Field + constructor:

```dart
  /// Optional hook exposing the day/week navigation actions for keyboard drivers.
  final StepController? stepController;
```

```dart
  const DateInput({
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.autofocus = false,
    this.backgroundColor,
    this.stepController,
    super.key,
  });
```

- [ ] **Step 4: DateInput — populate the controller**

At the start of `_DateInputState.build` (before `final theme = context.theme;`):

```dart
    widget.stepController
      ?..stepBack = (() => _navigateDate(-1))
      ..stepForward = (() => _navigateDate(1))
      ..jumpBack = (() => _navigateDate(-7))
      ..jumpForward = (() => _navigateDate(7))
      ..focusEditor = _focusNode.requestFocus;
```

- [ ] **Step 5: TimeRangeInput — add the param**

In `apps/plot/lib/widget/time_range_input.dart`, add:

```dart
import 'package:plot/widget/step_controller.dart';
```

Field + constructor param (alongside `backgroundColor`):

```dart
  /// Optional hook exposing the range-shift actions for keyboard drivers.
  final StepController? stepController;
```

```dart
  const TimeRangeInput({
    required this.startTime,
    required this.endTime,
    required this.onStartTimeChanged,
    required this.onEndTimeChanged,
    required this.onRangeShift,
    this.startTimeFocusNode,
    this.endTimeFocusNode,
    this.autofocus = false,
    this.backgroundColor,
    this.stepController,
    super.key,
  });
```

- [ ] **Step 6: TimeRangeInput — populate the controller**

At the start of `_TimeRangeInputState.build` (before `final theme = context.theme;`):

```dart
    widget.stepController
      ?..stepBack = _shiftLeft15
      ..stepForward = _shiftRight15
      ..jumpBack = _shiftLeft1Hour
      ..jumpForward = _shiftRight1Hour
      ..focusEditor = _startTimeFocusNode.requestFocus;
```

- [ ] **Step 7: Verify analyze is clean**

Run: `cd apps/plot && flutter analyze lib/widget/duration_input.dart lib/widget/date_input.dart lib/widget/time_range_input.dart lib/widget/step_controller.dart`
Expected: "No issues found!"

- [ ] **Step 8: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/duration_input.dart apps/plot/lib/widget/date_input.dart apps/plot/lib/widget/time_range_input.dart
git commit -m "flutter(scheduler): expose chevron step actions via StepController"
```

---

## Task 4: `schedule_range.dart` pure range helpers + tests

**Files:**
- Create: `apps/plot/lib/widget/schedule_range.dart`
- Test: `apps/plot/test/widget/schedule_range_test.dart`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/widget/schedule_range_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/util/time.dart';
import 'package:plot/widget/schedule_range.dart';

void main() {
  // A fixed reference time well in the past so clamp's not-past rule is testable.
  final base = DateTime(2026, 5, 28, 9, 0);
  DateTimeRange r({int durationMin = 30}) =>
      DateTimeRange(base, base.add(Duration(minutes: durationMin)));

  group('withDuration', () {
    test('moves end, keeps start', () {
      final out = withDuration(r(), const Duration(minutes: 90));
      expect(out.start, base);
      expect(out.end, base.add(const Duration(minutes: 90)));
    });
  });

  group('withStart', () {
    test('keeps duration, moves both ends', () {
      final out = withStart(r(durationMin: 60), const FTime(10, 0));
      expect(out.start, DateTime(2026, 5, 28, 10, 0));
      expect(out.end, DateTime(2026, 5, 28, 11, 0));
    });
  });

  group('withEnd', () {
    test('recomputes duration from new end', () {
      final out = withEnd(r(), const FTime(9, 45));
      expect(out.end, DateTime(2026, 5, 28, 9, 45));
      expect(out.duration, const Duration(minutes: 45));
    });
    test('end before start rolls to next day', () {
      final out = withEnd(r(), const FTime(8, 0));
      expect(out.end, DateTime(2026, 5, 29, 8, 0));
    });
  });

  group('withDate', () {
    test('keeps time-of-day and duration on the new date', () {
      final out = withDate(r(durationMin: 45), DateTime(2026, 6, 1));
      expect(out.start, DateTime(2026, 6, 1, 9, 0));
      expect(out.end, DateTime(2026, 6, 1, 9, 45));
    });
  });

  group('shiftedBy', () {
    test('shifts both ends, preserving duration', () {
      final out = shiftedBy(r(durationMin: 30), const Duration(minutes: 15));
      expect(out.start, base.add(const Duration(minutes: 15)));
      expect(out.end, base.add(const Duration(minutes: 45)));
    });
  });

  group('clampScheduleRange', () {
    test('enforces 15-min minimum duration', () {
      final tiny = DateTimeRange(base, base.add(const Duration(minutes: 5)));
      final out = clampScheduleRange(tiny, allowPast: true, now: base);
      expect(out.duration, const Duration(minutes: 15));
    });
    test('when allowPast is false, slides a past range forward keeping duration', () {
      final now = base.add(const Duration(hours: 1)); // 10:00, after start
      final out = clampScheduleRange(r(durationMin: 30), allowPast: false, now: now);
      expect(out.start, now);
      expect(out.duration, const Duration(minutes: 30));
    });
    test('when allowPast is true, leaves a past range alone', () {
      final now = base.add(const Duration(hours: 1));
      final out = clampScheduleRange(r(durationMin: 30), allowPast: true, now: now);
      expect(out.start, base);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/schedule_range_test.dart`
Expected: FAIL — `schedule_range.dart` does not exist.

- [ ] **Step 3: Implement the helpers**

Create `apps/plot/lib/widget/schedule_range.dart`:

```dart
import 'package:forui/forui.dart';

import 'package:plot/util/time.dart';

/// Pure helpers that recompute a [DateTimeRange] when one facet (date, start,
/// end, duration) changes, plus a [clampScheduleRange] that enforces a minimum
/// duration and (optionally) keeps the range out of the past. Extracted so both
/// the scheduler UI and unit tests share one implementation.

const Duration _minDuration = Duration(minutes: 15);
const Duration _fallbackDuration = Duration(minutes: 30);

DateTime _at(DateTime date, FTime time) =>
    DateTime(date.year, date.month, date.day, time.hour, time.minute);

/// Move the range to [date], preserving time-of-day and duration.
DateTimeRange withDate(DateTimeRange range, DateTime date) {
  final start = range.start;
  if (start == null) return range;
  final duration = range.duration ?? _fallbackDuration;
  final newStart = DateTime(
    date.year,
    date.month,
    date.day,
    start.hour,
    start.minute,
  );
  return DateTimeRange(newStart, newStart.add(duration));
}

/// Set the start time-of-day, preserving duration.
DateTimeRange withStart(DateTimeRange range, FTime start) {
  final anchor = range.start ?? Time.now();
  final duration = range.duration ?? _fallbackDuration;
  final newStart = _at(anchor, start);
  return DateTimeRange(newStart, newStart.add(duration));
}

/// Set the end time-of-day, recomputing duration. If the new end is at or
/// before start, it rolls to the next day.
DateTimeRange withEnd(DateTimeRange range, FTime end) {
  final start = range.start ?? Time.now();
  var newEnd = _at(start, end);
  if (!newEnd.isAfter(start)) {
    newEnd = newEnd.add(const Duration(days: 1));
  }
  return DateTimeRange(start, newEnd);
}

/// Set the duration, moving end relative to start.
DateTimeRange withDuration(DateTimeRange range, Duration duration) {
  final start = range.start ?? Time.now();
  return DateTimeRange(start, start.add(duration));
}

/// Shift both ends by [delta], preserving duration.
DateTimeRange shiftedBy(DateTimeRange range, Duration delta) {
  final start = range.start;
  final end = range.end;
  if (start == null || end == null) return range;
  return DateTimeRange(start.add(delta), end.add(delta));
}

/// Enforce a 15-minute minimum duration and, unless [allowPast], keep the range
/// from starting before [now] (sliding it forward and preserving duration).
DateTimeRange clampScheduleRange(
  DateTimeRange range, {
  required bool allowPast,
  required DateTime now,
}) {
  var start = range.start;
  var end = range.end;
  if (start == null || end == null) return range;

  if (!allowPast && start.isBefore(now)) {
    final shift = now.difference(start);
    start = now;
    end = end.add(shift);
  }

  if (end.isBefore(start) || end.difference(start) < _minDuration) {
    end = start.add(_minDuration);
  }

  return DateTimeRange(start, end);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/schedule_range_test.dart`
Expected: PASS (all groups).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/schedule_range.dart apps/plot/test/widget/schedule_range_test.dart
git commit -m "flutter(scheduler): extract pure range-coordination helpers"
```

---

## Task 5: `FormScheduler` form item

Adds `FormScheduler` (and its private body) to `apps/plot/lib/widget/form_scheduler.dart`. Three focusable sub-slots in top-to-bottom order: **0 = date, 1 = time range, 2 = duration**. Owns three `StepController`s (used by `StepperRow` for keys and by `activate` for Enter-to-edit) and the source-of-truth `DateTimeRange`.

**Files:**
- Modify: `apps/plot/lib/widget/form_scheduler.dart`

- [ ] **Step 1: Add imports to `form_scheduler.dart`**

Add these imports below the existing ones (`flutter/widgets.dart`, `flutter/services.dart`) at the top of `apps/plot/lib/widget/form_scheduler.dart`:

```dart
import 'package:forui/forui.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/time.dart';
import 'package:plot/widget/form.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/icon_input_row.dart';
import 'package:plot/widget/date_input.dart';
import 'package:plot/widget/duration_input.dart';
import 'package:plot/widget/time_range_input.dart';
import 'package:plot/widget/schedule_range.dart';
import 'package:plot/widget/step_controller.dart';
```

> `plot_colors.dart` + `forui` give `_FormSchedulerBody` the `context.theme.plotColors.editableBackground` color it passes to each `StepperRow.highlightColor`. (`StepperRow` itself is theme-agnostic.)

- [ ] **Step 2: Add the `FormScheduler` form item**

Append to `apps/plot/lib/widget/form_scheduler.dart`:

```dart
/// A [FormItem] for picking a date + start/end time + duration as a single
/// [DateTimeRange]. Renders three keyboard-steppable rows (date, time, duration)
/// — each a [StepperRow] over the existing chevron+typing input widgets — and
/// exposes them to [FormModal] as three focusable sub-slots. `getValue()`
/// returns the current [DateTimeRange].
class FormScheduler extends FormItem {
  FormScheduler({
    required super.key,
    required DateTimeRange initialRange,
    this.allowPastTimes = false,
    this.onChanged,
  }) : _range = initialRange,
       super(required: true);

  /// When true, past start times are preserved (edit mode). When false, the
  /// range is slid forward to "now" (create mode).
  final bool allowPastTimes;

  /// Optional external change callback.
  final VoidCallback? onChanged;

  DateTimeRange _range;
  final List<VoidCallback> _changeListeners = [];

  /// One controller per sub-slot: [0]=date, [1]=time, [2]=duration.
  final List<StepController> _stepControllers = [
    StepController(),
    StepController(),
    StepController(),
  ];

  @override
  bool get isFocusable => true;

  @override
  int get focusableCount => 3;

  @override
  bool get canActivate => true;

  @override
  DateTimeRange getValue() => _range;

  @override
  void setValue(dynamic value) {
    if (value is DateTimeRange) {
      _range = value;
      _notify();
    }
  }

  @override
  bool isValid() {
    final start = _range.start;
    final end = _range.end;
    return start != null && end != null && end.isAfter(start);
  }

  @override
  void addChangeListener(VoidCallback listener) =>
      _changeListeners.add(listener);

  @override
  void removeChangeListener(VoidCallback listener) =>
      _changeListeners.remove(listener);

  void _notify() {
    onChanged?.call();
    for (final l in _changeListeners) {
      l();
    }
  }

  /// Enter / tap on a row focuses its inner editable field for typing.
  @override
  Future<void> activate(BuildContext context, {int subIndex = 0}) async {
    if (subIndex >= 0 && subIndex < _stepControllers.length) {
      _stepControllers[subIndex].focusEditor?.call();
    }
  }

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    return _FormSchedulerBody(
      range: _range,
      allowPastTimes: allowPastTimes,
      highlightedSubIndex: highlightedSubIndex,
      focusNodes: focusNodes,
      stepControllers: _stepControllers,
      onChanged: (next) {
        _range = next;
        _notify();
      },
    );
  }
}

class _FormSchedulerBody extends StatefulWidget {
  const _FormSchedulerBody({
    required this.range,
    required this.allowPastTimes,
    required this.highlightedSubIndex,
    required this.focusNodes,
    required this.stepControllers,
    required this.onChanged,
  });

  final DateTimeRange range;
  final bool allowPastTimes;
  final int highlightedSubIndex;
  final List<FocusNode> focusNodes;
  final List<StepController> stepControllers;
  final ValueChanged<DateTimeRange> onChanged;

  @override
  State<_FormSchedulerBody> createState() => _FormSchedulerBodyState();
}

class _FormSchedulerBodyState extends State<_FormSchedulerBody> {
  late DateTimeRange _range;

  @override
  void initState() {
    super.initState();
    _range = widget.range;
  }

  @override
  void didUpdateWidget(_FormSchedulerBody old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range && widget.range != _range) {
      _range = widget.range;
    }
  }

  void _apply(DateTimeRange next) {
    final clamped = clampScheduleRange(
      next,
      allowPast: widget.allowPastTimes,
      now: Time.now(),
    );
    setState(() => _range = clamped);
    widget.onChanged(clamped);
  }

  FocusNode _node(int i) =>
      i < widget.focusNodes.length ? widget.focusNodes[i] : FocusNode();

  StepController _ctrl(int i) => widget.stepControllers[i];

  @override
  Widget build(BuildContext context) {
    final start = _range.start;
    final startFTime = start != null ? FTime.fromDateTime(start) : FTime.now();
    final end = _range.end;
    final endFTime = end != null
        ? FTime.fromDateTime(end)
        : FTime.fromDateTime(Time.now().add(const Duration(hours: 1)));

    final highlight = context.theme.plotColors.editableBackground;
    Color? hlFor(int i) => widget.highlightedSubIndex == i ? highlight : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 0: Date
        StepperRow(
          focusNode: _node(0),
          highlightColor: hlFor(0),
          onStepBack: () => _ctrl(0).stepBack?.call(),
          onStepForward: () => _ctrl(0).stepForward?.call(),
          onJumpBack: () => _ctrl(0).jumpBack?.call(),
          onJumpForward: () => _ctrl(0).jumpForward?.call(),
          child: IconInputRow(
            icon: PlotIcon.event,
            content: DateInput(
              value: _range.start,
              onChanged: (date) {
                if (date != null) _apply(withDate(_range, date));
              },
              stepController: _ctrl(0),
            ),
          ),
        ),
        // 1: Time range
        StepperRow(
          focusNode: _node(1),
          highlightColor: hlFor(1),
          onStepBack: () => _ctrl(1).stepBack?.call(),
          onStepForward: () => _ctrl(1).stepForward?.call(),
          onJumpBack: () => _ctrl(1).jumpBack?.call(),
          onJumpForward: () => _ctrl(1).jumpForward?.call(),
          child: IconInputRow(
            icon: PlotIcon.later,
            content: TimeRangeInput(
              startTime: startFTime,
              endTime: endFTime,
              onStartTimeChanged: (t) {
                if (t != null) _apply(withStart(_range, t));
              },
              onEndTimeChanged: (t) {
                if (t != null) _apply(withEnd(_range, t));
              },
              onRangeShift: (delta) => _apply(shiftedBy(_range, delta)),
              stepController: _ctrl(1),
            ),
          ),
        ),
        // 2: Duration
        StepperRow(
          focusNode: _node(2),
          highlightColor: hlFor(2),
          onStepBack: () => _ctrl(2).stepBack?.call(),
          onStepForward: () => _ctrl(2).stepForward?.call(),
          onJumpBack: () => _ctrl(2).jumpBack?.call(),
          onJumpForward: () => _ctrl(2).jumpForward?.call(),
          child: IconInputRow(
            icon: PlotIcon.waiting,
            content: DurationInput(
              value: _range.duration ?? const Duration(minutes: 30),
              onChanged: (d) => _apply(withDuration(_range, d)),
              stepController: _ctrl(2),
            ),
          ),
        ),
      ],
    );
  }
}
```

> The `PlotIcon.event` / `.later` / `.waiting` choices mirror the rows in `scheduler.dart:392-436` (waiting=duration, event=date, later=time). `_node(i)` falls back to a throwaway `FocusNode` only in the impossible case the form passes fewer than three nodes — it never happens because `focusableCount` is 3.

- [ ] **Step 3: Verify analyze is clean**

Run: `cd apps/plot && flutter analyze lib/widget/form_scheduler.dart`
Expected: "No issues found!"

- [ ] **Step 4: Re-run the StepperRow test (no regression)**

Run: `cd apps/plot && flutter test test/widget/stepper_row_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/form_scheduler.dart
git commit -m "flutter(scheduler): add FormScheduler form item (date/time/duration)"
```

---

## Task 6: Build the form + open helper in `focus_block.dart`; rewire `OpenScheduleFocusModal`

The modal definition moves here (next to `ScheduleFocusBlock`/`ArchiveFocusBlock`) to avoid a circular import with the soon-deleted `schedule_focus_modal.dart`.

**Files:**
- Modify: `apps/plot/lib/command/focus_block.dart`

- [ ] **Step 1: Replace the imports + add the form builder and open helper**

In `apps/plot/lib/command/focus_block.dart`, replace this import:

```dart
import 'package:plot/widget/schedule_focus_modal.dart';
```

with:

```dart
import 'package:plot/widget/form_scheduler.dart';
import 'package:plot/util/time.dart';
import 'package:plot/widget/priority.dart' show PriorityLabel;
import 'package:plot/command/priority.dart' show createPriorityInline;
```

> `base.dart` (already imported) re-exports `lib/widget/form.dart`, so `FormData`, `FormSelect`, `FormButton`, `StaticFormGroup`, `FormModal`-related types are in scope. `store.dart` (already imported) provides `Priority`, `PriorityId`, `PriorityOrder`, `Date`, `PriorityBlockRow`. `widget/widget.dart` (already imported) provides `Modal`/`FormModal`.

Then add, at the end of the file:

```dart
/// Build the "Schedule focus block" form. Create mode when [existingRow] is
/// null; edit mode (with Delete + past-time editing) otherwise.
FormData scheduleFocusBlockForm({
  Date? date,
  Priority? initialPriority,
  PriorityBlockRow? existingRow,
}) {
  final isEdit = existingRow != null;

  // Initial range: edit → from the row; create → next 15-min boundary today
  // (or 09:00 on a future date), 30-minute default.
  final DateTimeRange initialRange;
  if (isEdit) {
    final start = existingRow.effectiveAt;
    final duration = existingRow.duration ?? const Duration(minutes: 30);
    initialRange = DateTimeRange(start, start.add(duration));
  } else {
    final base = date?.toDateTime() ?? Date.today().toDateTime();
    final today = Date.today();
    final isToday =
        base.year == today.year &&
        base.month == today.month &&
        base.day == today.day;
    final DateTime start;
    if (isToday) {
      final now = Time.now();
      final remainder = now.minute % 15;
      final pad = remainder == 0 ? 0 : 15 - remainder;
      start = DateTime(now.year, now.month, now.day, now.hour, now.minute + pad);
    } else {
      start = DateTime(base.year, base.month, base.day, 9, 0);
    }
    initialRange = DateTimeRange(start, start.add(const Duration(minutes: 30)));
  }

  final priorityField = FormSelect<Priority>(
    key: 'priority',
    label: 'Priority',
    required: true,
    placeholder: 'Select priority',
    initialValue: initialPriority,
    items: (search) async {
      final priorities = await Priority.get(order: PriorityOrder.nested);
      if (search == null || search.isEmpty) return priorities;
      return priorities.where((p) => p.matchesSearch(search)).toList();
    },
    titleBuilder: (p) => p.title,
    labelBuilder: (p) => PriorityLabel(priority: p),
    onAdd: (ctx) => createPriorityInline(ctx, parent: initialPriority),
  );

  final scheduler = FormScheduler(
    key: 'schedule',
    initialRange: initialRange,
    allowPastTimes: isEdit,
  );

  final items = <FormItem>[
    priorityField,
    scheduler,
    FormButton(
      key: 'submit',
      isPrimary: true,
      buildCommand: (values) {
        final priority = values['priority'] as Priority;
        final range = values['schedule'] as DateTimeRange;
        final start = range.start!;
        final end = range.end!;
        return ScheduleFocusBlock(
          priorityId: priority.id,
          start: start,
          duration: end.difference(start),
          existingRow: existingRow,
        );
      },
    ),
    if (isEdit)
      FormButton(
        key: 'delete',
        skipValidation: true,
        buildCommand: (_) => ArchiveFocusBlock(row: existingRow),
      ),
  ];

  return FormData(
    title: isEdit ? 'Edit focus block' : 'Schedule focus block',
    dismissable: true,
    groups: [StaticFormGroup(items: items)],
  );
}

/// Open the schedule-focus modal as a [FormModal]. Used by both the agenda
/// date-header `+` button (create) and agenda block editing (create or edit).
Future<void> openScheduleFocusModal(
  BuildContext context, {
  Date? date,
  Priority? initialPriority,
  PriorityBlockRow? existingRow,
}) async {
  final form = scheduleFocusBlockForm(
    date: date,
    initialPriority: initialPriority,
    existingRow: existingRow,
  );
  final groups = await form.list();
  if (!context.mounted) return;
  await FormModal(
    form,
    groups: groups,
    rootContext: context,
    constraints: const BoxConstraints(maxHeight: 520, maxWidth: 420),
  ).run(context);
}
```

> `BoxConstraints` comes from `flutter/widgets.dart`, which is transitively available via the existing widget imports (it is already used across the form framework). If analyze flags it as undefined, add `import 'package:flutter/widgets.dart';` to the file.

- [ ] **Step 2: Rewire `OpenScheduleFocusModal.run`**

Replace the body of `OpenScheduleFocusModal.run` with:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    await openScheduleFocusModal(
      context,
      date: date,
      initialPriority: defaultPriority,
    );
    return const CommandDone();
  }
```

- [ ] **Step 3: Verify analyze is clean**

Run: `cd apps/plot && flutter analyze lib/command/focus_block.dart`
Expected: "No issues found!" (If `Date.today()`, `Date.toDateTime()`, `Priority.matchesSearch`, or `PriorityBlockRow.effectiveAt`/`.duration` are flagged, confirm spelling against `lib/store/priority.dart` / `lib/store/priority_block.dart` and `lib/util/time.dart` — they are used identically in the pre-existing `schedule_focus_modal.dart`.)

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/command/focus_block.dart
git commit -m "flutter(focus-block): build Schedule focus block as a FormModal"
```

---

## Task 7: Rewire `agenda.dart`; delete the old modal

**Files:**
- Modify: `apps/plot/lib/widget/agenda.dart`
- Delete: `apps/plot/lib/widget/schedule_focus_modal.dart`

- [ ] **Step 1: Inspect the current agenda call sites**

Run: `cd apps/plot && grep -n "ScheduleFocusModal\|schedule_focus_modal\|import 'package:plot/command/focus_block.dart'\|OpenScheduleFocusModal" lib/widget/agenda.dart`
Expected: an `import` of `schedule_focus_modal.dart` (or via `widget.dart`), the `OpenScheduleFocusModal(...)` use near line 284, and the two `ScheduleFocusModal.edit`/`.create` uses inside `_openFocusBlockEditor` near lines 1081–1096.

- [ ] **Step 2: Replace the `_openFocusBlockEditor` modal opens**

In `apps/plot/lib/widget/agenda.dart`, replace the `if (row != null) { Modal(...).show(); return; } ... Modal(...).show()` block at the end of `_openFocusBlockEditor` (lines ~1080–1096) with:

```dart
    if (row != null) {
      await openScheduleFocusModal(
        context,
        existingRow: row,
        initialPriority: block.priority,
      );
      return;
    }
    final w = _blockWindow;
    final dateForCreate = Date(w.start.year, w.start.month, w.start.day);
    await openScheduleFocusModal(
      context,
      date: dateForCreate,
      initialPriority: block.priority,
    );
```

> `_openFocusBlockEditor` is already `async` and already guards `if (!context.mounted) return;` before this block (line ~1079), so awaiting is safe. `block.priority` is the `Priority` for both branches.

- [ ] **Step 3: Fix imports in agenda.dart**

Ensure `agenda.dart` imports the command helper and drop the old modal import:

- Add (if not present): `import 'package:plot/command/focus_block.dart';`
- Remove any `import 'package:plot/widget/schedule_focus_modal.dart';` line.

Run: `cd apps/plot && grep -n "focus_block.dart\|schedule_focus_modal" lib/widget/agenda.dart` to confirm only the command import remains.

- [ ] **Step 4: Remove the barrel export if present, then delete the file**

Run: `cd apps/plot && grep -n "schedule_focus_modal" lib/widget/widget.dart`
- If a line `export 'schedule_focus_modal.dart';` exists, delete it.
- Add `export 'form_scheduler.dart';` to `lib/widget/widget.dart` (keep the new item discoverable via the barrel).

Then delete the old modal:

```bash
cd /Users/kris.braun/code/plot
git rm apps/plot/lib/widget/schedule_focus_modal.dart
```

- [ ] **Step 5: Verify the whole app still analyzes**

Run: `cd apps/plot && flutter analyze`
Expected: "No issues found!" — in particular, no remaining references to `ScheduleFocusModal`.

Run: `cd apps/plot && grep -rn "ScheduleFocusModal" lib/ test/`
Expected: no matches.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/agenda.dart apps/plot/lib/widget/widget.dart
git rm apps/plot/lib/widget/schedule_focus_modal.dart 2>/dev/null; true
git commit -m "flutter(focus-block): open FormModal from agenda; remove bespoke modal"
```

---

## Task 8: Finalize — analyze, run, docs, manual verification

**Files:**
- Modify: `docs/updates.md` (if user-facing)
- (verification only)

- [ ] **Step 1: Full analyze + targeted tests**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze
flutter test test/widget/stepper_row_test.dart test/widget/schedule_range_test.dart
```
Expected: analyze clean; both test files PASS.

- [ ] **Step 2: Manual verification via the run-app skill**

Invoke the `run-app` skill, launch the app, open the agenda, and:
- From a date-header `+`: confirm the modal opens as a `FormModal` (titled "Schedule focus block", X to close, Esc closes).
- Tab / ↑ / ↓ cycle focus: Priority → Date → Time → Duration → Schedule (→ Delete in edit).
- With Date focused: `←`/`→` change the day; `Shift+←`/`Shift+→` change by a week. Time row: `←`/`→` shift ±15 min; `Shift` ±1 hour. Duration row: `←`/`→` ±15 min; `Shift` ±1 hour.
- Click into a time/date field and confirm typing still works; chevron buttons still work.
- Enter on a row focuses its inner field; Enter on the Schedule button submits and the focus block appears in the agenda.
- Edit an existing block: fields pre-fill, Save updates, Delete removes it.

Capture a screenshot of the modal for the record.

- [ ] **Step 3: Update user-facing docs**

This is a UX improvement to an existing modal (keyboard navigation + cursor-key adjustment). Add a bullet to the top section of `docs/updates.md`:

```markdown
- Scheduling a focus block is now fully keyboard-friendly: Tab between fields and use the arrow keys (Shift for bigger jumps) to adjust the date, time, and duration.
```

- [ ] **Step 4: Run `/finalize`**

Per project convention, run the `/finalize` checklist (lint, backwards-compat, error capture, docs, public submodule). There is no schema, API, or `public/` change here, so expect it to reduce to the lint + docs items already done.

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add docs/updates.md
git commit -m "docs(updates): note keyboard-navigable focus-block scheduling"
```

---

## Self-Review

**Spec coverage:**
- Mandate documented (AGENTS.md + memory) → Task 1. ✓
- Convert modal to `FormModal` → Tasks 5–7. ✓
- Custom components with Left/Right stepping, Shift for large jump → `StepperRow` + `StepController` (Tasks 2–3), wired in `FormScheduler` (Task 5). ✓
- Keep typing + chevrons → input widgets reused unchanged except the additive `StepController`; `StepperRow` only claims `←`/`→` at row-focus level (Task 2 note). ✓
- Enter enters inner editor → `FormScheduler.activate` → `StepController.focusEditor` (Tasks 3, 5). ✓
- Reuse, don't rebuild; `Scheduler`/reschedule untouched → `stepController` optional, `Scheduler` not modified (Task 3). ✓
- Priority via existing `FormSelect`/picker/inline-create → Task 6. ✓
- `FormButton` handles validation/error-toast/pop → Task 6 (bespoke `_onSave`/`_onDelete` deleted with the file in Task 7). ✓
- Tests for range logic + key mapping; analyze + manual for the rest → Tasks 4, 2, 8. ✓
- Out-of-scope `reschedule_event_modal.dart` left alone → confirmed (only `Scheduler` is shared and untouched). ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code; commands have expected output. ✓

**Type consistency:** `StepController` fields (`stepBack`/`stepForward`/`jumpBack`/`jumpForward`/`focusEditor`) are defined in Task 2 and used identically in Tasks 3 and 5. `FormScheduler.getValue()` returns `DateTimeRange`; the form builder reads `values['schedule'] as DateTimeRange` and `values['priority'] as Priority` (Task 6) — matching `FormSelect<Priority>` key `'priority'` and `FormScheduler` key `'schedule'`. `clampScheduleRange(range, {allowPast, now})` signature matches its test (Task 4) and call site (Task 5). `openScheduleFocusModal(context, {date, initialPriority, existingRow})` defined in Task 6, called in Tasks 6 and 7 with matching named args. ✓
