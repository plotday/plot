# Keyboard-navigable "Schedule focus block" as a FormModal

**Date:** 2026-05-28
**Status:** Approved — ready for implementation plan

## Problem

Two related goals:

1. **Mandate.** Modals must always be keyboard-navigable and should always use
   the tuned variants (`FormModal`, `CommandModal`, `ConfirmModal`,
   `SelectModal`), extending them when needed — never a bespoke `Modal` with
   hand-rolled focus. This rule must be documented so it is followed going
   forward.

2. **Fix the offender.** The "Schedule focus block" modal
   (`apps/plot/lib/widget/schedule_focus_modal.dart`) was built as a bespoke
   `StatefulWidget` shown through a bare `Modal`. It bypasses all of
   `FormModal`'s focus management: there is no consistent Tab/↑/↓ field order,
   no Enter-to-submit, no Esc-to-dismiss wiring, and the priority row uses a
   hand-rolled `FocusableActionDetector`. Convert it into a `FormModal`,
   creating the custom form components needed so the date / time / duration
   fields can be adjusted with the **Left/Right cursor keys**.

## Decisions (confirmed with user)

- **Editing model: keep typing + add stepping.** The date/time/duration fields
  retain their existing typeable text / picker inputs (`FTimeField`,
  `FDateField`, the duration h/m fields) *and* gain Left/Right cursor-key
  stepping. We do **not** replace them with pure steppers.
- **Large step: Shift+Left/Right.** Plain `←`/`→` = small step
  (1 day / 15 min); `Shift+←`/`Shift+→` = large jump (1 week / 1 hour). The
  existing double-chevron buttons remain for mouse users, giving keyboard
  parity.
- **Reuse, don't rebuild.** The existing `DurationInput`, `DateInput`,
  `TimeRangeInput` widgets (already typing + chevrons) are reused. A small
  `StepController` hook lets the cursor keys invoke the *same* chevron actions —
  no duplicated snap/step logic.
- **Enter enters the inner editor.** Enter on a scheduler row activates its
  inner editor (focus the time field / open the calendar) for keyboard typing.
  Form submission happens from the primary button (consistent with how
  `FormSelect` already captures Enter to open its picker).

## Scope

- **In scope:** documentation mandate; converting the focus-block modal to a
  `FormModal`; the new `FormScheduler` form item; the reusable `StepperRow`
  wrapper; the `StepController` hook on the three input widgets; rewiring the
  two call sites.
- **Out of scope (noted as follow-up):** `reschedule_event_modal.dart` is the
  obvious next candidate for the same treatment but is **not** changed here. It
  still uses `Scheduler`, so `Scheduler` and the three input widgets remain.

## Architecture

### 1. Documentation mandate

- **`apps/plot/AGENTS.md` → "Modals & dialogs"** code-style bullet: extend it to
  state that every modal must be fully keyboard-navigable, that the tuned
  variants (`FormModal`/`CommandModal`/`ConfirmModal`/`SelectModal`) are the
  default, and that new interactions are added by extending the form system
  (a new `FormItem` subclass) rather than dropping to a raw `Modal`.
- **Memory note** (`feedback_plot_modals.md` + `MEMORY.md` line 33): update to
  capture the keyboard-navigability + "prefer the tuned variants, extend rather
  than bypass" rule.

### 2. `FormScheduler` — new `FormItem` (composite, 3 focusable sub-slots)

Lives in a new file `apps/plot/lib/widget/form_scheduler.dart` (or alongside the
form framework). Mirrors the multi-sub-slot pattern already used by
`FormWindowList`:

- `focusableCount => 3` (date row, time-range row, duration row).
- Owns a `DateTimeRange _range` and coordinates date/start/end/duration
  interdependencies exactly like `Scheduler._recalculateRange` (changing
  duration recomputes end; changing end recomputes duration; respects an
  `allowPastTimes` flag — `true` in edit mode).
- `getValue()` returns the current `DateTimeRange`. `isValid()` is true when
  `end` is after `start` (the inputs already enforce a 15-min minimum).
- `build(context, highlightedSubIndex, focusNodes: …)` renders three rows; each
  row is wrapped in a `StepperRow` bound to `focusNodes[i]` and the row's
  `StepController`.
- `activate(context, subIndex)` focuses the inner editor for that row (date →
  open calendar; time → focus start-time field; duration → focus hours field).

The internal body is a small stateful widget that holds the coordination logic
and renders the existing `DurationInput` / `DateInput` / `TimeRangeInput`
widgets as controlled inputs (`value` + `onChanged`).

### 3. `StepperRow` — reusable cursor-key wrapper

A thin widget:

```
StepperRow(
  focusNode: <form-provided node>,
  highlighted: <bool>,
  onStepBack / onStepForward / onJumpBack / onJumpForward: VoidCallback?,
  child: <row content>,
)
```

- Wraps `child` in `Focus(focusNode, onKeyEvent)`.
- `←` → onStepBack, `→` → onStepForward, `Shift+←` → onJumpBack,
  `Shift+→` → onJumpForward; each returns `KeyEventResult.handled`.
