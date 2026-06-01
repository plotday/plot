# Focus blocks on the agenda — design

Date: 2026-05-31
Status: Approved

## Problem

Today the running timer (a `Session` with `pomodoro`/`pomodoroAt`) and
agenda focus blocks (durable `priority_block` rows) are two separate
systems. The timer is visible only as a header pill; the agenda only
renders blocks the user explicitly scheduled. As a result:

- Starting a focus session leaves no trace on the agenda — the user
  can't see what they're working on or how much time is left in their
  own day view.
- "Start timer" is a vague label; users think in terms of *focus
  blocks*, not abstract timers.
- The default 15-minute pomodoro is shorter than typical focus
  intentions.
- Pausing makes the running block invisible until resumed.
- Scheduled blocks never auto-engage; the user must press Start even
  though their intent (and the calendar) already say "now is focus
  time."

## Goal

Make a focus block the single concept the user works with. Whether a
block is "running," "paused," or "scheduled" is derived state. The
agenda shows it; the header pill shows it; both views are kept in
sync.

## Non-goals

- Cross-day timers or sessions that span midnight.
- Reworking the `Session` table, time-tracking entries, or event
  schedules.
- Changing how scheduled events (`EventBlock`) are rendered.
- Changing the existing distraction-handoff path (`_startDistraction`)
  beyond what's needed to keep it consistent with the new model.

## Concept

A **focus block** is a `priority_block` row carrying an explicit
`effective_at` + `duration`. It is **running** for the user when:

> `now` is inside `[effective_at, effective_at + duration]` **and** the
> block's priority equals the user's current/selected focus
> (`NowLoaded.context`).

The header pill (Start / Pause / Stop) and the agenda are two
projections of the same block. The session row stays as the
time-tracking record (it remains the source of truth for elapsed time,
grace, distraction, and event tracking) but its existence becomes
derivable from "a focus block covers now for the current focus."

## Labels (UI)

| Where | Old | New |
|---|---|---|
| `StartTimer.title` | "Start timer" | "Start focus" |
| `StopTimer.title` | "Pause timer" | "Pause focus" |
| `EndTimer.title` | "Stop" | "Stop focus" |
| Root menu bar (`root_menu_bar.dart:208`) | "Start timer" / "Pause timer" | "Start focus" / "Pause focus" |
| Unified header tooltip (`unified_header.dart:1128`+) | "Start timer" | "Start focus" |

Class names (`StartTimer`, `StopTimer`, `EndTimer`) and the
widget-bridge protocol string (`widgetActionStartTimer = 'startTimer'`)
do **not** change — backwards compatibility for the macOS widget
extension and tracker analytics keys.

## Defaults

- `kDefaultPomodoro`: 15m → **30m**. Used in three places today:
  `startSession`'s fallback, the inactive-pill preview, and the
  `pendingFor` fallback. All three get 30m, with the existing
  next-event cap still applied.
- Add a new cap input: the next **focus block** on the agenda also
  caps the planned duration. Today `_capToEnd` reaches through
  `NowLoaded.endFor` which only consults `scheduled` (events) and
  `next`. Extend it to also clamp against the start of the next
  non-archived focus block whose `effective_at > now` for the current
  priority's day. (Cap is computed from `priorityBlocksByPriority`
  which `NowBloc` already subscribes to.)

## Agenda projection

`AgendaBuilder.build` already renders every non-archived, positive-
duration `priority_block` row whose window starts today or later. The
running case "just works" once the row exists. Two new cases:

### Running
Manual **Start focus** now writes a `priority_block` row at
`[now, now + planned)`. The agenda picks it up via the existing
`priorityBlocksByPriority` stream (which `PriorityBloc` already
watches and rebuilds the agenda on). No new render path. The block
shows `isCurrent: true` via the existing predicate.

If the user manually starts on a priority that **already has a focus
block covering `now`** (because they scheduled one earlier or it
auto-started), reuse the covering row instead of inserting a duplicate
— look up via the existing
`activeFocusBlockPriorityAt`/`priorityBlocksByPriority` indexing.

### Paused (sliding remaining)
Pausing today closes the session row but preserves remaining via
`pomodoroAt + pomodoro - end`. Two additional steps:

