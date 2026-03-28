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

- It is a **todo** — the user has marked it as a personal to-do.
- It is a **scheduled event** — it has a date/time range (including events imported from external calendars via link schedules).
- It is an **all-day entry** — it has a date range without a specific time.
- It is an **associated thread** of a calendar event that is in the agenda (even if the child itself has no schedule).

Archived threads are excluded unless the user enables "Show archived" or the `#archived` tag filter is active. Draft threads are never shown.

## Chronological Structure

### Day Sections

The agenda is divided into day sections. Every day from today through the visible horizon has a date header, even if that day has no threads. The date format is: day-of-week, day number (bold), and month. The year is appended when it differs from the current year.

### Within Each Day

Threads are organized around the day's scheduled events, sorted by start time:

1. **Before the first event**: Unscheduled threads appear under the date header, grouped by sub-priority.
2. **For each scheduled event**:
   - A gap header showing free time since the previous event's end.
   - The event thread itself.
   - Associated child threads appear immediately below the event.
   - Todos from the same priority (or descendants) whose schedule falls within the event's time range.
3. **After the last event**: A final gap header covers time from the last event's end to midnight.

Todos without a specific event appear at the start of the day (before the first scheduled event) or after the current event (for today).

### Sort Order

- **Events**: Sorted by start time.
- **Todos**: Sorted by schedule date first (earlier dates before later), then by user-defined order (supporting drag-and-drop reordering).

## "Now" Indicator and Time Awareness

The agenda updates every minute.

- **No event in progress**: The agenda starts at today's date header. The first future timed event is marked as "next" and shows a countdown (e.g. "In 15m").
- **Event in progress**: That event becomes the list's starting point. It displays elapsed time (e.g. "45m up-arrow") and remaining time (e.g. "15m down-arrow") using the priority's accent color.

## Gap Headers

Between each pair of scheduled events, a gap header shows the start time and duration of free time. The last gap of the day (ending at midnight) does not show a duration. Gap headers serve as visual separators and tap targets for scheduling.

## Thread Item Layout

### Leading Column

Contains a state icon and, for timed events, the event time (e.g. "2:30p" on mobile, "2:30 pm" on desktop).

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

For **timed events**: A label row above the title shows sub-priority label (if from a descendant priority), elapsed/remaining/countdown time, event duration, and RSVP summary (if other attendees exist). The title row shows a 16x16 source icon, the title text, and an inline preview excerpt.

For **todos**: A label row shows sub-priority label, schedule date (relative format), and duration if set.

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

### Creating Associations

- Drag a thread immediately below a link-scheduled event (before the gap header) to associate it.
- The thread's personal schedule is removed — it appears only under the event.
- Associations are shared: all users on the priority see the same associated threads in the same order.
- Recurring events share the same set of associated threads across all instances.

### Removing Associations

- **Drag away**: Drag an associated thread into a gap or regular block to disassociate it. A personal schedule is restored and the thread appears as a normal todo.
- **Click the X**: For associated threads without outstanding tasks, click the leading icon (or hover to reveal the X) to remove the association.
- **Click the circle**: For associated threads with outstanding tasks, clicking the leading icon finishes the thread and removes the association.

### Moving Between Events

- Drag an associated thread from one link-scheduled event to another to move the association. The old association is removed and a new one is created.

### Display

- Associated threads appear directly below the event thread, before the gap header.
- Associated threads can be reordered within their group. The order is shared across all users.

### Dual Appearance

A thread can be both associated and independently user-scheduled. In this case it appears twice: once under the event (as associated) and once in its normal agenda position (as a todo). Both copies are fully interactive.

### Link-Scheduled Events

Link-scheduled events do not pull in same-priority todos automatically. Only explicitly associated threads and the event's own content appear under link events. Threads with their own link schedule are not pulled under other events by priority matching.

## Recurring Events

Recurring events generate multiple occurrences within the visible range. Each occurrence is a distinct item. Cancelled/archived occurrences (exception dates) are excluded. Modified occurrences (different title, time, etc.) replace the generated occurrence.

Associated threads on recurring events are shared across all instances of the series.

## Drag-and-Drop Reordering

Todos can be reordered by drag. Calendar events cannot be reordered.

- **Mobile**: A trailing drag handle appears on reorderable items.
- **Desktop**: Dragging the row itself initiates reorder.

Drop behavior:

- **After a link-scheduled event** (before the gap header): Creates an association with that event.
- **In a gap**: Pins the todo to that gap's start time.
- **After a non-link event** (past the event, no gap header): Pins the todo to that event's start time.
- **In a different day section**: Changes the todo's date accordingly.
- **Otherwise**: Only the sort order changes.

## Interactions

### Tap

- **Thread row**: Opens the thread in the detail panel.
- **Leading icon**: Runs the primary action per the icon table above.
- **Date header**: Opens the schedule picker for the currently selected thread, pre-set to that day's first available slot.
- **Gap header**: Opens the reschedule picker for the associated event.

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

## Empty State

When the agenda has no items, a hint is shown inline: "Threads you [start icon] start or [schedule icon] schedule will appear here."

## Pagination

The agenda starts with a 90-day horizon. When the user scrolls to the bottom, the horizon extends by 90 days and 50 more items are loaded. This continues until no more items exist.

## Scroll Restoration

Scroll position is preserved per priority. Switching to a different priority resets scroll to the top. Returning to the same priority restores the previous scroll position.
