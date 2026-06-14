# Agenda

## Overview

The agenda is a universal, forward-looking, time-organized view of what the user needs to pay
attention to. It spans every priority the user has access to (rather than a single priority), and
presents the day as an ordered sequence of **blocks** — gaps, events, and priority blocks — never
individual thread rows. Each block stands in for the threads it contains; the activity feed
(per-priority) is where threads are managed individually.

## Where It Appears

The agenda is its own top-level tab, alongside Priorities and Activity:

- **`/agenda` route** — full-screen agenda. On mobile this is the agenda bottom-nav destination.
- **Multi-panel desktop** — the agenda also renders in the left panel (above the priorities list) as
  `LeftPanelAgendaView`, so it's always present alongside whatever priority the middle panel is
  showing. Navigating to `/agenda` in this layout bounces back to the current priority (the agenda
  is already visible).
- **Priority panel** — the priority panel itself no longer contains an agenda tab. The priority page
  renders only the activity feed (Today / Scheduled / New / Done sections — see `docs/activity.md`).

## What Appears in the Agenda

Because the agenda is universal, threads are surfaced across every priority the user has visibility
into. A thread appears if any of these are true:

- It is a **todo** (the user marked it as a personal to-do).
- It is a **scheduled event** with a date/time range — including events imported from external
  calendars via link schedules.
- It is an **all-day entry** with a date range but no specific time.
- It is an **associated thread** of a calendar event that is on the agenda. Associated threads do
  not render as their own row; they are summarized inside their parent event block's header.
- It is **unread**. Unread threads that the day grouping would otherwise drop (e.g. an unread thread
  last touched on a past date) are merged into today's section so the agenda never silently hides
  them. They land in an existing priority block on today if one exists; otherwise a new priority
  block is appended at the section's tail.

Archived and draft threads are excluded.

## Chronological Structure

### Day Sections

The agenda is divided into day sections. Every day from today through the visible horizon has a date
header, except for today — today has no header; the list starts directly with the current event or
the first block of the day. The date format is: day-of-week, day number (bold), and month. The year
is appended when it differs from the current year.

### Blocks

Each day is a sequence of three block kinds, sorted by start time:

- **Gap block** — a free time interval between scheduled events (e.g. 10:30 – 11:00). When no todos
  are pinned to the interval, the gap is a neutral time marker showing start time and duration. When
  todos are pinned to it, the gap also picks up the lead priority's breadcrumb and accent color and
  summarizes those threads in its header.
- **Event block** — a scheduled event together with any associated child threads. The header carries
  event time, priority breadcrumb, RSVP summary (when other attendees exist), and elapsed/remaining
  or countdown timing. The event title and any associated child titles render as a one-line summary
  on the header (no separate rows below).
- **Priority block** — a priority's pinned threads, rendered under a priority breadcrumb. When a
  priority shares a gap with another priority, that gap's first priority owns the gap header and
  additional priorities render as standalone priority blocks under the same gap.

Each block emits **exactly one row** (its header) in the rendered list. There are no per-thread rows
in the agenda. The block header's secondary line is a `·`-joined summary of the contained thread
titles.

A "period" is one gap region: the gap block plus any priority blocks immediately following it within
the same gap. Every block in a period shares the same time anchor — the gap's start.

### Layout Per Day

1. **Before the first event** — threads not pinned to any event group into priority blocks under the
   date header.
2. **For each scheduled event** — a gap block (if free time since the previous event), then the
   event block. Todos pinned to the gap appear inside the gap or its trailing priority blocks for
   that period.
3. **After the last event** — a final gap block covers the time from the last event's end to
   midnight. The trailing gap omits its duration.

### Block Sort Within a Period

