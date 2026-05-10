# Agenda Priority Block Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-priority agenda with a universal `/agenda` view that renders priority blocks only (no individual threads), redesign the priority block as a two-line calendar-style item with hover-revealed duration controls, and consolidate Agenda navigation into a single top-level destination.

**Architecture:** All work is in `apps/plot` (Flutter). No server or database changes. The agenda becomes a new `AgendaPage` mounted at `/agenda` that reuses the existing `PriorityBloc` keyed to the user's default (root) priority, with `AgendaBuilder` switched to a universal mode that emits one block per priority that has scheduled or unread threads for each day. `PriorityPage`'s Agenda tab is removed; the page renders only the activity feed.

**Tech Stack:** Flutter (`flutter/widgets.dart` + `forui` only — never `flutter/material.dart`), `auto_route` for routing, Drift for local persistence, BLoC for state, FontAwesome icons. Project conventions from `apps/plot/AGENTS.md` apply (sentence-case UI text, commands for state changes, Plot `Modal` only).

---

## Spec reference

Source spec: `docs/superpowers/specs/2026-05-09-agenda-priority-block-redesign.md`

## Task ordering rationale

Bottom-up: utilities → data model → command → modal → control widget → header rewrite → page → route → tile → tab removal. Each task ends with `flutter analyze` on the changed package and a commit.

---

## Task 1: Add `isTouchPlatform()` helper

**Files:**
- Modify: `apps/plot/lib/util/platform.dart`
- Test: `apps/plot/test/util/platform_test.dart` (create if missing)

- [ ] **Step 1: Read the existing file**

Run: `cat apps/plot/lib/util/platform.dart`

Confirm `hasPhysicalKeyboard()` and `isMobilePlatform()` exist.

- [ ] **Step 2: Add the helper**

Append to `apps/plot/lib/util/platform.dart`:

```dart
/// True for platforms where the primary input is touch (no physical
/// keyboard). Used to switch UI affordances between hover-revealed
/// (desktop) and tap-to-modal (touch) treatments.
bool isTouchPlatform() => !hasPhysicalKeyboard();
```

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/util/platform.dart`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/util/platform.dart
git commit -m "Add isTouchPlatform() helper"
```

---

## Task 2: Add `summaryLine` and `hasUnread` to `AgendaBlock`

**Files:**
- Modify: `apps/plot/lib/state/agenda_model.dart`

- [ ] **Step 1: Read the sealed class definition**

Run: `sed -n '240,330p' apps/plot/lib/state/agenda_model.dart`

Confirm `AgendaBlock` is a `sealed class` with `id`, `priority`, `threads`, `isOutside` getters and three concrete subclasses (`PriorityBlock`, `GapBlock`, `EventBlock`).

- [ ] **Step 2: Add getters to the sealed class**

In `apps/plot/lib/state/agenda_model.dart`, locate `sealed class AgendaBlock extends Equatable` and add two computed getters at the end of the class body (after the existing abstract getters):

```dart
  /// Joined `displayTitle` of threads in this block with non-empty
  /// titles, separated by ` · `. Empty when no titled threads exist.
  String get summaryLine => threads
      .map((t) => t.displayTitle)
      .where((s) => s.isNotEmpty)
      .join(' · ');

  /// True if any thread in this block is unread.
  bool get hasUnread => threads.any((t) => t.unread);
```

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/agenda_model.dart`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/state/agenda_model.dart
git commit -m "Add summaryLine and hasUnread to AgendaBlock"
```

---

## Task 3: Stop emitting per-thread items from `flatItems()`

The agenda no longer renders individual thread rows — only block headers. `flatItems()` should emit exactly one `AgendaHeaderItem` per block. The `hidden` flag and `contextPriorityId` parameter become unused.

**Files:**
- Modify: `apps/plot/lib/state/agenda_model.dart`
- Modify: `apps/plot/lib/state/priority.dart` (callsite at `_rebuildAgendaModel`, line ~442)

- [ ] **Step 1: Inspect the current `flatItems()` and its callers**

Run: `sed -n '49,189p' apps/plot/lib/state/agenda_model.dart`
Run: `grep -n "flatItems\|agendaItems\|AgendaThreadItem" apps/plot/lib/ -r`

Note every callsite that consumes `agendaItems` and decide whether each one should be replaced (agenda render) or remain on the activity feed. The activity feed uses `state.activityFeedItems` (a separate list), not `agendaItems`.

- [ ] **Step 2: Replace `flatItems()` body**

In `apps/plot/lib/state/agenda_model.dart`, replace the entire `flatItems(...)` method body so it emits exactly one `AgendaHeaderItem` per block, plus the existing date/text section headers. Drop the `contextPriorityId` parameter and the `hidden` flag.

Keep the method's outer signature simple:

```dart
  /// Flattens this model into a render-friendly list. Each block emits
  /// exactly one [AgendaHeaderItem]; per-thread items are not produced
  /// for the agenda view.
  List<AgendaItem> flatItems() {
    final out = <AgendaItem>[];
    for (final section in sections) {
      // Preserve existing date/text section header emission.
      // (Copy the section-header switch from the prior implementation.)
      switch (section) {
        case DateSection():
          out.add(AgendaHeaderItem.date(date: section.date));
        case TextSection():
          out.add(AgendaHeaderItem.text(text: section.text));
      }
      for (final block in section.blocks) {
        out.add(AgendaHeaderItem.block(block: block));
      }
    }
    return out;
  }
```

