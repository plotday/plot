# Agenda

## Overview

The agenda is a forward-looking, time-organized list of threads the user needs to pay attention to. It is scoped to a single priority and all its descendants. It shows todos, scheduled events, and their associated threads — never purely historical content.

## Where It Appears

The agenda is one of two views in the priority panel, alongside the Activity Feed.

- **Desktop**: Two tabs ("Agenda" and "Activity") at the top of the priority panel, with an animated underline indicator. An unread dot appears on the "Activity" tab when there are unread threads.
- **Mobile**: Two bottom navigation items (agenda icon and activity icon). An unread dot appears on the activity nav item.

When search is active on desktop, the layout collapses to show only the Activity Feed — the agenda is hidden. On mobile, both views are individually filtered.

## What Appears in the Agenda

A thread appears if any of these are true:

- It is a **todo** in the current priority or a descendant — the user has marked it as a personal to-do.
- It is a **scheduled event** in the current priority or a descendant — it has a date/time range (including events imported from external calendars via link schedules).
- It is an **all-day entry** in the current priority or a descendant — it has a date range without a specific time.
- It is an **associated thread** of a calendar event that is in the agenda (even if the child itself has no schedule or is from a different priority).
- It is a **link-scheduled event from another priority** — shown dimmed to provide full calendar context without detail.

Archived threads are excluded unless the user enables "Show archived" or the `#archived` tag filter is active. Draft threads are never shown.

## Priority Filtering

The agenda is filtered by the current priority. The rules are:

- **User-scheduled threads** (todos): Only threads in the current priority or a descendant are shown.
- **Link-scheduled events in the current priority**: Shown normally with all associated threads, even if the associated threads are from other priorities.
- **Link-scheduled events from other priorities**: Shown at their scheduled times but **dimmed**. Associated threads are not shown unless they individually belong to the current priority or a descendant. This allows the user to see their full schedule without details of other priorities.
- **Cross-priority events are hidden during search/filtering**: When search text, tag filters, or icon filters are active, only threads matching the current priority are shown.

## Chronological Structure

### Day Sections

The agenda is divided into day sections. Every day from today through the visible horizon has a date header, except for today — today has no date header; the list starts directly with the current event or the first todo/event. The date format is: day-of-week, day number (bold), and month. The year is appended when it differs from the current year.

### Within Each Day

Each day is a sequence of **blocks**, sorted by start time. There are three block kinds — gap, event, and priority — and threads always render inside one of them:

- **Gap block**: A time gap between scheduled events (e.g. 10:30 – 11:00). Carries a header that shows the gap's start time and duration. If todos are pinned into the gap, the gap block also picks up the lead priority's breadcrumb and accent color and contains those todos.
- **Event block**: A scheduled event together with any associated child threads. The header carries the event time, the event's priority breadcrumb, RSVP summary (when other attendees exist), and elapsed/remaining or countdown timing. The event row appears below the header; associated threads follow.
- **Priority block**: A second (or third, …) priority sharing the same gap. Carries just a priority breadcrumb header (no time) and renders below the gap block in the same time period.

A "period" is a gap region: a gap block plus any priority blocks following it within the same gap. All blocks in a period share the same time anchor — the gap's start.

Layout per day:

1. **Before the first event**: Threads not pinned to any event group into priority blocks under the date header.
2. **For each scheduled event**: A gap block (if free time since the previous event), then the event block. Todos pinned to the gap appear inside the gap/priority blocks for that period.
3. **After the last event**: A final gap block covers time from the last event's end to midnight (no duration shown for this trailing gap).

### Block Sort Order

Within a single period (a gap region), priorities are ordered by their **effective priority order** at the gap's start. The user's drag actions on block headers write a `priority_block` row at that gap's anchor, so a reorder applies to that gap forward in time without changing earlier gaps' orderings. Re-reordering the same gap replaces its previous entry rather than accumulating duplicates.

### Thread Sort Within a Block

- **Events**: One per event block; sorted by start time across blocks.
- **Todos**: Sorted by their original schedule date first (so overdue items keep their relative order), then by user-defined order (drag-and-drop).

### Block Collapse

