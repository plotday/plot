# Agenda: Thread Associations

## Overview

Threads can be associated with calendar events (link-scheduled threads) to create a shared sub-agenda. Associated threads appear below the event, move when the event is rescheduled, and are visible to all members of the priority.

## Creating Associations

- Drag a thread immediately below a link-scheduled event (before the gap header) to associate it with that event.
- The thread's personal schedule is removed — it appears only under the event.
- Associations are shared: all users on the priority see the same associated threads in the same order.
- Recurring events share the same set of associated threads across all instances.

## Removing Associations

- **Drag away**: Drag an associated thread into a gap or regular block to disassociate it. A personal schedule is restored and the thread appears as a normal todo.
- **Click the X**: For associated threads without outstanding tasks, click the leading icon (or hover to reveal the X) to remove the association.
- **Click the circle**: For associated threads with outstanding tasks, clicking the leading icon finishes the thread and removes the association.

## Moving Between Events

- Drag an associated thread from one link-scheduled event to another to move the association. The old association is removed and a new one is created.

## Display

- Associated threads appear directly below the event thread, before the gap header.
- **Icon**: Associated threads without outstanding tasks show a down-arrow icon. Associated threads with outstanding tasks show a circle icon (same as regular todos with tasks).
- **Hover**: Non-task associated threads show an X on hover. Task associated threads show a check on hover.
- Associated threads can be reordered within their group. The order is shared across all users.

## Dual Appearance

- A thread can be both associated and independently user-scheduled. In this case it appears twice: once under the event (as associated) and once in its normal agenda position (as a todo).
- Both copies are fully interactive.

## Link-Scheduled Events

- Link-scheduled events do not pull in same-priority todos automatically. Only explicitly associated threads and the event's own content appear under link events.
- Threads with their own link schedule (their own calendar event) are not pulled under other events by priority matching.