If the constructors `AgendaHeaderItem.date / .text / .block` don't exist, adapt to whatever named constructors `AgendaHeaderItem` already exposes — the structural intent is "one header item per section header and per block, no thread items."

- [ ] **Step 3: Update the `_rebuildAgendaModel` callsite**

In `apps/plot/lib/state/priority.dart` at line ~442, replace:

```dart
        agendaItems: agenda.flatItems(contextPriorityId: state.context.id),
```

with:

```dart
        agendaItems: agenda.flatItems(),
```

Search the whole repo for any other `flatItems(contextPriorityId:` callsites and update them the same way.

Run: `grep -rn "flatItems(contextPriorityId" apps/plot/lib/`
Expected after this step: no matches.

- [ ] **Step 4: If `AgendaThreadItem` is no longer referenced anywhere, remove it**

Run: `grep -rn "AgendaThreadItem" apps/plot/lib/`

If only test files or commented code reference it, delete `AgendaThreadItem` from `agenda_model.dart` and update the `AgendaItem.when({...})` switch to no longer require an `activity` branch. If `_findThreadInState` in `priority.dart` (line ~459) still depends on iterating `agendaItems` for activity items, change it to iterate the source `state.agenda` blocks directly:

```dart
    for (final section in state.agenda.sections) {
      for (final block in section.blocks) {
        for (final thread in block.threads) {
          if (thread.id == id) return thread;
        }
      }
    }
```

If `AgendaThreadItem` is still used by other widgets, leave it defined but ensure no agenda code emits it.

- [ ] **Step 5: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/agenda_model.dart apps/plot/lib/state/priority.dart
git commit -m "Emit one item per block in agenda flatItems"
```

---

## Task 4: Make `AgendaBuilder` universal across priorities

`AgendaBuilder.build` already accepts a `context` priority used for theming. Today it groups blocks within that subtree. Change it so that, regardless of `context`, every priority with scheduled or unread threads in the input gets its own block per day, and same-priority unread threads (not otherwise scheduled) are merged into each block.

**Files:**
- Modify: `apps/plot/lib/state/agenda_builder.dart`
- Modify: `apps/plot/lib/state/priority.dart` (at `makeAgendaItems`, if defined here)
- Test: `apps/plot/test/state/agenda_builder_test.dart` (create if missing)

- [ ] **Step 1: Read the current builder**

Run: `cat apps/plot/lib/state/agenda_builder.dart`
Run: `grep -n "makeAgendaItems" apps/plot/lib/state/priority.dart`

Identify exactly how the current grouping uses `context` (probably to filter or to seed an "in-context vs outside" distinction).

- [ ] **Step 2: Write a failing test**

Create `apps/plot/test/state/agenda_builder_test.dart` (model on existing tests in `apps/plot/test/state/`):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_builder.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

// Helpers — adapt names to whatever fixture builders the codebase uses
// (e.g. ThreadFactory, PriorityFactory). If none exist, build minimal
// fakes via copyWith on freshly constructed objects.

void main() {
  group('AgendaBuilder universal mode', () {
    test('emits one block per priority with scheduled threads', () {
      final p1 = makePriority(id: 'p1', title: 'Work');
      final p2 = makePriority(id: 'p2', title: 'Personal');
      final t1 = makeThread(priority: p1, scheduledAt: today9am);
      final t2 = makeThread(priority: p2, scheduledAt: today10am);

      final agenda = AgendaBuilder.build(
        threads: [t1, t2],
        context: rootPriority,
        horizonDays: 1,
      );

      final blockPriorities = agenda.sections
          .expand((s) => s.blocks)
          .map((b) => b.priority.id)
          .toSet();
      expect(blockPriorities, containsAll([p1.id, p2.id]));
    });

    test('merges same-priority unread thread into block summary', () {
      final p = makePriority(id: 'p', title: 'Work');
      final scheduled = makeThread(priority: p, scheduledAt: today9am, title: 'Standup');
      final unread = makeThread(priority: p, unread: true, title: 'PR review');

      final agenda = AgendaBuilder.build(
        threads: [scheduled, unread],
        context: rootPriority,
        horizonDays: 1,
      );

      final block = agenda.sections.first.blocks.first;
      expect(block.threads.length, 2);
      expect(block.summaryLine, contains('Standup'));
      expect(block.summaryLine, contains('PR review'));
      expect(block.hasUnread, isTrue);
    });
  });
}
```

If the existing fixture/factory helpers in `apps/plot/test/` use different names, adapt. The point is two tests: (a) blocks span priorities, (b) unread threads get merged.

- [ ] **Step 3: Run the test to confirm it fails**

Run: `cd apps/plot && flutter test test/state/agenda_builder_test.dart`
Expected: FAIL — either compilation errors (until factories exist) or assertion failures showing only the in-context priority's blocks.

- [ ] **Step 4: Update the builder**