- Everything else returns `KeyEventResult.ignored`, so ↑/↓/Tab/Enter/Esc
  propagate to `FormModal`.
- **Implicit edit-mode:** when the *row* node has focus, ←/→ step; when the user
  clicks into an inner editor, that editor has focus and consumes ←/→ for the
  text cursor (it returns `handled`, so the keys never reach `StepperRow`).
  No explicit toggle.

### 4. `StepController` — DRY stepping hook

Mirrors the existing `FormChannelListController` pattern (a controller the child
populates and the parent invokes):

```
class StepController {
  VoidCallback? stepBack, stepForward, jumpBack, jumpForward;
}
```

- `DurationInput`, `DateInput`, `TimeRangeInput` each gain an optional
  `StepController? stepController` param. In their `State` they assign their
  existing private chevron actions to it:
  - Duration: `stepBack=_decrement15Minutes`, `stepForward=_increment15Minutes`,
    `jumpBack=_decrementHour`, `jumpForward=_incrementHour`.
  - Date: `stepBack=()=>_navigateDate(-1)`, `stepForward=()=>_navigateDate(1)`,
    `jumpBack=()=>_navigateDate(-7)`, `jumpForward=()=>_navigateDate(7)`.
  - Time: `stepBack=_shiftLeft15`, `stepForward=_shiftRight15`,
    `jumpBack=_shiftLeft1Hour`, `jumpForward=_shiftRight1Hour`.
- `StepperRow`'s key handlers call through the controller. Chevron buttons and
  arrow keys share one code path. No behavior change for `Scheduler` /
  `reschedule_event_modal.dart` (they simply don't pass a controller).

### 5. The form definition + call sites

- Replace the `ScheduleFocusModal` `StatefulWidget` with a `FormData` builder,
  e.g. `scheduleFocusBlockForm({Date? date, Priority? defaultPriority,
  PriorityBlockRow? existingRow, Priority? existingPriority})` returning the
  groups:
  - `FormSelect<Priority>(key: 'priority', required: true, …)` — reuses the
    existing priority picker (`SelectModal`, inline create via
    `createPriorityInline`).
  - `FormScheduler(key: 'schedule', initialRange, allowPastTimes: isEdit)`.
  - `FormButton(key: 'submit', isPrimary: true)` building `ScheduleFocusBlock`
    from `values['priority']` + `values['schedule']` (start =
    `range.start`, duration = `range.end - range.start`, `existingRow`).
  - Edit mode only: `FormButton(key: 'delete', skipValidation: true)` building
    `ArchiveFocusBlock(row)`.
- **`apps/plot/lib/command/focus_block.dart`** — `OpenScheduleFocusModal.run`
  builds the create-mode form and runs `FormModal(form, groups, rootContext)`.
- **`apps/plot/lib/widget/agenda.dart`** — `_openFocusBlockEditor` builds the
  edit-mode (row present) or create-mode form and runs the same `FormModal`.

`FormButton` already handles validation, `CommandMessage` error toasts, and
pop-on-success, so the bespoke `_canSave` / `_onSave` / `_onDelete` / overlay
toast logic is removed.

## Data flow

```
User opens (agenda + button / agenda block edit)
  → OpenScheduleFocusModal / _openFocusBlockEditor builds FormData
  → FormModal renders: FormSelect(priority), FormScheduler(date/time/duration), buttons
  → ↑/↓/Tab move between items (FormModal); ←/→ + Shift step the focused scheduler row (StepperRow → StepController)
  → Enter on primary button → FormButton builds ScheduleFocusBlock(priorityId, start, duration, existingRow) → runs → pops
  → (edit) Enter on Delete → ArchiveFocusBlock(row) → runs → pops
```

## Testing

- **Widget tests** (`apps/plot/test/widget/`):
  - Tab / ↑ / ↓ cycle focus through Priority → date → time → duration → buttons.
  - `←` / `→` step the focused scheduler row by the small step; `Shift+←` /
    `Shift+→` by the large jump; assert the resulting range/duration.
  - Enter on the primary button runs `ScheduleFocusBlock`; priority-required
    validation disables the button until a priority is set.
  - Edit mode shows Delete and runs `ArchiveFocusBlock`.
- **`flutter analyze`** clean on all changed files.
- **Manual** via the `run-app` skill to confirm the stepping interaction feels
  right (keyboard + mouse chevrons + typing).

## Risks / notes

- **Esc while editing an inner field** closes the modal (FormModal `DismissIntent`).
  Acceptable: Tab leaves the editor back to row-level nav. We can later refine
  Esc-to-defocus if desired.
- **`FTimeField`/`FDateField` own ↑/↓ and ←/→ when focused.** This is the
  desired implicit edit-mode behavior — those keys edit the value while the
  inner editor has focus, and only step when the row has focus.
- Keep `Scheduler` and the three input widgets intact for
  `reschedule_event_modal.dart`; the `StepController` param is optional and
  unused there.
