# Unread below active — sort change + unread-only filter — design

## Problem

In a focus's feed, unread threads currently project to the **top** of the Active
("Doing") section, sorted by urgency and importance, above the user's read
active to-dos (`apps/plot/lib/state/priority.dart:1260-1294`). This helps catch
up on unread, but causes five problems:

1. It obscures and distracts from known-important committed work in the default view.
2. It blocks dragging a to-do to the top. The current workaround — marking an item
   unread to float it up — is confusing and self-defeating: it becomes read again
   and drops back down.
3. It moves ordered active items out of position whenever they become unread.
4. It contradicts the product's "higher is more important" direction.
5. Marking an item active drops it to the bottom of Active.

We want committed active work to stay where the user put it, and incoming unread
items to sit below it rather than bury it — while still giving a fast way to
triage everything unread when needed (e.g. after tapping a notification).

## Relationship to the prior spec

This supersedes `2026-05-16-unread-filter-toggle-design.md`. That spec added an
unread-only filter while **deliberately preserving** the existing sort
("Changes to section order … Out of scope"). We are now changing that sort: the
default-view reordering is the primary change here, and the filter is revised to
match. Where the two conflict, this document wins.

## Solution overview

1. **Stop projecting active and scheduled unread threads into a top cluster.**
   Active to-dos keep their manual order; an active or scheduled thread that
   becomes unread stays in place and just shows its unread dot.