Long priority and gap blocks stay scannable by collapsing past the first two threads. When a block has more than two threads and isn't the expanded one, the third row is replaced by a chevron-down "expand" affordance. Tapping the chevron expands the block; expanding another block automatically collapses the previous one. Event blocks with several associated threads collapse the same way (the event row plus one associated thread, then the chevron).

## "Now" Indicator and Time Awareness

The agenda updates every minute.

- **No event in progress**: The agenda starts directly with today's first block (no date header for today). The first future event block is marked as "next" and the countdown ("In 15m") appears on its block header.
- **Event in progress**: That event block becomes the list's starting point. Its block header displays elapsed time ("45m ↑") and remaining time ("15m ↓") in the priority's accent color.

## Block Headers

Block headers replace the older standalone "gap header" + per-row priority labels. Their content depends on block kind:

- **Gap block (no threads)**: A neutral time marker showing start time and duration on the day-section background. The trailing gap of the day omits its duration.
- **Gap block (with threads)** and **priority block**: A priority-tinted bar with the priority's breadcrumb. Gap blocks also show the gap's start time on the left.
- **Event block**: A priority-tinted bar with event time on the left, the event title and priority breadcrumb in the middle, and (right-aligned) the RSVP summary, elapsed/remaining for the in-progress event, "In 15m" countdown for the next event, and the event's duration.

Hovering a draggable block header (gap or priority block in the current priority) reveals a vertical-grip affordance. The whole header is the drag handle — see "Drag-and-Drop Reordering".

## Thread Item Layout

### Leading Column

Contains a state icon. The event time previously rendered in this column has moved to the surrounding event block's header.

Icon behavior by thread state:

| State                              | Default Icon          | Hover Icon       | Tap Action                    |
| ---------------------------------- | --------------------- | ---------------- | ----------------------------- |
| Not a todo                         | Empty circle          | Todo icon        | Start (mark as todo)          |
| Todo, not future-scheduled         | Filled circle         | Checkmark        | Finish                        |
| Todo, future-scheduled             | Calendar icon         | Schedule icon    | Reschedule picker             |
| Todo with outstanding tasks        | Hollow pending circle | Checkmark circle | Finish                        |
| Associated, no outstanding tasks   | Association icon      | X                | Remove association            |
| Associated, with outstanding tasks | Pending circle        | Checkmark circle | Finish and remove association |

Long-pressing the leading area opens the schedule picker.

### Body

The block header now carries the priority breadcrumb, time, RSVP, and elapsed/remaining metadata that earlier appeared above each row. Individual thread rows therefore render leaner:

- **Event row** (the event itself, inside an event block): A 16x16 source icon, the title text, and an inline preview excerpt. Time, RSVP, and timing are on the surrounding block header, not the row.
- **Todo row**: A 16x16 source icon, the title text, and an inline preview. Schedule date (relative format) and duration are shown when set; the priority breadcrumb is on the surrounding block header.
- **Associated child row**: Same as a todo row, but indented under its parent event with an association icon in the leading column.

Title color: priority accent color for the current event, standard foreground otherwise.

## Inline Action Buttons

On hover (desktop) or selection, an action bar appears on the right side of the title row with a gradient fade. The bar can include:

- Thread commands (schedule, archive, move-to-priority, etc.)
- Tag suggestion buttons for commonly used tags in this priority
- A "More" button opening the full command palette
- Existing tag buttons (up to 5) with count badges
- Conferencing button for events with video links (Google Meet, Zoom, Teams, Webex) — opens the meeting URL externally
- RSVP button for events with attendees; a secondary "skip series" button appears on hover when the user hasn't RSVPed

## Thread Associations

Threads can be associated with calendar events to create a shared sub-agenda. Associated threads appear below the event, move when the event is rescheduled, and are visible to all members of the priority.

- Drag a thread onto a link-scheduled event to associate it. The thread nests under the event and disappears from anywhere else in the agenda.
- The thread's personal schedule is removed — it appears only under the event.
- Associations are shared: all users on the priority see the same associated threads in the same order.
- Recurring events share the same set of associated threads across all instances.

### Removing Associations