Within a single period, priorities are ordered by their **effective priority order** at the gap's
start. A block drag writes a `priority_block` row at that gap's anchor, so the new ordering applies
to that gap (and to any later gap that hasn't been individually reordered). Re-reordering the same
gap replaces the gap's previous row rather than accumulating duplicates.

### Thread Sort Within a Block

Events: one per event block; sorted by event start time across blocks. Todos within a single
priority block: original schedule date first (so overdue items keep their relative order), then
user-defined order.

Per-block sorting is computed by `AgendaSort.compareThreadsInBlock` and feeds the block's `·`-joined
summary line.

## Pending Duration Per Block

Each agenda block can have its own **pending duration** — planned time the user wants to commit to
that block. Pending duration is per-block, not per-priority: editing time on one day's block affects
only that block.

- The +/− gutter on a priority block (or a priority-led gap block) writes a `priority_block` row at
  `effective_at = block.start` with the new duration. The next agenda rebuild reads it back and
  attaches it to the block via `cascadeDuration`.
- Blocks without a row in their window display no pending. Nothing cascades into a block from
  earlier days or earlier blocks; nothing carries over to later blocks.
- When the user runs the timer, the block containing `now` shows remaining time live; the static row
  duration is the source once the session ends.

The render is a pure post-process — the agenda builder folds each row's duration onto the matching
block via the per-block resolver and never writes back. Priorities with no row in their window are
unaffected by the fold and continue to appear only where they have threads.

## "Now" Indicator and Time Awareness

The agenda updates every minute.

- **No event in progress** — the agenda starts directly with today's first block (no date header for
  today). The first future block is marked as "next" and a countdown ("in 15m") appears on its
  header.
- **Event in progress** — that event block becomes the list's starting point. Its header displays
  elapsed time ("↑45m") and remaining time ("/ 15m") in the priority's accent color, replacing the
  static duration label.

## Block Headers

Block headers are the canonical agenda row. Content depends on block kind:

- **Empty gap block** — neutral time marker on the day-section background. Shows start time and
  duration; the trailing gap of the day omits its duration.
- **Gap block with threads** and **priority block** — priority-tinted bar with the priority's
  breadcrumb and a `·`-joined summary of contained threads. Gap blocks additionally show the gap's
  start time on the left.
- **Event block** — priority-tinted bar with event time on the left; event title (priority
  foreground) and any associated child titles (muted) in the middle; right-aligned trailing area for
  RSVP summary, elapsed/remaining for the in-progress event, "in 15m" countdown for the next event,
  and the event's duration.

The block's tint is the priority's accent color and is applied when the block belongs to the user's
current priority context; non-current blocks render on the plain background so the active priority
visually groups against everything else.

Hovering a draggable block header (gap or priority block) reveals a vertical-grip affordance and a
±15m duration bump button pair. The whole header is the drag handle — see "Drag-and-Drop
Reordering". Hovering an event header also reveals the bump buttons; they edit the event thread's
duration.

## Recurring Events

Recurring events generate one event block per occurrence within the visible range.
Cancelled/archived occurrences (exception dates) are excluded. Modified occurrences (different
title, time, etc.) replace the generated occurrence. Associated threads on a recurring event are
shared across all instances of the series.

## Drag-and-Drop Reordering

The agenda only supports **block-level** dragging — there are no per-thread rows, so there's no
per-thread drag. Block drag moves or reorders a whole block (and all of its threads at once).

### Block Drag Sources

A block header is a drag source when:

- It is a gap block (with or without threads) or a priority block.
- It is not an event block — events are anchored to their event's time and cannot be repositioned by
  drag.

Outside-priority blocks (e.g. link-scheduled events from other priorities, which historically
rendered dimmed) used to be filtered out as drag sources. In the universal agenda every priority's
blocks are equally first-class.

- **Desktop** — press-and-drag the block header.
- **Mobile** — long-press (300 ms) on the header.

A grip affordance appears on hover. While dragging, the source block dims in place; once the pointer
crosses into a valid drop zone, the source collapses and the destination zone opens up to show a
dimmed preview of the block's content.

### Drop Behavior

- **Same period as the source** — reorders priorities within that period. Writes a `priority_block`
  row at the gap's anchor; later gaps that haven't been individually reordered inherit the new
  order. Re-reordering the same period replaces the previous entry.
- **Different period (same day or another day)** — for thread-bearing blocks, repins every thread in
  the block to the destination period's gap anchor (via thread schedule rewrites); if the
  destination already has a block of the same priority, the threads merge into it. For empty
  cascade-only blocks (`threads` is empty), no thread schedules exist to rewrite, so the drop falls
  through to the reorder path with `effectiveAt` = the destination gap's anchor — the priority's
  cascade slice naturally lands in the new gap on the next rebuild.
- **Cross-period drop into a gap with no pending duration set** — when the target gap has no
  `priority_block` row at its anchor for the source priority, the drop also writes a default
  `priority_block` row at the gap's anchor with `duration = min(30m, available-gap-room)`. This
  applies regardless of whether the dragged block has threads; the next agenda rebuild reads the row
  and attaches it as the destination block's pending duration.