2. **Cluster only *non-active* unread threads** (incoming items that aren't to-dos
   and aren't scheduled) at the **bottom of the Active section** — mirroring
   today's top-of-Active cluster, just flipped to the bottom — sorted by
   urgency/importance as today. No separate section and no header of its own;
   the cluster stays under the Active header and drains to Done on read.
3. **Reading drains** a non-active unread item to Done on navigation (existing
   behavior, via the sticky-unread overlay), so the bottom cluster stays transient.
4. **A persistent, tri-state header toggle** filters the feed to unread-only for
   triage, placed immediately before the search toggle.

## Feed sort and sections

Top to bottom, the feed becomes:

1. **Active** (`ActivitySection.doing`), under a single "Active" header, in two
   ordered groups:
   - **Active to-dos** in manual `order` — read and unread intermixed by order.
     An unread active to-do stays in its `order` position, showing a dot; it is
     no longer projected to the top.
   - **Non-active unread cluster** at the **bottom of the same section** — unread
     threads whose primary section is Done (plus the sticky-pinned open thread),
     sorted `urgent DESC, importance DESC, order ASC, id ASC` (the comparator
     currently applied to `unreadDoing` at `priority.dart:1287-1294`). This
     cluster gets **no header of its own**; it sits under the Active header,
     mirroring how unread currently sits at the top of Active — just flipped.
2. **Scheduled** (`ActivitySection.scheduled`) — unchanged. An unread scheduled
   thread stays in its date slot with a dot; it is **not** pulled into the
   cluster (mirrors "active stays in place").
3. **Done** (`ActivitySection.activity`) — unchanged; non-active items drain here
   when read.

The change in `_buildUnifiedFeedItems` (`priority.dart:1250-1379`): the
`t.unread || _isStickyPinned(t.id)` branch (lines 1260-1270) no longer captures
active or scheduled threads. Active threads always go to the active-by-`order`
list regardless of read state; only unread threads whose `primarySectionFor` is
`activity` (plus the sticky-pinned open thread) populate the bottom cluster;
scheduled unread stays in Scheduled. The Active section emits its header, then
the active-by-order rows, then the bottom unread-cluster rows.

## Active-stays-in-place semantics

- An active to-do that becomes unread keeps its `order` position; only the unread
  dot appears. It does not move.
- Marking a non-active item active moves it to the **bottom of Active** — unchanged
  from today. (Problem 5 is left as-is by request.)

## Drag / reorder constraints

Drag-and-drop **keeps today's behavior** for the unread cluster — it stays fully
reorderable, and an unread thread can still be promoted into Active by dragging
it up. The **only new constraint** is that an active to-do cannot be reordered
*down into* the non-active unread cluster. The boundary is one-way: unread can
cross up to become active; active cannot cross down into unread.

The dragged thread's identity (active vs non-active unread), not just the drop
position, governs which slots are valid. Four canonical cases:

1. **Unread dragged within the unread cluster** → stays where dropped, remaining
   non-active unread. It **absorbs the destination neighbours' urgency/importance
   bucket** and orders within it — the existing `asUnreadInDoing(order, urgent,
   importance)` path (`priority.dart:2268-2276`). (This resolves "peg order vs.
   change urgency/importance" as *change urgency/importance*: it's how the cluster
   stays urgency/importance-sorted and how a drop sticks today.)
2. **Unread dragged above an active thread** → it crosses the boundary, **becomes
   active**, and stays where dropped — the existing `asActiveToday(order)` path
   (`priority.dart:2282`). Open implementation detail: whether crossing up also
   marks it read (today `asActiveToday` does) or preserves the unread dot — decide
   in the plan; preserving unread is likely more correct ("I triaged it, I haven't
   read it").
3. **Active dragged toward the bottom of Active** → a single drop placeholder opens
   at the **Active/unread boundary** (end of the active to-dos), and **no slots
   open between unread rows**. Dropping snaps it into that end-of-Active
   placeholder. Reordering an active to-do must preserve its read/unread state
   (don't force-read an unread active to-do just because it was dragged) and peg
   `order`.
4. **Active dragged to a Scheduled date or to Done** → stays where dropped, via
   the existing `asScheduled(date, order)` / `asInactive()` paths
   (`priority.dart:2305-2314`). Dropping in Done makes it inactive.

Implementation note: `computeActivityFeedDropBoundaries` and the drag activation
are currently source-agnostic — they emit a slot above every Doing row. To honor
case 3, the slot set (or the activation filter) must become **drag-source-aware**:
when an active thread is dragged, suppress the inter-unread-row slots and expose
only the end-of-Active boundary; when an unread thread is dragged, expose both the
intra-cluster slots (case 1) and the active slots (case 2). A dispatcher clamp
(an active thread dropped into an unread slot lands at the end of Active) is the
backstop. `clusterOf` (`priority.dart:2235-2237`) also moves from keying on
`t.unread` to keying on `isActiveThread`, since unread *active* to-dos now live in
the active order space, not the unread cluster.

## Header toggle (tri-state)

A single persistent icon button, **first in the header action cluster,
immediately before the search toggle** (`unified_header.dart`). It is always
rendered (stable header layout), with three states:

| State | Condition | Icon | Tooltip | Interaction |
|-------|-----------|------|---------|-------------|
| No unread | focus has 0 unread | `envelopeCircleCheck`, **disabled** | "No unread threads" | none |
| Has unread, filter off | ≥1 unread, not filtering | `envelopeDot` | "Show only unread threads" | tap → turn filter on |
| Filtering | filter on | `envelopeDot` in **highlight colour** | "Show all threads" | tap → turn filter off |

No count, no badge — presence of `envelopeDot` is the "you have unread" signal,
matching the prior spec's restraint.

> Icon note: verify `envelopeDot` / `envelopeCircleCheck` exist in the app's Font
> Awesome set (`apps/plot/lib/widget/icon.dart`; the app already uses
> `FontAwesomeIcons.messageDot` for `PlotIcon.unread`). If `envelopeDot` is
> unavailable, fall back to a composed envelope + dot or `messageDot`. Adding or
> changing an FA glyph requires bumping `FONT_CACHE_VERSION` in
> `scripts/cache-bust-fonts.sh` for the web build.

## Filter behavior

When the filter is on, the feed shows only unread threads, preserving section
grouping and order:

- Active section: unread active to-dos (in `order`) followed by the bottom
  non-active unread cluster (urgency/importance sort) — i.e. everything unread
  that lives under the Active header. Read active to-dos are hidden.
- Scheduled: only unread scheduled threads.
- Done: hidden (Done items are read by definition).
- A section header renders only if its filtered view has ≥1 row.

Everything else (header, agenda actions, drag/drop, keyboard nav) is unchanged.
When off, the feed renders exactly as the new default sort above.

## Read-while-filtering — pin the open thread

One unifying rule, identical in filtered and unfiltered views (reuses the
existing sticky-unread overlay):

- While a thread is **open**, it stays visible in its current position even after
  its dot clears.
- On **navigate-away**: a non-active item drains to Done (collapse/expand
  animation); an active item stays a to-do in Active. Either way it leaves the
  filtered view because it is no longer unread.
- Multi-panel: "open" means selected in the side panel; drain happens when the
  user opens another thread or leaves. Single-panel: the move-to-Done occurs per
  today's behavior (on navigation / on marking Done).

The feed recomputes unread membership when the user returns to the focus, not on
every per-thread read flip — same as today.

## Clearing the filter

### Clear on opening the last unread (primary path)

When the user opens an unread thread and **no other unread threads remain** in
the focus, the filter clears immediately, while the just-opened thread stays
pinned until navigation.

- Multi-panel: the list panel reveals the full focus behind the still-open
  thread, so the user lands somewhere real instead of an empty filtered list with
  a dead toggle. The opened thread drains to Done on the next navigation as usual.
- Single-panel: opening the last unread navigates into the thread; the filter is
  already off underneath, so backing out lands on the full focus.

### Back gesture clears the filter first (mirrors search)

The back gesture that would leave the focus instead **clears the filter first,
staying in the focus**, so the user sees the full feed; a second back leaves.
This mirrors the existing search-filter clear in `_closeSearch`
(`unified_header.dart:299-339`) and its back registration
(`LayoutBloc.registerSearchClose`). Backing out of an individual thread to the
focus list does **not** clear the filter — that is not "leaving the focus."

### Auto-off safety net

If the focus's unread set reaches 0 by any other means (e.g. the last item is
read on another device and syncs in while filtering), the filter turns itself off
on the next recompute and the toggle transitions to the disabled
`envelopeCircleCheck` state. In-session, clear-on-open-last preempts this.

## Auto-apply on notification entry

When the user opens a focus by **tapping a notification**, auto-enable the unread
filter — the user is clearly entering to triage what's new. (If the notification
deep-links to the focus's only unread thread, clear-on-open-last immediately
releases the filter, so the net effect is simply "focus + that thread, full feed
visible.") Manual navigation into a focus does **not** auto-apply; the filter is
off by default.

## State scope

- Per-focus, in-memory only; held on the priority Bloc as `bool unreadFilterActive`
  with a derived `bool hasUnread` selector (per the prior spec's structure).
- Switching focuses resets the filter to off (except the notification-entry case,
  which sets it on for the entered focus).
- Not persisted across app restarts. Rationale unchanged from the prior spec: this
  is a triage mode, not a saved preference.

## Keyboard shortcut (optional, carried from prior spec)

Carry forward `⌘⇧U` / `Ctrl+Shift+U` bound to the toggle command, active only
when a focus feed is the focused view and ≥1 unread exists. Drop if we'd rather
not spend the binding — not load-bearing for this change.

## Edge cases

- **Active + unread item read while filtering:** loses its dot, stays pinned while
  open, then leaves the filtered view (still a to-do in Active). Same pin rule.
- **No non-active unread:** the bottom cluster is simply absent; the Active
  section shows only its to-dos (or no Active header at all if empty), and the
  toggle shows disabled `envelopeCircleCheck`.
- **Urgent buried at bottom:** accepted for now; we keep the urgency/importance
  sort within the bottom cluster and will revisit (e.g. urgent break-through) only
  if monitoring shows urgent items get missed.
- **Animation sequencing:** when the last unread is opened, the filter release and
  the feed repopulating should read as one motion, not a flash of empty list.

## Copy and onboarding updates

Any user-facing copy that describes the **old** behavior must be updated to the
new one. Sweep onboarding screens, in-app guidance, seeded/onboarding threads,
tooltips, and help/marketing text for wording like "New and updated threads
arrive at the **top** of Active" and reword to reflect that unread now arrives
at the **bottom** of Active (with committed to-dos staying on top). Implementation
must grep the app, onboarding content, and docs for such phrases — at minimum
search for "top of Active", "top of the list", "arrive at the top", and similar —
and update each hit. Also add a `docs/updates.md` entry under `## Next release`
describing the reordering in plain language.

## Out of scope

- Count badge or number on the toggle.
- Persistence across sessions or focuses.
- Changing how unread state is computed, or the Scheduled/Done sort.
- Urgent break-through ordering (monitor first).
- A global/cross-focus "all unread" view.

## Implementation touchpoints

- Sort/sections: `apps/plot/lib/state/priority.dart` `_buildUnifiedFeedItems`
  (1250-1379) and the unread comparator (1287-1294); section enum
  `apps/plot/lib/state/activity_section.dart`.
- Filter state + selectors: priority Bloc (`priority.dart` / `priority_state.dart`).
- Sticky/pin + drain reuse: `_isStickyPinned`, `_applyOverlay` (`priority.dart`).
- Drag/drop: `apps/plot/lib/widget/activity_feed_drag.dart`
  (`computeActivityFeedDropBoundaries` → make source-aware; `dispatchActivityFeedThreadDrop`)
  and `applyActivityFeedThreadDrop` / `resolveDoingDrop` / `clusterOf` /
  `asUnreadInDoing` / `asActiveToday` / `asScheduled` / `asInactive`
  (`priority.dart:2161-2352`).
- Header toggle + back clearing: `apps/plot/lib/widget/unified_header.dart`
  (action cluster, `_closeSearch` precedent at 299-339, `LayoutBloc` back
  registration).
- Notification entry hook: wherever a notification tap routes into a focus.
- Command: new `ToggleUnreadFilter` in `apps/plot/lib/command/`.
- Icons: `apps/plot/lib/widget/icon.dart` (+ `FONT_CACHE_VERSION` bump for web).
- Copy sweep: onboarding screens/threads, in-app guidance, tooltips, and docs
  that describe unread arriving at the top of Active; plus a `docs/updates.md`
  entry under `## Next release`.