1. **Soft-archive the row** that was covering the session so the
   agenda no longer renders it at its scheduled slot. (Resume reads
   remaining from `Session.latestPausedFor`, not the row, so archiving
   doesn't lose state.)
2. Surface a **paused focus** descriptor from `NowBloc` —
   `{priority, remaining}` — derived from the latest paused-explicit
   session whose priority is still `context`.
3. `AgendaBuilder.build` accepts an optional
   `pausedFocus: ({Priority priority, Duration remaining})?` parameter
   and, when set, synthesizes a `PriorityBlock` at
   `[now, now + remaining)`, clamped to **not overlap** the next
   anchored item (event or future focus block) — shrink to fit, hide
   if zero. This synthesized block has `sourceRow: null` and a
   distinct id prefix (`fp_` for "focus paused").
4. On each `_onTrackTick` (1s), `NowBloc` re-emits its state so the
   downstream `PriorityBloc` rebuilds the agenda with `now` advanced —
   the paused block slides forward.

### Pause semantics

Today's pause leaves the row alone (rows are independent of sessions).
With the unified model the row is the agenda's only handle on
"running," so pausing must:

- Soft-archive the row (set `archived_at`) so the agenda no longer
  renders it at its scheduled slot.
- Continue to use `Session.latestPausedFor` as the resume source of
  truth (unchanged).
- Surface `pausedFocus` for the synthesized sliding block.

Resume (next **Start focus**) creates a fresh row at
`[now, now + remaining)`, identical to the existing resume-after-pause
session shift but with a row written too. The paused session row is
unchanged — `latestPausedFor` continues to work as the elapsed-time
lookup.

### Stopped
Stop (`EndTimer.endSession`) truncates the session as today, and
**soft-archives** the underlying focus block row. The agenda drops
it as past.

## Auto-start

`NowBloc` gains a single rule: **if `context` has a non-archived,
positive-duration focus block whose window covers `now`, and there is
no active session for `context`, start (or resume) one matched to
that block.**

Triggered from two paths:

1. **`setContext`** — when the user selects a focus that already has a
   covering block (most common case).
2. **`_onTrackTick`** — when a scheduled block's `effective_at`
   arrives while the user is already on that focus.

The start mirrors `startSession` but uses the row's `[effective_at,
effective_at + duration]` as the planned window. If a paused-explicit
session for the same priority exists with later `end`, resume from it
(existing `latestPausedFor` path). Cap as before so a scheduled block
running past the next event is shortened.

## Drag interactions

Existing dragging reschedules `priority_block` rows via
`PriorityBloc.moveFocusBlock` →
`PriorityBlock.setBlockDuration`/`effective_at` rewrite. Extend with
session-routing logic so that after the row write:

- **Drop covers `now`** *and* the priority is `context` → start (or
  resume) a session matched to the new window. No-op if already
  running for this priority on the same window.
- **Drop is wholly in the future** *and* a session was active for this
  block → close that session via `_closeActiveSession`. The row stays
  (as a normal scheduled block).
- **Drop is wholly in the past** → already handled by existing edit
  rules (allowed in edit mode).

The edit modal's "Update focus block" (the `ScheduleFocusBlock`
command's edit branch) follows the same rules — saving a window that
covers `now` for the current focus starts the timer; moving it to the
future stops it.

## State → render table

| State | Session | Row | Agenda render |
|---|---|---|---|
| Idle (nothing scheduled, no session) | none | none | nothing |
| Scheduled (future) | none until window arrives | real, future | scheduled block (existing) |
| Running (manual Start) | active, `[pomodoroAt, +pomodoro]` | real, covering now | `isCurrent` block (existing) |
| Running (scheduled auto-start) | active, matched to row | real, covering now | `isCurrent` block (existing) |
| Paused | closed `source='active'`, remaining preserved | archived | synthesized sliding `fp_…` block, capped to next item |
| Stopped | closed + truncated | archived | none |

## Code changes

### `apps/plot/lib/command/timer.dart`
- `StartTimer.title` "Start timer" → "Start focus".
- `StopTimer.title` "Pause timer" → "Pause focus".
- `EndTimer.title` "Stop" → "Stop focus".
- Class names and shortcuts unchanged.

### `apps/plot/lib/state/now_state.dart`
- `kDefaultPomodoro` 15m → 30m.

### `apps/plot/lib/state/now.dart`
- `startSession`: after computing `pomodoro`, ensure a
  `priority_block` row covers `[now, now + pomodoro)` for `ctx`.
  Reuse a covering row if one exists; otherwise insert via
  `PriorityBlock.setBlockDuration`. Done in the same op so the
  agenda's first re-render after Start already shows the running
  block.
- `stopSession` (pause): after `_closeActiveSession`, soft-archive the
  row that covered the session.
- `endSession` (stop): after the truncate write, soft-archive the row.
- Extend `_capToEnd` (or callers of `endFor` /
  `pomodoroEndCap`) to also clamp against the next non-archived
  focus-block start in `priorityBlocksByPriority`.
- Add an auto-start trigger in `setContext` and `_onTrackTick`:
  if no active context session and a covering row exists, call a new
  private `_startFromRow(row)` that mirrors `startSession` against the
  row's window.
- Expose a `pausedFocus` derivation on `NowLoaded` — `{priority,
  remaining}?` — driven off `Session.latestPausedFor(context.id)` and
  cleared by Resume/Stop. (Cache on `NowBloc` so the agenda doesn't
  re-query per tick.)

### `apps/plot/lib/state/agenda_builder.dart`
- New optional parameter
  `({Priority priority, Duration remaining})? pausedFocus`.
- When set, after `anchored` is built and gap interleaving runs for
  today, synthesize a `PriorityBlock` at `[now, now + remaining)`,
  shrunk to not exceed the next anchored start (event or focus
  block) — drop if room is zero.
- New id prefix `fp_<priorityId>` for the synthesized block.
- `sourceRow: null` so the block is read-only on the agenda; the
  header pill controls it. (Drag is gated on `sourceRow != null` in
  `agenda.dart:431` — existing predicate already excludes it.)

### `apps/plot/lib/state/priority.dart`
- Subscribe to `NowBloc.stream` to receive `pausedFocus` changes (and
  re-tick on `_onTrackTick`); store the latest snapshot and pass it
  into all `AgendaBuilder.build` call sites.
- Extend `moveFocusBlock` to dispatch the start/stop calls described
  in **Drag interactions**.

### `apps/plot/lib/command/focus_block.dart`
- `ScheduleFocusBlock.run` (edit branch): after the `setBlockDuration`
  write, route through `NowBloc.applyBlockBump` (or a new equivalent)
  to start/stop the session per the new-window rules.
- No label changes here — "Schedule focus block" is already correct.

### `apps/plot/lib/widget/root_menu_bar.dart`, `widget/unified_header.dart`
- Update hard-coded "Start timer" labels/tooltips to read from the
  command titles or update strings to "Start focus" / "Pause focus".

## Edge cases

- **Distraction** (`_startDistraction`): keeps its 5-minute default
  and `explicit: false` semantics. Does **not** write a focus-block
  row — distractions aren't user-scheduled. This means a distraction
  doesn't appear on the agenda. (Acceptable; mirrors today.)
- **Grace period**: session's grace tail is unchanged. The row's
  window already ended before grace begins, so the agenda already
  shows it as past during grace — no visual change.
- **Resume after a long pause that pushes past the next event**: cap
  the new row + session to the next event (same `_capToEnd`).
- **Two manual Starts in a row with paused remaining**: resume path
  (`Session.latestPausedFor`) wins; new row is `[now, now +
  remaining)`.
- **Scheduled block whose `effective_at` already passed but `+
  duration` still covers now**: auto-start uses the **remaining
  window** (`[now, effective_at + duration)`) so the user doesn't
  retroactively bill themselves for time they weren't focused.
- **Manual Start while context is on a *future* scheduled block**:
  the future block stays put; a new row at `[now, now + 30m]` is
  written for `context`. (Acceptable; treat as "I'm starting now, not
  later.")

## Testing

Unit tests:
- `AgendaBuilder` — paused sliding block synthesis, cap-to-next-item
  shrinking, hide-when-zero.
- `now.dart` — manual Start writes a row; Pause archives the row;
  Stop archives the row; auto-start fires from `setContext` and
  `_onTrackTick` when the covering row exists; `_capToEnd` clamps
  against next focus block.
- `PriorityBloc.moveFocusBlock` — drag-to-now starts, drag-to-future
  stops, drag in past is no-op.

Manual:
- Via `run-app` skill: start focus → confirm block appears on agenda;
  pause → confirm sliding block; let a minute pass → confirm slide;
  drag paused block forward → confirm it becomes a normal scheduled
  block and session ends; schedule a block 2m in the future on the
  current focus → wait → confirm auto-start; switch focus to a
  priority with a covering block → confirm auto-start.

## Risk

Medium. The change is small per call site but touches several layers
(commands, state, agenda builder, priority bloc, drag handlers). The
single biggest risk is double-writes (a manual Start while a covering
row already exists, or auto-start racing with a scheduled-row arrival)
— the design's "reuse covering row" guard plus the existing
optimistic emit in `startSession` mitigate this, but the implementation
needs careful idempotency on the `setBlockDuration` path.
