# Agenda Priority Block Redesign — Design

**Date:** 2026-05-09
**Status:** Approved (verbal)
**Scope:** `apps/plot` Flutter agenda. No server changes.
**Builds on:** [2026-04-30-agenda-priority-blocks-design.md](2026-04-30-agenda-priority-blocks-design.md)

## Goal

Make the agenda the universal, priority-agnostic home view. Priority blocks
become the only items in the agenda — individual threads never appear. Each
block carries enough information to scan, prioritize, and act on without
expanding (because nothing expands). Add inline duration controls and prepare
for active timing (elapsed up / remaining down).

The agenda becomes the new default route, replacing the per-priority
"Everything" entry on the priorities home as the single top-level destination
that aggregates the user's day across all priorities.

## User-visible changes

### The agenda becomes universal

- The agenda no longer scopes to a current priority. It renders blocks for
  every priority that has scheduled or unread threads in view, sorted by time
  (and by the existing block ordering rules within a time slot).
- The "expanded block shows its threads" behavior is removed. Blocks render
  in collapsed form only. There is no expansion, no chevron, no
  `contextPriorityId`-driven animation.
- The "outside priority" styling concept (`isOutside` on blocks/headers) no
  longer applies to the agenda — every block is in scope. Code paths and
  styling for `isOutside` are removed from the agenda render path.
- Clicking a block navigates to that block's priority page
  (`PriorityRoute(priorityId: ...)`), where the user sees the threads
  themselves. Clicking is the only built-in tap action; no in-place expand.

### Routing

- New route `/agenda` mounted in `apps/plot/lib/router.dart` (auto_route
  config) for an `AgendaPage`. Guarded by the existing `AuthGuard`.
- Root path (`/`, currently redirected to the user's default
  `PriorityRoute`) is changed to redirect to `/agenda`.
- Existing per-priority routes (`/p/{base58}`) and thread routes
  (`/t/{base58}`) are unchanged. The priority page continues to render its
  own threads view; only the root landing changes.
- `PriorityRoute` for the user's default priority is no longer special and
  no longer the root target.

### Priorities home — Agenda tile replaces Everything

`apps/plot/lib/widget/priorities_list.dart`:

- The "Everything" tile (currently `widget.root` with
  `ChangeCurrentPriority(widget.root)` as its command) is replaced by an
  "Agenda" tile.
- Tile content: title "Agenda", leading icon = a calendar icon
  (`FontAwesomeIcons.calendar` or a close equivalent — pick at
  implementation time, consistent with other tile icons).
- Tile command: navigate to `/agenda` (via `auto_route`'s
  `AutoRouter.of(context).push(const AgendaRoute())` or the appropriate
  command wrapper used elsewhere in the codebase).
