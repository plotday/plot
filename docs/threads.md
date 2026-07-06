# Thread Feed

How threads are surfaced, ordered, and acted on inside a focus. The feed is the middle panel of the
app — the primary working surface — where the threads filed to a focus are grouped into **Active**,
**Scheduled**, and **Done**.

This document supersedes the old `activity.md`, which described a removed two-tab "Agenda / Activity"
panel and an "unread at the top" ordering. For adjacent surfaces see [`agenda.md`](./agenda.md) (the
day view), [`priorities.md`](./priorities.md) (the focus / Inbox / Everything model), and
[`notifications.md`](./notifications.md) (when and how threads notify you).

Terminology: the product term is **focus** (not "priority") and **thread** (not "activity"). Several
code identifiers still use the older names (`priority`, `ActivityTab`, `activity_section`); they are
vestigial.

## Where it appears

The focus panel renders **one unified feed** — there are no "Agenda" / "Activity" tabs. `ActivityTab`
is a transitional single-value shim (`unified`), and its legacy constants (`catchUp`, `respond`,
`doIt`, `read`, `all`) all collapse to the same value; the feed never filters at the tab level
(`state/activity_section.dart:22-47`). The only animated underline in the header sits under the
**search field**, not a tab.

The multi-panel layout is: sidebar (focus list) → **focus feed** (`PriorityPage`, middle panel) →
thread detail (`ThreadPage`, right panel). Single-panel stacks these. The **agenda** is a separate
global view (its own bottom-nav tab / route, and a left-panel view in multi-panel) — it is not part
of the focus panel. See [`agenda.md`](./agenda.md).

The feed is scoped to one of:

- a **focus** — threads filed to that focus,
- the **Inbox** — an ordinary role focus holding threads not sorted into any focus, or
- **Everything** — the unscoped cross-focus view of all threads.

See [`priorities.md`](./priorities.md) for the focus model.

### What's excluded