- **Above a gap header** — treated as "into that gap's period". The gap header's boundary slot
  belongs to the gap's own period, not the previous one.

### Drop Zone Physics

The agenda uses a single **block-region drop area** model. Each non-source block X owns a drop area
equal to X's vertical region in the live layout, and direction-aware activation picks the slot:

- **Drag down** (pointer below the current preview) — cursor in X activates K_after_X. The threshold
  for the next swap sits at the next block's top edge.
- **Drag up** (pointer above the current preview) — cursor in X activates K_above_X. The threshold
  sits at X's top edge.

The asymmetry mirrors how a drop reads visually (drop below the cursor when dragging down; above
when dragging up). Without it, drag-up would not advance source until the cursor overshot by a full
block height.

Carve-outs:

1. **Tie-breaker — placeholders never move out from under the cursor.** A slot's expanded preview
   band is sticky; cursor inside it keeps the slot active regardless of what other rules would say.
   When no slot is active, the source's at-rest region is the placeholder — cursor inside source
   means "no swap" (preview stays at source).
2. **Source-flank no-swap.** A block whose K_after slot is filtered (the block immediately above
   source) has no valid drop target. Cursor here holds whatever slot was last active, or "no swap"
   if nothing has activated yet — the preview never bounces back to source once a slot has been
   active.
3. **First-block-of-section split.** When the first block of a section is not source AND its K_above
   slot is valid, the first block's top H pixels (H = the dragged block's height) activate K_above;
   the remaining pixels fall through to K_after. This lets the user reach the top-of-section slot
   without dragging off-agenda above.
4. **Combined event deadzone.** When two or more events sit adjacent with no gap between them, the
   slots between them are filtered (nothing can drop there). The combined chain uses a halfway flip
   — top half holds at the slot above the first event of the chain; bottom half snaps to the first
   valid slot below the chain.

Slots whose `prev` or `next` block id equals the dragged block's id are filtered out of activation
entirely — those drops are no-ops and never offered as targets.

### Drag Animation

A single `BlockDragController` coordinates all slot height transitions via one shared
`AnimationController`. Each frame, every registered slot's height is
`lerp(snapshot, target, easeOut(progress))` against a unified `0→1` progress value — so the running
sum across slots stays at the source's height even when the active slot changes mid-animation. This
is what keeps the agenda's overall height conserved (no jiggle) during rapid block boundary
crossings.

When the user releases, slot heights snap to 0 immediately (not animated) so an in-flight close
animation doesn't race the next drag.

## Interactions

### Tap

- **Block header (gap or priority)** — tapping switches the user's current priority to the block's
  priority. A collapsed block's header can also act as the drag handle (see above).
- **Event block header** — opens the reschedule picker for that event when the event isn't in the
  past.
- **Date header** — opens the schedule picker for the currently selected thread, pre-set to that
  day's first available slot.

### Inline Duration Bump

On hover (desktop), a ±15m button pair appears on the right side of priority and gap blocks (and on
event headers). The buttons edit:

- **Event blocks** — the event thread's duration (via `SetThreadDuration`).
- **Priority and priority-led gap blocks** — the block's own pending duration. There is no
  priority-wide total to re-anchor; each block stands alone.
- **Empty gap blocks** — no editable duration; the bump UI is suppressed.

On touch, short right/left swipes on the same block headers map to +15m / −15m, giving mobile users
equivalent control without the hover pair.

### Long-Press (Mobile) / Right-Click (Desktop)

On a draggable block header, long-press initiates the block drag (mobile); on desktop it isn't bound
to a menu — block-level commands aren't exposed in the agenda. Per-thread commands live in the
activity feed.

## Pagination

The agenda starts with a 90-day horizon. When the user scrolls toward the bottom, the horizon
extends by 90 days and 50 more items are loaded. The fill horizon grows separately so sparse agendas
(many empty days) keep producing date headers as the user scrolls. This continues until the bloc
signals `agendaDoneEnd`.

## Empty Sections

A day with no scheduled content still gets a date header (above the visible horizon and within the
fill window). Today is the only day without a header. There is no inline empty-agenda hint in the
universal `/agenda` view itself — when the bloc hasn't loaded yet, a loading page is shown; once
loaded, even an empty horizon produces date headers and gap blocks.