- **Drag away**: Drag an associated thread into a gap or regular block to disassociate it. A personal schedule is restored and the thread appears as a normal todo.
- **Trailing "Remove from event" button**: Hover an event-associated thread on desktop to reveal the button at the trailing end; tap it to detach without finishing.
- **Click the X**: For associated threads without outstanding tasks, click the leading icon (or hover to reveal the X) to remove the association.
- **Click the circle**: For associated threads with outstanding tasks, clicking the leading icon finishes the thread and removes the association.

### Moving Between Events

- Drag an associated thread from one link-scheduled event to another to move the association. The old association is removed and a new one is created.

### Display

- Associated threads appear inside the event block, directly below the event row, before the next block.
- Associated threads can be reordered within their group. The order is shared across all users.
- Long associated lists collapse the same way priority blocks do: the event row plus one associated row remain visible, and the remainder hide behind a chevron until the block is expanded.

### Dual Appearance

A thread can be both associated and independently user-scheduled. In this case it appears twice: once under the event (as associated) and once in its normal agenda position (as a todo). Both copies are fully interactive.

### Link-Scheduled Events

Link-scheduled events do not pull in same-priority todos automatically. Only explicitly associated threads and the event's own content appear under link events. Threads with their own link schedule are not pulled under other events by priority matching.

## Recurring Events

Recurring events generate multiple occurrences within the visible range. Each occurrence is a distinct item. Cancelled/archived occurrences (exception dates) are excluded. Modified occurrences (different title, time, etc.) replace the generated occurrence.

Associated threads on recurring events are shared across all instances of the series.

## Drag-and-Drop Reordering

The agenda supports two distinct drag interactions: **thread-level** (move a single thread) and **block-level** (move or reorder a whole priority block).

### Thread Drag

Drag a single todo or associated child to reposition it. Calendar events themselves cannot be reordered.

- **Mobile**: A trailing drag handle appears on reorderable items.
- **Desktop**: Dragging the row itself initiates reorder.

Drop behavior:

- **Onto an event** (any event row or its associated area): Creates an association with that event. The thread's personal schedule is removed and it appears only under the event.
- **Inside a block** (between threads of the same block): Reorders within the block; the thread adopts that block's priority if different.
- **At the end of a block in the same period** (after the last thread, still under that priority block): Reorders within the block and adopts that block's priority.
- **At the end of a block in a different period or day**: Creates a new block in the destination period for the thread's *own* priority (not the destination's), or merges into an existing block of the same priority if one is already there. The thread is repinned to the destination gap.
- **In a gap with no existing block of the thread's priority**: A new priority block forms at that gap; the thread is pinned to the gap's start time.
- **In a different day section**: The thread's schedule date changes accordingly.

### Block Drag

Drag a gap block or priority block by its header (the priority-tinted bar). Event blocks are anchored to their event's time and cannot be dragged. Outside-priority blocks (link-scheduled events from other priorities, dimmed) are not draggable either.

- **Desktop**: Press-and-drag the block header.
- **Mobile**: Long-press (300 ms) on the header.

A grip affordance appears on hover. While dragging, the source block dims in place; once the pointer crosses into a valid drop zone, the source collapses and the destination zone opens up to show a dimmed preview of the block's content.

Drop behavior:

- **In the same period as the source**: Reorders priorities within that period. The agenda writes the new ordering to the gap's anchor, so it applies to that gap and any later gap with no further reorder. Re-reordering the same period replaces the previous entry rather than accumulating duplicates.
- **In a different period (same day or another day)**: Repins every thread in the block to the destination period's gap anchor. If the destination already has a block of the same priority, the threads merge into it; otherwise a new block forms.
- **Above a gap header**: Treated as "into that gap's period" — the gap header's slot belongs to the gap's own period, not the previous one. Dropping at the very top of a period and dropping at the bottom both land in that period.

#### Drop Zone Physics

The agenda uses a single **block-region drop area** model. Each non-source block X owns a drop area equal to X's vertical region in the live layout, and cursor in X activates the slot just **after** X — dropping the dragged block places it after the block under the cursor. The threshold for swapping to the next slot is at the **next block's top edge**, so the visual swap happens immediately as the cursor crosses into the next block, not halfway through.

A small set of carve-outs covers the edge cases:

1. **Tie-breaker — placeholders never move out from under the cursor.** When a slot is active, its expanded preview band is sticky — cursor inside it keeps the slot active regardless of what other rules would say. When no slot is active, the source's at-rest region is the placeholder — cursor inside source means "no swap" (preview stays at source). The tie-breaker takes precedence over every other rule.

2. **Source-flank no-swap.** A block whose K_after slot is filtered (the block immediately above the source) has no valid drop target. Cursor here holds whatever slot was last active, or "no swap" if nothing has activated yet. Per "the preview never bounces back to source," once a slot has been active, returning to a no-swap zone holds it instead of reverting.

3. **First-block-of-agenda split.** When the very first block of the agenda is not source AND its K_above slot is valid, the first block's top H pixels (where H is the dragged block's height) activate K_above_first; the remaining pixels fall through to K_after_first. This lets the user reach the top-of-agenda slot without dragging off-agenda above.

4. **Combined event deadzone.** When two or more events sit adjacent with no gap between them, the slot between them is filtered (nothing can drop there). The combined event chain uses a halfway flip — top half holds at the slot above the first event, bottom half snaps to the first valid slot below the chain.

Slots whose `prev` or `next` block id equals the dragged block's id are filtered out of activation entirely — those drops are no-ops and never offered as targets.

## Interactions

### Tap

- **Thread row**: Opens the thread in the detail panel.
- **Leading icon**: Runs the primary action per the icon table above. Long-press opens the schedule picker.
- **Source icon (in the title row)**: Opens an inline editor for the thread's title, icon, and priority. Long-press jumps to the move-to-priority command.
- **Date header**: Opens the schedule picker for the currently selected thread, pre-set to that day's first available slot.
- **Gap block header / priority block header**: Pressing a hover/touch on an expanded block's header collapses it (the next press starts a drag). On a collapsed block, the header is the drag handle.
- **Block expand chevron**: Expands a collapsed long block; expanding another auto-collapses the previous.
- **Event block header**: Opens the reschedule picker for that event when the event isn't in the past.

### Swipe (Mobile)

- **Short swipe right**: Start (mark as todo), if not already started.
- **Long swipe right**: Open schedule picker.
- **Short swipe left**: Mark as read, if unread.
- **Long swipe left**: Finish, if it is a todo.

Swipe actions animate the row off-screen, then collapse it.

### Long-Press (Mobile) / Right-Click (Desktop)

Opens the command palette for that thread.

### After Finishing a Thread

The row fades and collapses. The next thread in the agenda is automatically opened (or a new thread is created if none remain).

## Keyboard Shortcuts (Desktop)

| Shortcut    | Action                                        |
| ----------- | --------------------------------------------- |
| Cmd+T       | Focus the agenda list                         |
| Cmd+Shift+T | Focus the activity feed                       |
| /           | Toggle search bar                             |
| D           | Toggle start/finish on current thread         |
| Shift+D     | Open schedule picker for current thread       |
| Backspace   | Archive current thread                        |
| Up/Down     | Navigate through agenda items (skips headers) |
| Enter       | Open command palette for focused item         |
| Escape      | Clear list focus                              |

## Filtering and Search

A search bar in the header filters both the agenda and activity feed with a 250ms debounce. Search operates on locally synced data.

Filter chips (via the funnel icon) include:

- **Subtype filters**: Notes, Idea, Goal, Decision, Discussion, Announcement, Ask — each with a count badge. Multiple can be active simultaneously.
- **Tag filters**: One per tag used in the current priority path, ordered by usage frequency, with count badges.

When any filter is active, the search bar remains open even with empty text. Closing the search bar clears text and all filters.

## Outside-Priority Blocks

Link-scheduled events from priorities outside the current one render as dimmed event blocks at their scheduled times. Their associated child threads are not pulled in unless those children individually belong to the current priority. Outside blocks are not drag sources — they exist only to give the current priority's agenda full calendar context.

## Empty State

When the agenda has no items, a hint is shown inline: "Threads you [start icon] start or [schedule icon] schedule will appear here."

## Pagination

The agenda starts with a 90-day horizon. When the user scrolls to the bottom, the horizon extends by 90 days and 50 more items are loaded. This continues until no more items exist.

## Scroll Restoration

Scroll position is preserved per priority. Switching to a different priority resets scroll to the top. Returning to the same priority restores the previous scroll position.