- **Drafts** — only your own drafts appear (enforced by the server `user.thread` view).
- **Archived threads** — hidden unless "Show archived" is on.
- **Muted threads** appear in **Done** (not the Archive) and can be filtered to muted-only — see
  [Muting](#muting).

## Sections

The feed is assembled as ordered sections within one scrollable list
(`state/priority.dart` `_buildUnifiedFeedItems`), in this order:

**Event Agenda → Active → Scheduled (per day) → Done.**

Section headers are rendered as plain text from `ActivitySectionMarker.defaultLabel`
(`state/activity_section.dart:119-130`).

### Event Agenda

A pinned event thread plus its associated threads. It appears **only** when an event owned by the
current focus is selected (never in Everything). Header: "Event Agenda".

### Active

The "doing" section, headed **"Active"**. Two clusters, in this order:

1. **Your to-dos, at the top**, in the order you chose (`order` ascending). Read and unread to-dos
   are intermixed here — membership is by active state, not the unread flag.
2. **New, unread threads, gathered at the bottom** (the "unread cluster"), sorted by **urgent**
   (first), then **importance** (highest first), then `order`
   (`state/activity_feed_layout.dart:13-36`).

So incoming messages never push your committed work down — a new arrival lands below the to-dos, not
above them. The Active header carries a **"Mark all read"** button (when the section has unread rows)
and a **"Do all later"** button.

A thread is Active when `active == true` and it is not scheduled for a future day
(`store/thread.dart` `isActiveThread`).

### Scheduled

Active threads scheduled for a **future** day (`isScheduledThread = active && isFuture`). Grouped
into per-day sub-sections in date order, each headed by a relative date label — **"Today"**,
**"Tomorrow"**, the weekday name for the next few days (e.g. "Monday"), then an abbreviated date
(e.g. "Jul 6"), with a year suffix when outside the current year (`activity_section.dart:154-188`).
Within a day, threads sort by `order`. (The full "July 6 Monday" format belongs to the agenda pane,
not this feed.)

### Done

The tail of history: read threads with no active state, headed **"Done"**, sorted by **activity
time**, most recent first. Only the very top of Done is a valid drop target; dropping a thread there
marks it done and bumps it to the top.

### Flat mode

In **Everything**, during **search**, or whenever **any filter** is active, the feed drops the
sections and renders one unsectioned list ordered purely by activity time (most recent first) — no
Active/Scheduled/Done split and no unread cluster.

## Sorting signals

Every thread carries per-user state on `thread_state`:

- **`active`** (bool) — belongs in the Active section (your to-do).
- **`urgent`** (bool) — should break through before your next response window.
- **`importance`** (0–100) — chosen in bands: suppress 15, low 45, normal 60, elevated 85 (default
  50) (`workers/api/src/state/importance/band.ts`).

A thread surfaces (shows unread / can notify) when **`importance >= 50` OR `urgent`**. This replaced
an older `urgency` enum (`interrupt` / `inform-requests` / `inform-updates` / `passive`), which no
longer exists. See [`notifications.md`](./notifications.md) for how `urgent` / `importance` drive
notification timing.

**Activity time** is the most recent of: last note timestamp, link source timestamp, bumped-at
timestamp, or a past schedule's end time — falling back to created-at.

## Unread and reading

- **What makes a thread unread:** a new note added by someone **other than you** (your own contacts
  are treated as you). The flag is set server-side; the client shows a thread as unread when
  `unread == true` and `read_at` is null. Classification sets `urgent` / `importance`, but the unread
  flag is guaranteed even when AI is off.
- **Reading:** opening a thread marks it read on the **next macrotask** (effectively on open) — a
  sub-frame open-and-close does not mark it read (`page/thread.dart`). (The old "750ms" figure is
  stale.)
- **Cross-device:** reading on one device clears the thread everywhere. The client pushes `read_at`
  (`/sync/thread-read` for plain threads, `/sync/thread-state` for to-dos); the server fans out so
  your other devices re-pull. The clear is race-safe against content that arrived after you read.
- **Re-unread:** new content after you've read re-unreads the thread — unless you'd already read past
  that note. Muted threads never re-surface.

### Sticky while reading

When you open a thread from the bottom **unread cluster**, its unread dot clears immediately but its
row stays pinned in place, so it doesn't jump while you read. When you navigate away, it drains to
its natural section — **Done** (once read) or its **Scheduled** day.

## Muting

Muting a thread ("skip active for threads like this") moves it straight to **Done** — it isn't
archived, and it stays in its focus, so you can still find it in Done or by search. Plot learns from
the mute: future similar threads arrive directly in Done instead of showing up unread in Active. Use
the **muted-only** filter to review what's been muted.

## Indicators

- **Sidebar, per focus:** an **unread dot** — a 6px circle in the focus's accent color at 70% opacity
  — appears trailing the focus name when the focus has unread threads (tooltip "Unread threads",
  shown only with a physical keyboard). A focus with **active** threads renders its title **bold**;
  there is no separate active dot.
- **Header unread-only toggle** (envelope, multi-panel): tri-state — disabled with "No unread
  threads" when there are none; "Show only unread threads" when off; highlighted "Show all threads"
  when on. It filters the feed to unread threads (plus the thread you currently have open, so it
  doesn't vanish mid-read) and auto-clears when no unread remain.

## The thread row

### Leading status button

Branches on the thread's to-do state:

| State | Resting glyph | On hover | Tap |
| --- | --- | --- | --- |
| Not a to-do | empty (dot if unread) | `+` "To do" | Make it a to-do (active + read) → moves to Active |
| Active to-do | filled circle in focus color | check "Done" | Finish it |
| Just finished (~1.5s) | check flash | — | Re-open as a to-do |
| Multi-select mode | checkbox | — | Toggle selection |

An **unread** thread shows an accent dot on the glyph. **Long-press** the leading area to schedule
("Do later"). There is no distinct leading state for scheduled or event-associated threads — the
schedule shows in the metadata row, and event association is a trailing "Remove from event" button.

### Metadata row (above the title)

Left to right: a **focus label** (only when the thread is filed in a different focus, or always in
Everything/search), a **channel breadcrumb** (e.g. "Acme Co › #general"), **participant names**, and
a **schedule date** (for events and scheduled to-dos). The most-recent-note relative time is
right-aligned.

### Title row

- A **source logo** (Plot mark, or the connector/twist/URL logo). It's non-interactive; on row hover
  it's replaced by a "move to focus" affordance.
- The **title**, colored in the focus color when it's the current focus and foreground when selected.
- An inline **preview excerpt** (muted) appended when it differs from the title.

### Trailing content

Persistent (when applicable): a mute icon, conferencing **Join** buttons, a **status icon** (tap to
change a connected thread's status), an **RSVP chip** (events with other attendees), and an
**assignee avatar**. Tags and reactions are **not** shown on the feed row.

On desktop hover, up to five frequent commands slide in — led by **Schedule**, plus **Mute**,
**Assign**, **Remove from event** where relevant, and always a **More** button that opens the
thread's command palette.

## Interactions

- **Tap** a row to open it in the detail panel; tap the **leading** button for its primary action.
- **Swipe (mobile)** — right acts on the thread, left files it:
  - **Right, short** → **Done** (finish; from the Done list it re-engages instead).
  - **Right, long** → **Do later** (schedule).
  - **Left, short** → **Move** (to another focus).
  - **Left, long** → the thread **command menu**.
  - Swipes are hidden for threads outside the current focus.
- **Long-press (mobile)** on the row body starts a **reorder drag**; long-press the leading area to
  schedule. **Right-click (desktop)** opens a context menu of thread commands. The full fuzzy command
  palette is ⌘K.
- **Drag between sections:** into **Active** makes it a to-do; into a **Scheduled** day schedules it;
  onto the top of **Done** marks it done (and bumps it to the top). An active to-do can't be dropped
  into the unread cluster. Reorder by hand within Active or within a day.
- **After finishing** a thread the row collapses (with haptic feedback). If you finished the thread
  you had open, the next thread opens automatically (or the compose page when the feed is empty);
  finishing a row you don't have open just animates it out.

## Keyboard shortcuts (desktop)

⌘ on macOS, Ctrl elsewhere.

| Shortcut | Scope | Action |
| --- | --- | --- |
| ⌘⇧A | feed | Focus the feed list |
| ⌘/ | feed | Toggle search |
| ⌘D | feed | To do / Done on the focused thread |
| ⌘⇧D | feed | Schedule ("Do later") |
| ↑ / ↓ | feed | Move through the feed, skipping headers |
| Esc | feed | Move focus to the thread editor |
| ⌘N | app | New thread |
| ⌘↑ / ⌘↓ | app | Open previous / next thread |
| ⌘↵ | open thread | Done (finish) |
| ⌘. | open thread | Move |
| ⌘⇧S | open thread | Share |
| ⌘T | open thread | Mark the focused note a to-do |
| ⌘K | global | Command palette |
| ⌘J | global | Switch focuses |
| ⌘[ | global | Back |

The old ⌘⇧T "toggle agenda/activity" and ⌘T "agenda" bindings are gone (the panel is feed-only).
There is no dedicated shortcut for archiving a thread or for the Everything view.

## Search and filters

- **Search** debounces at 500ms and runs in **Everything** mode. It queries local data **and** the
  server, surfacing not-yet-synced matches as "extras" plus a count of archived matches; it exposes
  offline / in-progress state.
- **Filters** (any active filter switches the feed to a flat list):
  - **Unread-only** toggle (the envelope, above).
  - **Muted-only** toggle.
  - **Icon / type** filter — this is where **subtypes** live: action, notes, idea, goal, decision,
    discussion, announcement, ask — plus connector link types and twists.
  - **Tag**, **reaction**, and **assignee** filters.

## Pagination, scroll, and updates

- **Pagination:** 50 threads to start, plus 50 each time you scroll near the bottom — served from
  local queries. A single remote pull runs once per focus load (deferred to the first feed emission
  or a ~1.5s fallback), **not** on scroll.
- **Scroll position** is preserved per focus (restored when you return) and reset when you switch
  focuses.
- **Real-time:** the feed rebuilds whenever the underlying data changes (a local edit, or a sync) —
  there is no refresh timer.

## Empty state

When the feed is empty and loading is complete:

> Threads track your specific goals and activities, with tasks, notes, and linked documents in one
> place. Create a thread or add a connection to add threads here.

Narrowed variants: "No matching threads in this focus." · "No threads match your search." · "No
threads match your filters." · "No threads match your search and filters."

## Notifications

Which threads notify you, when, and how they're batched and presented is covered in
[`notifications.md`](./notifications.md). In short: a thread's `urgent` and `importance` drive whether
and when it notifies, low-signal threads stay in-app without interrupting you, and reading a thread on
one device retracts its notification on your others.