- The Agenda tile does **not** display unread or active indicators. Pass
  `unread: false, active: false` to `PriorityNotification` (or skip the
  notification widget entirely — it's always blank for this tile).
- Order: Agenda tile sits at the top of the priorities list, in the slot
  the Everything tile occupied.
- **Hidden when the bottom nav is showing.** On layouts that expose Agenda
  through the bottom nav (mobile / narrow widths), the Agenda tile is
  omitted from the priorities list to avoid duplication. Use the existing
  layout signal (e.g. inverse of `context.isMultiPanel`, or whatever flag
  controls bottom-nav visibility — confirm at implementation time) to gate
  the tile.

### PriorityPage — tabs removed

`apps/plot/lib/page/priority.dart` (or wherever the priority page tabs are
defined):

- The Agenda / Activity tab strip is removed. `PriorityPage` becomes a
  single-pane view that renders the activity feed only.
- The Agenda tab content is gone — the agenda lives at `/agenda` now.
- The activity feed view is left as-is in this spec; another agent will
  redesign it to incorporate active threads.
- Routing: `/p/{base58}` continues to land on the activity feed. Any
  in-app links that previously targeted the Agenda tab on a priority should
  be redirected to `/agenda` (search for and update those callsites at
  implementation time).

### Collapsed block — new layout

Two-line block on a priority-tinted background (existing
`priority.displayColor` and `backgroundFromTheme`).

```
[gutter]    [event title]  [breadcrumb]                  [right meta]
            [thread summary, joined titles]
```

- **Gutter** (existing leading column, ~64px): time on top, **unread dot
  below the time** when the block contains any unread thread. The dot is the
  same blue used elsewhere for unread.
- **Title row** (`sm` / ~14px):
  - For event blocks: event title (weight 600) followed by the priority
    breadcrumb. Ancestors of the breadcrumb dimmed to ~55% opacity; leaf at
    full weight.
  - For unscheduled blocks (no event): the breadcrumb is the title — no
    separate event text.
- **Summary row** (`xs`, muted ~6b6b6b): joined `thread.displayTitle` over
  the block's threads, separated by ` · `, single line, ellipsized. Threads
  with no title are omitted (no synthesis from notes in this iteration).
- **Right meta**: existing `RsvpSummary` (when applicable) followed by `·`
  and the duration value.
- **No expand affordance.** No chevron. The whole row is clickable and
  navigates to the priority page.

### Pure gap rows (empty time, no priority, no threads)

Collapse to a single muted line: `11:30  23m free`. Duration moves onto the
time line since there's no other content. Gap rows are non-interactive.

### Unread thread inclusion

A priority block now collects:
1. Threads scheduled into this block's time window (existing behavior).
2. Any unread threads in the same priority that aren't otherwise scheduled
   today. They're mixed indistinguishably into the summary line. The unread
   dot in the gutter reflects either source.

Since the agenda is now universal, this no longer requires "unread threads
in unloaded priorities" — the agenda needs every priority's data anyway. The
builder iterates over all priorities and emits a block for each one with at
least one scheduled or unread thread for the day.

### Duration controls — desktop

Inline stepper, hover-revealed:

- Idle: `30m` text only in the right meta.
- On row hover: `−` and `+` glyphs fade in at the outer edges of the
  duration strip; the value stays centered. Glyphs themselves are unpadded;
  the entire duration strip becomes the hit zone, split at the value's
  vertical centerline (left half = `−`, right half = `+`).
- Each click adjusts by ±15m. Clicking `−` past 0 clears the duration.
- Zero-duration block: idle shows nothing in the duration slot; hover shows
  just `+` (clicking adds the first 15m).

### Duration controls — touch

Tapping the duration area opens a Plot `Modal` (subclass — never raw
`FDialog`):

- Large current-value display.
- 60×60 `−` and `+` buttons for ±15m.
- Preset chips: 15m, 30m, 1h, 2h.
- `Clear` action removes the duration entirely.
- Standard modal dismissal returns the new value via `Modal.pop<Duration?>`.

Touch detection uses an `isTouchPlatform`-style helper (confirm name during
implementation; add to `apps/plot/lib/util/platform.dart` if missing).
Pointer-events on hover-capable platforms keep the inline stepper.

### Active timing (priority being worked on)

When a timer is running on the block's priority, the right meta switches
from `30m` to:

```
↑12m / 48m
```

- `↑12m` in the priority's accent foreground color, counts up from session
  start, ticks every minute.
- `/ 48m` muted, counts down toward 0. Hides when there's no remaining
  duration.
- Hover still reveals the `−`/`+` stepper, which now mutates the *remaining*
  duration.
- Reuses the existing `_scheduleTick` minute timer in `_BlockHeader`.

The mechanism that records active time and exposes "is this priority active
right now" is **out of scope** for this spec. The display contract is: the
header reads an `activeTiming` value (nullable `({DateTime startedAt,
Duration? plannedTotal})`); when non-null it renders the timing format
above. Wiring in the actual active state is a follow-on.

## Data model changes

### `AgendaBlock` / `PriorityBlock` — `apps/plot/lib/state/agenda_model.dart`

- Add `String summaryLine` (computed): joined `displayTitle` of threads in
  the block with non-empty title, separated by ` · `.
- Add `bool hasUnread` (computed): true if any thread in the block has
  `unread = true`.
- `threads` continues to hold all block threads (used to compute
  `summaryLine` and `hasUnread`). Threads are no longer rendered as
  individual rows in the agenda view.
- Remove the per-block "expanded" / `hidden` flag plumbing in `flatItems()`
  — every block emits exactly one item (the block atom). `AgendaThreadItem`
  can be removed from the agenda render path entirely (kept only if used by
  other consumers; otherwise delete).

### `agenda_builder.dart`

- Build blocks for **every** priority that has scheduled or unread threads
  for the day, not just the current context priority.
- After grouping threads into priority blocks for a day, append same-priority
  unread threads (sorted by recency) so the summary line and unread dot
  reflect them.
- The `PriorityState.makeAgendaItems` callsite changes from "items for the
  current priority" to "items for the universal agenda" — verify both
  callsites and update.

### Server / sync

No schema change. No new RPC.

## Widget structure — `_BlockHeader` rewrite

`apps/plot/lib/widget/agenda.dart`:

- Replace the single-row `_buildRow` body with two rows inside the
  priority-tinted container.
- Gutter: existing `agendaLeadingWidth(context)` width. Stack `time` on top,
  `unreadDot` below (when `hasUnread`).
- Right meta: `RsvpSummary` (when applicable), then a `_DurationControl`
  widget that owns the hover stepper / touch modal trigger.
- Drag behavior (`BlockDragController`, `_isDraggable`, etc.) preserved.
  Drag source is the block row itself; no separate handle.
- Tap on the row (outside the duration control's hit zone) navigates to
  `PriorityRoute(priorityId: block.priority.id)`.
- Remove all `priorityContext` / `isOutsidePriority` / chevron rotation /
  expansion code paths.

### `AgendaPage` — new page

`apps/plot/lib/page/agenda.dart`:

- Hosts the universal agenda. Mounted at `/agenda`.
- Wraps the existing agenda widget with whatever app shell currently wraps
  `PriorityPage` (left rail, top bar, etc. — match existing layout).
- Holds the `AgendaBloc` (or whichever Bloc the agenda already uses) loaded
  in universal mode (no priority filter).

### `_DurationControl` — new widget

- Inputs: `Duration? value`, `ValueChanged<Duration?> onChanged`, `Color
  foreground`.
- Desktop: `MouseRegion` controls `_hover`. Renders `−`, value, `+` as a
  `Row` with two `GestureDetector` halves spanning the strip. On
  zero-duration value, hides `−` and value, leaves only `+` in the right
  half.
- Touch: tapping the strip pushes a `DurationModal` and on return calls
  `onChanged` with the result.
- Active timing display is rendered by the parent widget, not by
  `_DurationControl` — the control's stepper remains accessible by hover
  even when active timing is showing.

### `DurationModal` — new modal

`apps/plot/lib/widget/duration_modal.dart`. Subclass of `Modal`. Returns
`Value<Duration?>` (where `null` = clear). Uses `forui` widgets only.

## Commands

- Duration mutation: new command in `apps/plot/lib/action/` (likely
  `SetThreadDuration`) that mutates `thread.at` (`DateTimeRange.duration`).
  A zero/cleared duration on a scheduled thread becomes an `at.start`-only
  event with no end (existing model supports this).
- Replace the priorities-home command emitted by the Everything tile
  (`ChangeCurrentPriority(root)`) with an `OpenAgenda` (or equivalent
  router-push) command.

## Behavior contracts

- Hover stepper does not appear during a block drag (`_isBeingDragged` is
  true).
- Setting duration on an unscheduled block (no `at.start`) anchors it to the
  block's gap-start time. If there is no gap-start (top-of-day blocks),
  setting a duration is a no-op until a time is set — i.e. the `+` control
  is disabled.
- Active timing display takes priority over the static duration in the
  right meta. Hover still reveals the stepper underneath.
- Unread dot is purely informational; clicking it does nothing distinct
  from clicking the rest of the row (which navigates to the priority).
- Block row click → `PriorityRoute`. Duration control hit zone consumes the
  tap before the row's tap handler.

## Out of scope

- LLM-based summarization of the thread list (future).
- The mechanism that records elapsed time / determines active priority
  (separate spec).
- Activity feed (only the agenda is affected).
- Per-priority page rendering (unchanged — that's where threads still
  appear).
- Removing the legacy expansion data model fields server-side (none exist
  to remove).

## Files affected

- `apps/plot/lib/widget/agenda.dart` — `_BlockHeader` rewrite, expansion
  code removal.
- `apps/plot/lib/page/agenda.dart` — new page.
- `apps/plot/lib/router.dart` — add `/agenda` route, change root redirect.
- `apps/plot/lib/widget/priorities_list.dart` — replace Everything tile
  with Agenda tile (hidden when bottom nav is showing).
- `apps/plot/lib/page/priority.dart` (and any tab-strip widget it uses) —
  remove Agenda/Activity tabs; render activity feed only.
- `apps/plot/lib/widget/duration_modal.dart` — new.
- `apps/plot/lib/state/agenda_model.dart` — add `summaryLine`,
  `hasUnread`; remove per-block expansion flags.
- `apps/plot/lib/state/agenda_builder.dart` — universal mode (every
  priority); union same-priority unread threads into blocks.
- `apps/plot/lib/action/` — new duration-mutation command and Agenda
  navigation command.
- `apps/plot/lib/util/platform.dart` — confirm/add `isTouchPlatform`-style
  helper.