In `apps/plot/lib/state/agenda_builder.dart`, change `AgendaBuilder.build` (and `PriorityState.makeAgendaItems` in `priority.dart` if it's the one that does the grouping) to:

- Group input `threads` by their priority for each day, regardless of whether the priority is in-context.
- For each day × priority combination with at least one scheduled thread (or one unread thread), emit a single block. Use existing block-type selection logic (event vs gap vs priority block) per group.
- After scheduled-block construction, find unread threads in the input that are not already in any block for that day and append each to the block matching its priority (creating a new `PriorityBlock` for that day if no scheduled block exists for that priority). Sort appended unread threads after scheduled threads by `updatedAt` desc.
- Drop the in-context vs outside-context distinction; remove `isOutside` settings inside the agenda render path. Leave `isOutside` on the data class for now (no consumer relies on it false-vs-true after this change), but make the builder always set it to `false` so legacy reads stay safe.

- [ ] **Step 5: Run the test to confirm it passes**

Run: `cd apps/plot && flutter test test/state/agenda_builder_test.dart`
Expected: PASS.

- [ ] **Step 6: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/state/agenda_builder.dart apps/plot/lib/state/priority.dart apps/plot/test/state/agenda_builder_test.dart
git commit -m "Build agenda blocks across all priorities; merge unread threads"
```

---

## Task 5: Add `SetThreadDuration` command

Mutates `thread.at.duration` for an event block's event thread. A null new duration removes the end time, leaving an `at.start`-only schedule (existing model already supports this).

**Files:**
- Modify: `apps/plot/lib/command/thread.dart` (or wherever schedule commands live — `grep -n "extends.*Command" apps/plot/lib/command/thread.dart` first)
- Test: `apps/plot/test/command/thread_test.dart` (extend if it exists; create if not)

- [ ] **Step 1: Find the existing schedule-mutation command pattern**

Run: `grep -n "class.*Schedule\|class.*At.*Command\|copyWith(at:" apps/plot/lib/command/thread.dart`

Find a command that already mutates `thread.at` (e.g. `ScheduleThread`, `MoveThreadTime`). Use it as a template. If none exists, model on `FinishThread` (shown in research notes).

- [ ] **Step 2: Write a failing test**

In `apps/plot/test/command/thread_test.dart`:

```dart
test('SetThreadDuration changes at.duration', () async {
  final thread = makeThread(scheduledAt: today9am, duration: const Duration(minutes: 30));
  final cmd = SetThreadDuration(thread, const Duration(minutes: 45));

  // Build a test BuildContext / mock store as other thread tests do.
  await cmd.run(testContext);

  final saved = await store.threads.findById(thread.id);
  expect(saved.at?.duration, const Duration(minutes: 45));
});

test('SetThreadDuration with null clears the end', () async {
  final thread = makeThread(scheduledAt: today9am, duration: const Duration(minutes: 30));
  final cmd = SetThreadDuration(thread, null);

  await cmd.run(testContext);

  final saved = await store.threads.findById(thread.id);
  expect(saved.at?.start, today9am);
  expect(saved.at?.end, isNull);
});
```

Adapt to the test harness used by sibling `apps/plot/test/command/*` tests.

- [ ] **Step 3: Confirm the test fails**

Run: `cd apps/plot && flutter test test/command/thread_test.dart -p`
Expected: FAIL — `SetThreadDuration` undefined.

- [ ] **Step 4: Implement the command**

Append to `apps/plot/lib/command/thread.dart`:

```dart
class SetThreadDuration extends _UpdateThreadCommand {
  SetThreadDuration(super.thread, this.newDuration, {super.onUpdate})
      : super(
          title: 'Set duration',
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  final Duration? newDuration;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final at = thread.at;
    if (at?.start == null) return const CommandDone();
    final newAt = newDuration == null
        ? DateTimeRange(start: at!.start, end: null)
        : DateTimeRange(
            start: at!.start,
            end: at.start!.add(newDuration!),
          );
    await saveOptimistically(context, thread.copyWith(at: Value(newAt)));
    return const CommandDone();
  }
}
```

If `_UpdateThreadCommand` requires different super-args or `saveOptimistically` is not the helper name in this file, mirror an adjacent command verbatim.

- [ ] **Step 5: Run the test to confirm it passes**

Run: `cd apps/plot && flutter test test/command/thread_test.dart -p`
Expected: PASS.

- [ ] **Step 6: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/command/`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/command/thread.dart apps/plot/test/command/thread_test.dart
git commit -m "Add SetThreadDuration command"
```

---

## Task 6: Create `DurationModal` (touch picker)

**Files:**
- Create: `apps/plot/lib/widget/duration_modal.dart`

- [ ] **Step 1: Read the Modal pattern**

Run: `cat apps/plot/lib/widget/confirm_modal.dart`
Run: `sed -n '1,60p' apps/plot/lib/widget/modal.dart`

Confirm the `Modal` constructor signature (builder, header, etc.) and `Modal.pop<T>(context, Value<T>(...))`.

- [ ] **Step 2: Write the modal**

Create `apps/plot/lib/widget/duration_modal.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/util/value.dart';
import 'package:plot/widget/modal.dart';

class DurationModal {
  const DurationModal({this.initial});

  final Duration? initial;

  static const _step = Duration(minutes: 15);
  static const _presets = [
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 2),
  ];

  Future<Value<Duration?>> show(BuildContext context) {
    return Modal(
      builder: (ctx) => _DurationModalBody(initial: initial),
    ).show<Duration?>(context);
  }
}

class _DurationModalBody extends StatefulWidget {
  const _DurationModalBody({required this.initial});

  final Duration? initial;

  @override
  State<_DurationModalBody> createState() => _DurationModalBodyState();
}

class _DurationModalBodyState extends State<_DurationModalBody> {
  late Duration _value = widget.initial ?? Duration.zero;

  void _bump(Duration delta) {
    setState(() {
      final next = _value + delta;
      _value = next < Duration.zero ? Duration.zero : next;
    });
  }

  void _set(Duration d) => setState(() => _value = d);

  void _commit(Duration? d) {
    Modal.pop<Duration?>(context, Value(d));
  }

  @override
  Widget build(BuildContext context) {
    final spacing = context.theme.spacing;
    return Padding(
      padding: EdgeInsets.all(spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(_format(_value),
              style: context.theme.typography.xl3.copyWith(
                fontWeight: FontWeight.w600,
              )),
          SizedBox(height: spacing.lg),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StepButton(label: '−', onTap: () => _bump(-DurationModal._step)),
              SizedBox(width: spacing.lg),
              _StepButton(label: '+', onTap: () => _bump(DurationModal._step)),
            ],
          ),
          SizedBox(height: spacing.lg),
          Wrap(
            spacing: spacing.sm,
            children: [
              for (final p in DurationModal._presets)
                FButton(
                  style: FButtonStyle.outline,
                  onPress: () => _set(p),
                  label: Text(_format(p)),
                ),
            ],
          ),
          SizedBox(height: spacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              FButton(
                style: FButtonStyle.ghost,
                onPress: () => _commit(null),
                label: const Text('Clear'),
              ),
              FButton(
                onPress: () =>
                    _commit(_value == Duration.zero ? null : _value),
                label: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _format(Duration d) {
    if (d == Duration.zero) return '0m';
    final h = d.inHours;
    final m = d.inMinutes - h * 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.colour.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.colour.border),
        ),
        child: Text(label, style: const TextStyle(fontSize: 22)),
      ),
    );
  }
}
```

If `FButton` props differ in this codebase's `forui` version, adapt to the local version's API (compile errors will tell you the right names).

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/widget/duration_modal.dart`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/duration_modal.dart
git commit -m "Add DurationModal for touch duration editing"
```

---

## Task 7: Build `_DurationControl` widget (hover stepper / touch trigger)

The control renders the duration value. On hover (desktop), `−` and `+` glyphs slide in at the outer edges and the surrounding strip becomes a two-half hit zone. On touch (`isTouchPlatform()`), a single tap opens `DurationModal`.

**Files:**
- Create: `apps/plot/lib/widget/duration_control.dart`

- [ ] **Step 1: Implement the widget**

Create `apps/plot/lib/widget/duration_control.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/duration_modal.dart';

class DurationControl extends StatefulWidget {
  const DurationControl({
    required this.value,
    required this.onChanged,
    required this.foreground,
    super.key,
  });

  /// Current duration. Null means "no duration set".
  final Duration? value;

  /// Called with the new duration. `null` means "clear duration".
  /// If null, the control renders read-only (no controls revealed,
  /// no tap handler).
  final ValueChanged<Duration?>? onChanged;

  /// Foreground accent color (priority's display color).
  final Color foreground;

  static const _step = Duration(minutes: 15);

  @override
  State<DurationControl> createState() => _DurationControlState();
}

class _DurationControlState extends State<DurationControl> {
  bool _hover = false;

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes - h * 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h${m}m';
  }

  Duration? _bump(Duration? current, Duration delta) {
    final next = (current ?? Duration.zero) + delta;
    if (next <= Duration.zero) return null;
    return next;
  }

  Future<void> _openModal() async {
    final result = await DurationModal(initial: widget.value).show(context);
    if (!result.present) return;
    widget.onChanged?.call(result.value);
  }

  @override
  Widget build(BuildContext context) {
    final fontSize = context.theme.typography.xs.fontSize ?? 11;
    final readOnly = widget.onChanged == null;
    final value = widget.value;

    if (isTouchPlatform()) {
      return GestureDetector(
        onTap: readOnly ? null : _openModal,
        child: _label(value, fontSize),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        height: 20,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _HitHalf(
              visible: _hover && !readOnly && value != null,
              glyph: '−',
              onTap: readOnly
                  ? null
                  : () => widget.onChanged!(_bump(value, -DurationControl._step)),
              fontSize: fontSize,
            ),
            _label(value, fontSize),
            _HitHalf(
              visible: _hover && !readOnly,
              glyph: '+',
              onTap: readOnly
                  ? null
                  : () => widget.onChanged!(_bump(value, DurationControl._step)),
              fontSize: fontSize,
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(Duration? value, double fontSize) {
    final text = value == null ? '' : _format(value);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(text,
          style: TextStyle(
            fontSize: fontSize,
            color: context.colour.foreground,
            height: 1,
          )),
    );
  }
}

class _HitHalf extends StatelessWidget {
  const _HitHalf({
    required this.visible,
    required this.glyph,
    required this.onTap,
    required this.fontSize,
  });

  final bool visible;
  final String glyph;
  final VoidCallback? onTap;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 18,
        height: 20,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: Center(
            child: Text(glyph,
                style: TextStyle(
                  fontSize: fontSize + 1,
                  height: 1,
                  color: context.colour.foreground,
                )),
          ),
        ),
      ),
    );
  }
}
```

The "value strip split at center" behavior is implemented by giving each `_HitHalf` opaque hit-testing and placing them on either side of the value label. The label itself doesn't capture taps because it's wrapped only in `Padding`.

- [ ] **Step 2: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/widget/duration_control.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/duration_control.dart
git commit -m "Add DurationControl with hover stepper / touch modal"
```

---

## Task 8: Rewrite `_BlockHeader` to the new two-line layout

Replace the current single-row `_buildRow` with the spec's two-line layout. Add unread dot to the gutter (below time), event title + breadcrumb (with dimmed ancestors) on line 1, joined-titles summary on line 2, RSVP + duration control on the right. Make the row tap navigate to the priority. Remove all chevron / `priorityContext` / `isOutsidePriority` plumbing.

**Files:**
- Modify: `apps/plot/lib/widget/agenda.dart`

- [ ] **Step 1: Read current header construction**

Run: `sed -n '427,800p' apps/plot/lib/widget/agenda.dart`

Note: `_buildRow`, `_buildFeedback`, `_buildGrip`, drag wiring, `_scheduleTick`, the `priorityContext` parameter throughout `AgendaHeader` and `_BlockHeader`, the `isOutsidePriority` field.

- [ ] **Step 2: Remove `priorityContext` and `isOutsidePriority` from `AgendaHeader` and `_BlockHeader`**

In `apps/plot/lib/widget/agenda.dart`:

- Delete the `priorityContext` field on `AgendaHeader` and `_BlockHeader`.
- Delete the `isOutsidePriority` field on `AgendaHeader` and `_BlockHeader`.
- Remove `priorityContext:` and `isOutsidePriority:` from every constructor invocation in this file.
- Update every callsite of `AgendaHeader(...)` in the codebase (search):

  Run: `grep -rn "AgendaHeader(" apps/plot/lib/`

  Remove `priorityContext:`, `isOutsidePriority:` named args.

- [ ] **Step 3: Add the block to `_BlockHeader`**

`_BlockHeader` should accept the full `AgendaBlock` (so it can compute the summary line, hasUnread, click target). Replace the current arg list:

```dart
class _BlockHeader extends StatefulWidget {
  const _BlockHeader({
    required this.block,
    required this.dateTimeRange,
    required this.thread,
    required this.now,
    required this.isNext,
    required this.parentBlockId,
    required this.sourceDate,
    required this.sourcePeriodStart,
    required this.parentBlockVisibleCount,
  });

  final AgendaBlock block;
  final DateTimeRange? dateTimeRange;
  final Thread? thread;
  final bool now;
  final bool isNext;
  final String? parentBlockId;
  final Date? sourceDate;
  final DateTime? sourcePeriodStart;
  final int? parentBlockVisibleCount;

  Priority get priority => block.priority;

  @override
  State<_BlockHeader> createState() => _BlockHeaderState();
}
```

Update the `AgendaHeader.build` branch (line ~93) that constructs `_BlockHeader` to pass the block. The `AgendaHeader.blockPriority` field becomes `block` (or remove `blockPriority` and accept `block` directly).

- [ ] **Step 4: Replace `_buildRow` body**

Replace the entire body of `_buildRow` in `_BlockHeaderState` with the two-line layout. Keep the surrounding Container/coloring and the `grip` overlay parameter. Strip the chevron entirely.

```dart
  Widget _buildRow(BuildContext context, {Widget? grip}) {
    final block = widget.block;
    final priority = block.priority;
    final dateTimeRange = widget.dateTimeRange;
    final thread = widget.thread;

    final fg = context.colour.colours.fromTheme(priority.displayColor);
    final mutedFg = context.colour.colours.fromTheme(priority.displayColor, muted: true);
    final bg = context.colour.colours.backgroundFromTheme(priority.displayColor);
    final spacing = context.theme.spacing;
    final smSize = context.theme.typography.sm.fontSize ?? 14;
    final xsSize = context.theme.typography.xs.fontSize ?? 12;
    final currentTime = Time.now();

    final hasTime = dateTimeRange != null;
    final timeOfDay = dateTimeRange?.start?.toTimeOfDay();
    final timeText = hasTime && timeOfDay != null && !timeOfDay.isMidnight
        ? (context.isMultiPanel
            ? timeOfDay.formatShort(context)
            : timeOfDay.formatNarrow(context))
        : null;

    final summary = block.summaryLine;
    final hasUnread = block.hasUnread;

    // Right meta children (RSVP + duration / active timing).
    final rightChildren = <Widget>[];
    if (thread != null && thread.hasOtherAttendees) {
      rightChildren.add(RsvpSummary(activity: thread));
      rightChildren.add(SizedBox(width: spacing.sm));
      rightChildren.add(Text('·',
          style: TextStyle(color: mutedFg, fontSize: xsSize, height: 1)));
      rightChildren.add(SizedBox(width: spacing.sm));
    }

    // Active-timing display (out-of-scope wiring; keep stub for now).
    if (widget.now && thread?.at?.start != null) {
      final start = thread!.at!.start!;
      final end = thread.at!.end;
      final elapsed = currentTime.difference(start).inMinutes;
      if (elapsed >= 1) {
        rightChildren.add(Text('↑${Duration(minutes: elapsed).format()}',
            style: TextStyle(color: fg, fontSize: xsSize, height: 1)));
      }
      if (end != null && end.isAfter(currentTime)) {
        final remaining =
            (end.difference(currentTime).inSeconds / 60).ceil();
        rightChildren.add(SizedBox(width: spacing.xs));
        rightChildren.add(Text('/ ${Duration(minutes: remaining).format()}',
            style: TextStyle(color: mutedFg, fontSize: xsSize, height: 1)));
      }
    } else {
      // Static duration with hover stepper.
      rightChildren.add(DurationControl(
        value: dateTimeRange?.duration,
        onChanged: thread == null
            ? null
            : (newDur) => SetThreadDuration(thread, newDur).run(context),
        foreground: fg,
      ));
    }

    final timeColWidth = agendaLeadingWidth(context);

    return Container(
      color: bg,
      padding: EdgeInsets.symmetric(vertical: spacing.sm),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (grip != null) grip,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: timeColWidth,
                child: Padding(
                  padding: EdgeInsets.only(right: spacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (timeText != null)
                        Text(timeText,
                            style: TextStyle(
                              color: context.colour.foreground,
                              fontSize: xsSize,
                              height: 1,
                            )),
                      if (hasUnread) ...[
                        SizedBox(height: 4),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: context.colour.colours.unread,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        if (thread != null) ...[
                          Flexible(
                            child: Text(
                              thread.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: fg,
                                fontSize: smSize,
                                fontWeight: FontWeight.w600,
                                height: 1,
                              ),
                            ),
                          ),
                          SizedBox(width: spacing.sm),
                        ],
                        Flexible(
                          child: PriorityLabel(
                            priority: priority,
                            color: fg,
                            mutedAncestorColor: mutedFg,
                            fontSize: thread != null ? xsSize : smSize,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                    if (summary.isNotEmpty) ...[
                      SizedBox(height: spacing.xs),
                      Text(summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: mutedFg,
                            fontSize: xsSize,
                            height: 1.25,
                          )),
                    ],
                  ],
                ),
              ),
              SizedBox(width: spacing.sm),
              ...rightChildren,
              SizedBox(width: spacing.lg),
            ],
          ),
        ],
      ),
    );
  }
```

Notes for the engineer:
- `PriorityLabel` may not currently expose `mutedAncestorColor`. If not, edit `apps/plot/lib/widget/priority.dart` to add an optional `mutedAncestorColor` parameter that, when set, renders ancestor crumbs with that color while leaving the leaf at `color`. Default to `color` when unset (preserves existing behavior). Keep this change small and additive.
- `context.colour.colours.unread` — if no such accessor exists, use the constant currently used by `_DotPainter` in `priority_notification.dart` (likely a hard-coded blue). Pull it into a named getter on `colours` if convenient.
- The `SetSavingDuration` invocation uses `SetThreadDuration` from Task 5. Import it.

- [ ] **Step 5: Wrap the row with a tap handler that navigates to the priority**

Wrap the returned `Container` in a `GestureDetector` that triggers navigation:

```dart
    final body = Container(
      // …everything from above…
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => OpenPriority(priority).run(context),
      child: body,
    );
```

If a navigation command like `OpenPriority` doesn't already exist, add it as a small command in `apps/plot/lib/command/priority.dart` (or wherever priority commands live):

```dart
class OpenPriority extends Command {
  OpenPriority(this.priority)
      : super(
          title: 'Open ${priority.title}',
          eventObject: EventObject.priority,
          eventAction: EventAction.opened,
        );

  final Priority priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    AutoRouter.of(context)
        .push(PriorityRoute(priorityIdString: priority.id.toShortString()));
    return const CommandDone();
  }
}
```

`DurationControl`'s gesture detectors will absorb taps on the duration strip before this outer detector fires (HitTestBehavior.opaque on the inner detectors handles this).

- [ ] **Step 6: Strip the chevron / expansion plumbing**

- Remove any rotated chevron widget from the row.
- Remove any code that reads/writes a "context priority" expansion state from `_BlockHeader` and its parent.

- [ ] **Step 7: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/widget/agenda.dart lib/widget/priority.dart`
Expected: `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/widget/agenda.dart apps/plot/lib/widget/priority.dart apps/plot/lib/command/priority.dart
git commit -m "Redesign _BlockHeader as two-line block with duration control"
```

---

## Task 9: Create `AgendaPage`

A page mounted at `/agenda` that hosts the universal agenda. Reuses the existing `PriorityBloc` keyed to the user's default priority (the same value the old root redirect used) and renders the agenda widget without the activity-feed branch.

**Files:**
- Create: `apps/plot/lib/page/agenda.dart`

- [ ] **Step 1: Read PriorityPage's app-shell wiring**

Run: `sed -n '1,80p' apps/plot/lib/page/priority.dart`
Run: `grep -n "PriorityBlocProvider\|BlocProvider<PriorityBloc>" apps/plot/lib/`

Confirm how `PriorityBlocProvider` is constructed and which Bloc(s) it provides. The new `AgendaPage` needs the same wrapper.

- [ ] **Step 2: Implement the page**

Create `apps/plot/lib/page/agenda.dart`:

```dart
import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/agenda.dart' as agenda_widget;

@RoutePage()
class AgendaPage extends StatelessWidget {
  const AgendaPage({super.key});

  @override
  Widget build(BuildContext context) {
    final defaultPriority =
        context.read<NowBloc>().loadedState.defaultPriority;

    return PriorityBlocProvider(
      priority: defaultPriority,
      child: BlocBuilder<PriorityBloc, PriorityState>(
        builder: (context, state) {
          if (state.loading) {
            return const Center(child: SizedBox.shrink());
          }
          // Render only the agenda — no tabs, no activity feed.
          return agenda_widget.AgendaList(items: state.agendaItems);
        },
      ),
    );
  }
}
```

If the agenda is rendered inside `PriorityPage` by a private widget rather than an exported `AgendaList`, extract the agenda rendering into a public widget in `apps/plot/lib/widget/agenda.dart` first (call it `AgendaList`) and use it from both pages. Move only the agenda body — leave the activity-feed branch in `PriorityPage`.

If `PriorityBlocProvider` does not accept a `priority` parameter directly, look at how the existing `PriorityRoute` constructs it (priority.dart line 2569+) and mirror that pattern, building from `defaultPriority` instead of the route param.

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/page/agenda.dart lib/widget/agenda.dart`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/page/agenda.dart apps/plot/lib/widget/agenda.dart
git commit -m "Add AgendaPage hosting universal agenda"
```

---

## Task 10: Add `/agenda` route and redirect root to it

**Files:**
- Modify: `apps/plot/lib/router.dart`

- [ ] **Step 1: Read the current routes block**

Run: `sed -n '110,205p' apps/plot/lib/router.dart`

Locate the root redirect at lines ~136-155 (the one that replaces with `PriorityRoute(defaultPriority)`).

- [ ] **Step 2: Add the new route and change the redirect**

In `apps/plot/lib/router.dart`:

a) Add an `AgendaRoute` entry alongside the existing children of `AppShellRoute` (sibling to `PriorityShellRoute` etc.):

```dart
        AutoRoute(
          page: AgendaRoute.page,
          path: 'agenda',
          guards: [AuthGuard()],
        ),
```

b) Change the root-path redirect to push `AgendaRoute` instead of `PriorityRoute(defaultPriority)`:

```dart
        AutoRoute(
          page: EmptyShellRoute("Now"),
          path: '',
          guards: [
            AuthGuard(),
            AutoRouteGuardCallback((resolver, router) async {
              router.replaceAll([const AgendaRoute()]);
            }),
          ],
        ),
```

The `NowBloc.loading` check that the previous version did is no longer needed (the `AgendaPage` handles its own loading state via `PriorityBloc`).

- [ ] **Step 3: Regenerate route definitions**

Run: `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs`
Expected: regenerates `router.gr.dart` (or equivalent) with `AgendaRoute` and `AgendaRoute.page`. If the generator complains, ensure `AgendaPage` is annotated `@RoutePage()` (Task 9).

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/router.dart`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/router.dart apps/plot/lib/router.gr.dart
git commit -m "Add /agenda route and redirect root to it"
```

---

## Task 11: Replace Everything tile with Agenda tile (gated by bottom nav)

**Files:**
- Modify: `apps/plot/lib/widget/priorities_list.dart`

- [ ] **Step 1: Read the Everything tile construction**

Run: `sed -n '380,470p' apps/plot/lib/widget/priorities_list.dart`

Note the surrounding loop / list structure where the tile is inserted. The Everything tile is the special root entry whose `command` is `ChangeCurrentPriority(widget.root)`.

- [ ] **Step 2: Replace the tile and gate visibility**

In `apps/plot/lib/widget/priorities_list.dart`:

a) Replace the Everything `ListTile` block (lines ~410-457) with an Agenda tile:

```dart
        if (context.isMultiPanel) // hide on layouts where bottom nav owns Agenda
          ListTile(
            title: 'Agenda',
            command: OpenAgenda(),
            leadingBuilder: (isHovered, hasFocus) => Padding(
              padding: EdgeInsets.only(
                left: context.theme.spacing.lg,
                right: context.theme.spacing.sm,
                bottom: 2,
              ),
              child: FaIcon(
                FontAwesomeIcons.calendar,
                size: 16,
                color: context.colour.foreground,
              ),
            ),
            textStyle: itemStyle,
          ),
```

The existing `_hasDescendantUnread` / `_hasDescendantActive` calls are dropped — no notification widget for this tile.

b) Add the navigation command. Create or extend `apps/plot/lib/command/agenda.dart`:

```dart
import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:plot/command/base.dart';
import 'package:plot/router.dart';
import 'package:plot/event/event.dart';

class OpenAgenda extends Command {
  OpenAgenda()
      : super(
          title: 'Open agenda',
          eventObject: EventObject.priority,
          eventAction: EventAction.opened,
        );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    AutoRouter.of(context).push(const AgendaRoute());
    return const CommandDone();
  }
}
```

If the project has a different `Command`-base import path, mirror what `ChangeCurrentPriority` uses (run `grep -rn "class ChangeCurrentPriority" apps/plot/lib/`).

- [ ] **Step 3: Verify bottom-nav visibility logic**

Run: `grep -rn "BottomNavigation\|bottomNavigationBar\|isMultiPanel" apps/plot/lib/` to confirm `context.isMultiPanel` is `true` on layouts WITHOUT a bottom nav (sidebar layout) and `false` on layouts WITH a bottom nav. The pattern matches the gating: `if (context.isMultiPanel) ...`.

If it turns out the existing app uses a different signal for "bottom nav showing" (e.g. an explicit `LayoutState.useBottomNav`), use that instead.

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/widget/priorities_list.dart lib/command/agenda.dart`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/priorities_list.dart apps/plot/lib/command/agenda.dart
git commit -m "Replace Everything tile with Agenda tile (hidden when bottom nav)"
```

---

## Task 12: Remove Agenda/Activity tabs from `PriorityPage`

**Files:**
- Modify: `apps/plot/lib/page/priority.dart`

- [ ] **Step 1: Locate the tab plumbing**

Run: `grep -n "PriorityTab\|_currentTab\|isUpNext" apps/plot/lib/page/priority.dart`

Identify every read/write of `_currentTab` and the conditional that switches between `agendaViewItems` and `activityFeedItems`.

- [ ] **Step 2: Strip the tab state**

In `apps/plot/lib/page/priority.dart`:

- Delete the `_currentTab` field on `_PriorityPageState`.
- Delete the `enum PriorityTab` (line ~30) if no other consumer references it. Run `grep -rn "PriorityTab" apps/plot/lib/` to check.
- Replace every read of `state.agendaViewItems` and the `isUpNext` switch with a direct read of `state.activityFeedItems`.
- Replace `_buildList(...)` (the agenda branch) with `_buildActivityFeed(...)` everywhere the conditional appeared.
- Delete the tab-strip widget that renders the Agenda / Activity selector. Run `grep -n "Agenda\|Activity" apps/plot/lib/page/priority.dart` to find any tab labels.

- [ ] **Step 3: Update in-app links that targeted the Agenda tab**

Run: `grep -rn "PriorityTab.agenda\|setCurrentTab\|switchToAgenda" apps/plot/lib/`

For each match outside of `priority.dart`, replace the tab-switch with a navigation to `AgendaRoute`:

```dart
AutoRouter.of(context).push(const AgendaRoute());
```

Or, if those callsites are commands, replace with `OpenAgenda().run(context)` (added in Task 11).

- [ ] **Step 4: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/page/priority.dart`
Expected: `No issues found!`

- [ ] **Step 5: Manual smoke test (run the app via hot reload)**

Verify in-app:
- Launching the app lands on `/agenda`.
- The Agenda screen shows priority blocks across all priorities for today and a few upcoming days.
- Each block shows the new two-line layout with breadcrumb (dimmed ancestors), summary line, RSVPs, duration.
- Hovering a block reveals `−`/`+` around the duration; clicking adjusts in 15m increments and clears at 0.
- On a touch device (or with touch-emulated input), tapping the duration opens the modal.
- Clicking a block navigates to `/p/{base58}` and that page shows only the activity feed (no tabs).
- The priorities home shows an "Agenda" tile in sidebar layouts, hidden in bottom-nav layouts; the bottom nav (when present) still has Agenda.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "Remove Agenda/Activity tabs from PriorityPage"
```

---

## Task 13: Run /finalize

- [ ] **Step 1: Invoke the finalize skill**

Use the project's `/finalize` skill (per `apps/plot/AGENTS.md`) which runs `pnpm lint`, checks backwards compatibility, verifies error capture, updates docs, and handles the public submodule.

- [ ] **Step 2: Add a user-facing update note**

Append a bullet to the top section of `docs/updates.md`:

```
- The agenda is now a single, universal view that shows your day across every priority. Open it from the new Agenda destination at the top of your priorities list (or the bottom nav on mobile). Priority blocks are now the main item — hover any block on desktop to nudge its duration in 15-minute increments, or tap on touch.
```

- [ ] **Step 3: Commit doc updates**

```bash
git add docs/updates.md
git commit -m "Note agenda redesign in updates"
```

---

## Self-review notes

Spec coverage check:

- ✅ Universal agenda — Tasks 4, 9
- ✅ No expansion / no chevron — Tasks 3, 8
- ✅ `isOutside` removal from render path — Tasks 4, 8
- ✅ Click navigates to priority page — Task 8 step 5
- ✅ `/agenda` route + root redirect — Task 10
- ✅ Agenda tile replaces Everything (bottom-nav gated) — Task 11
- ✅ PriorityPage tabs removed — Task 12
- ✅ Two-line block layout with dimmed ancestors / leaf — Task 8
- ✅ Gutter unread dot below time — Task 8
- ✅ Joined-titles summary — Tasks 2, 8
- ✅ Pure gap rows on time line — preserved by existing gap rendering (no spec-mandated change beyond Task 3 cleaning up flat items; if a regression appears in gap rows during smoke test, file a follow-up — out of scope for this iteration's tasks since gap rows already render this way)
- ✅ Unread thread inclusion — Task 4
- ✅ Duration controls desktop — Task 7
- ✅ Duration controls touch / modal — Tasks 6, 7
- ✅ Active timing display contract — Task 8 step 4 (stub uses existing `widget.now` flag)
- ✅ Drag preserved — Task 8 leaves drag wiring intact
- ✅ `SetThreadDuration` command — Task 5
- ✅ `OpenAgenda` navigation command — Task 11
- ✅ `isTouchPlatform` helper — Task 1

No placeholders or TBDs remain. Type names used consistently across tasks (`SetThreadDuration`, `DurationControl`, `DurationModal`, `OpenAgenda`, `AgendaRoute`, `AgendaPage`, `AgendaList`).
