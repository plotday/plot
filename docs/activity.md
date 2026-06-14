# Activity Feed

## Overview

The activity feed is a reverse-chronological list of threads in the current priority and all its
descendants. It surfaces new and recent content, organized by unread status and recency. It is one
of two views in the priority panel, alongside the Agenda.

## Where It Appears

- **Desktop**: Two tabs ("Agenda" and "Activity") at the top of the priority panel, with an animated
  underline indicator. An unread dot appears on the "Activity" tab when there are unread threads in
  the current priority or its descendants. A notification bell button beside the tab opens attention
  settings.
- **Mobile**: Two bottom navigation items (agenda icon and activity icon). An unread dot appears on
  the activity nav item.

When search is active on desktop, the layout hides the agenda entirely and shows only the activity
feed at full height. On mobile, both views are individually filtered.

## What Appears in the Feed

A thread appears if it belongs to the current priority or any descendant priority. The feed does not
show cross-priority link-scheduled events (unlike the agenda — only threads directly in the priority
tree are included).

**Exclusions:**

- Draft threads are always excluded.
- Archived threads are excluded unless the user enables "Show archived" or the `#archived` tag
  filter is active.

## Sections and Grouping

### Unread Section

Unread threads appear at the top of the feed. There is no section header — unread threads simply
occupy the first positions. Threads currently being viewed by the user remain in this section until
the user navigates away (sticky behavior — see below).

### Time-Ago Sections

After the unread section, read threads are grouped under relative time headers:

- **Today** — threads with activity today
- **Yesterday** — 1 day ago
- **2 days ago** through **6 days ago**
- **A week ago** — 7–13 days
- **2 weeks ago** — 14–20 days
- **3 weeks ago** — 21–29 days
- **A month ago** — 30–59 days
- **2 months ago** through **11 months ago**
- **A year ago** — 365–729 days
- **2 years ago**, **3 years ago**, etc.

A new section header appears whenever the time bucket changes.

## Sort Order

### Unread Threads

Sorted by urgency (highest first), then importance (highest first), then activity time (most recent
first):

1. **Urgency rank**: interrupt > inform-requests > inform-updates > passive
2. **Importance**: 0–100 descending
3. **Activity time**: most recent first

### Read Threads

Sorted by activity time descending (most recent first) within each time-ago section.

### Activity Time

A thread's activity time is the most recent of: last note timestamp, link source timestamp,
bumped-at timestamp, or past schedule end time — falling back to created-at if none exist.

## Unread Status

A thread is unread when it has new content the user hasn't seen. Unread threads appear in the unread
section at the top of the feed.

### What Makes a Thread Unread

A thread becomes unread for a user when a new note is added by someone other than that user.
Specifically:

- Notes added by **any of the user's contacts** — whether from any of their apps, or from a
  connector syncing external content with the user as the author — never show as unread for that
  user.
- Notes added by other people (or their connectors) make the thread unread.
- The unread state is only set **after note analysis completes**. The app may display a thread as
  unread, but must not generate a local notification before analysis has classified the note's
  urgency and importance.

### Urgency and Importance

Each unread thread has an urgency level and importance score, determined by AI-powered note
analysis:

- **interrupt**: Urgent, needs immediate attention.
- **inform-requests**: Someone is waiting on this person (reply needed, question asked, task
  assigned).
- **inform-updates**: General update worth reviewing.
- **passive**: Minor update — show as unread in the app but do not push-notify.

Importance is a 0–100 numeric scale (0 = trivial, 50 = normal, 100 = critical).

### Reading a Thread

A thread is marked as read when the user views it. Specifically:

- The app marks a thread read after the user has had it open for 750ms.
- Reading a thread on one device **immediately marks it read on all other devices** for that user.
- The read state is based on what content the user has seen: if new content arrives after the user
  read the thread, it becomes unread again (after analysis).

### Sticky Unread Behavior

When a user opens an unread thread:

- The thread stays in the unread section even if a sync arrives and clears its unread flag. The
  unread indicator clears, but the position does not change.
- The sort values (urgency, importance, activity time) are frozen from when the thread was opened,
  so the thread's position doesn't jump while the user is reading.

When the user navigates away from the thread:

- The thread is removed from the unread section and placed in the read section.
- Its activity time is updated to now (bumped), so it appears at the top of the "Today" section.

### Unread Indicators

- The activity tab (desktop) or activity nav item (mobile) shows an unread dot when the current
  priority or any descendant has unread threads.
- Each priority in the sidebar shows its own unread dot (no descendant aggregation).
- The dot is 6px, colored with the priority's accent color at 70% opacity.
- On desktop, the dot has a tooltip describing the state ("Unread threads", "Active threads", or
  "Active and unread threads").

## Bumped Threads

When a user finishes a thread from the agenda, the thread is "bumped" — its activity time is set to
now, so it rises to the top of the "Today" section in the activity feed. Bumping also marks the
thread as read.

Finishing a thread from within the activity feed does **not** bump it. Only finishing from the
agenda triggers the bump.

## Thread Item Layout

### Leading Column

A button showing the thread's state icon:

| State                              | Default Icon         | Hover Icon       | Tap Action           |
| ---------------------------------- | -------------------- | ---------------- | -------------------- |
| Not a todo                         | Empty circle         | Todo icon        | Start (mark as todo) |
| Todo, not future-scheduled         | Check circle outline | Checkmark        | Finish               |
| Todo, future-scheduled             | Calendar icon        | Schedule icon    | Open schedule picker |
| Associated, no outstanding tasks   | Association icon     | X                | Remove association   |
| Associated, with outstanding tasks | Pending circle       | Checkmark circle | Finish and remove    |

Long-pressing the leading area opens the schedule picker.

### Above the Title

An optional metadata row showing:

- **Sub-priority label**: Shown when the thread's priority differs from the currently viewed
  priority.
- **Schedule date**: Shown in relative format when the thread has a link schedule.

### Title Row

- A 16x16 source icon (app logo or fallback). Tapping it cycles the thread's subtype.
- The thread title. Colored with the priority accent when the thread is selected; standard
  foreground otherwise.
- An inline preview excerpt (muted color) appended after the title when the thread has preview
  content that differs from the title.

### Trailing Buttons

**Tag badges** (always visible): Up to 5 existing tags on the thread, shown as count-badge buttons.
The `#todo` tag is excluded.

**Inline action buttons** (desktop, on hover): Appear to the right of the title with a gradient
fade. Includes:

- Thread commands (schedule, etc.)
- Up to 3 tag suggestions the thread doesn't already have
- A "more" button opening the full command palette

Maximum 6 buttons total (actions + more).

## Interactions

### Tap

- **Thread row**: Opens the thread in the detail panel.
- **Leading icon**: Runs the primary action per the state table above.
- **Thread type icon**: Cycles through available subtypes.

### Swipe (Mobile)

- **Short swipe right**: Start (mark as todo), if not already started.
- **Long swipe right**: Open schedule picker.
- **Short swipe left**: Mark as read, if unread.
- **Long swipe left**: Finish, if it is a todo.

Swipe actions animate the row off-screen, then collapse it. Swipe actions are hidden for threads
outside the current priority or in viewer-only priorities.

### Long-Press (Mobile) / Right-Click (Desktop)

Opens the command palette for that thread with all available commands (open, start/finish, schedule,
edit, move, merge, private toggle, archive).

### After Finishing a Thread

The row fades and collapses. The next thread in the feed is automatically opened.

## Keyboard Shortcuts (Desktop)

| Shortcut    | Action                                                       |
| ----------- | ------------------------------------------------------------ |
| Cmd+Shift+T | Focus the activity feed (toggle between agenda and activity) |
| Cmd+T       | Focus the agenda list                                        |
| /           | Toggle search bar                                            |
| D           | Toggle start/finish on current thread                        |
| Shift+D     | Open schedule picker for current thread                      |
| Backspace   | Archive current thread                                       |
| Up/Down     | Navigate through feed items (skips headers)                  |
| Enter       | Open command palette for focused item                        |
| Escape      | Clear list focus                                             |

## Filtering and Search

Search and filters are shared between the agenda and activity feed — they are not independent.

A search bar in the header filters both views with a 250ms debounce. Search operates on locally
synced data only (remote sync is not triggered during search).

Filter chips (via the funnel icon) include:

- **Subtype filters**: Notes, Idea, Goal, Decision, Discussion, Announcement, Ask — each with a
  count badge. Multiple can be active simultaneously (OR semantics).
- **Tag filters**: One per tag used in the current priority path, ordered by usage frequency, with
  count badges. Multiple tags are ANDed.

When any filter is active, the search bar remains open even with empty text. Closing the search bar
clears text and all filters.

## Empty State

When the feed has no items and loading is complete: "Threads track your specific goals and
activities, with tasks, notes, and linked documents in one place. Create a thread or add a
connection to add threads here."

## Pagination

The feed starts with 50 threads. When the user scrolls near the bottom, 50 more are loaded. Remote
sync is triggered as needed to fetch additional threads from the server. Pagination stops when all
available threads have been loaded.

During search, pagination works against local data only (no remote sync).

## Scroll Restoration

Scroll position is preserved per priority. Switching to a different priority resets scroll to the
top. Returning to the same priority restores the previous scroll position.

## Real-Time Updates

- Local changes (note added, thread edited, tags changed) trigger an immediate re-render.
- Changes are debounced by 100ms to coalesce rapid updates.
- Remote changes arrive via sync and appear immediately in the feed.
- When optimistic updates are in flight, stale intermediate states from the database are suppressed
  for 500ms to prevent flickering.
- New unread threads from sync appear at the top of the unread section without user action.

The activity feed does not refresh on a timer (unlike the agenda, which updates every minute). It
updates only when underlying data changes.

## Push Notifications

- **Platforms**: FCM on iOS/Android; WebSocket-triggered on macOS/Windows.
- **Passive threads excluded**: Threads with urgency "passive" never generate push notifications —
  they are only shown as unread in-app.
- **Quiet hours**: Notifications are suppressed during configured quiet hours; a retry fires when
  quiet hours end.
- **Content**: Title and preview per thread, grouped by first-level priority.
- **Tapping a notification**: Navigates directly to the Activity tab of the notified priority.
- **Retraction**: When a thread is read on another device, the corresponding notification is removed
  from the notification tray.
- **Cold start**: If the app is not running when a notification is tapped, the target priority is
  buffered and replayed once the app initializes.
