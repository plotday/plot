# Thread note initial expand/collapse + scroll

**Date:** 2026-05-30
**Status:** Approved (design)

## Summary

Change how a thread's notes are initially expanded/collapsed and where the
note list is scrolled on open (`ThreadPage`). Today every long note is
height-truncated ("View all" fade) regardless of context, and the list always
rests at the bottom (newest note) in the `reverse: true` list. The new
behavior keys off note count and unread status:

- **Single note:** never collapsed (rendered untruncated), and the list opens
  scrolled to the **top** of that note.
- **Multiple notes, some unread:** the unread notes start **expanded**
  (untruncated); read notes keep today's truncation/"View all" collapse. The
  list opens scrolled to the **top of the oldest unread note** (the first one
  the user would read), so the older read notes sit off the top.
- **Multiple notes, none detectable as unread:** unchanged — every long note
  stays collapsed and the list rests at the bottom (newest note); no
  auto-scroll.

No schema changes. No new divider/separator UI. Scope is limited to
`lib/page/thread.dart` and `lib/widget/note.dart`.

## Determining "unread" notes

There is **no per-note read flag**. The only read signal is the thread-level
`thread.readAt` (`DateTime?`). A note is considered **unread** when:

```dart
readAt == null || note.sourceCreatedAt.isAfter(readAt)
```

This is self-consistent with the existing read logic. When a thread has been
read, `ThreadPage` sets `readAt = thread.contentTimestamp`, which equals the
newest note's `sourceCreatedAt`. So for a fully-read thread, no note is
strictly after `readAt` → nothing is unread (this is the "can't tell which are
unread" case). A `null` `readAt` (never read) treats every note as unread,
which lands the user at the top of the oldest (first) note — the natural start
of a brand-new thread.

### Snapshot timing (critical)

`ThreadPage` marks the thread read 750 ms after open via `_scheduleMarkAsRead`,
which resets `readAt` to `contentTimestamp`. All expand/scroll decisions must
therefore be based on a **snapshot of `readAt` captured before that timer
fires**.

- Capture `_initialReadAt = thread.readAt` once in `didChangeDependencies`
  (the thread is already available there), before/independent of the 750 ms
  mark-read timer.
- Base both the per-note expand decision and the scroll-target decision on
  `_initialReadAt`, not the live `thread.readAt`.

This guarantees notes do not suddenly collapse ~750 ms after the page settles
when the thread gets marked read.

## Initial expand state (per note)

Computed from the snapshot and used to **seed** the existing
`_TruncatedNoteContentState._expanded` field in `initState`. Seeding it (rather
than recomputing on every build) means a later rebuild with a fresh `readAt`
will not re-collapse an already-expanded note, and matches the current
"once expanded, stays expanded — no inline collapse" behavior.

- **Single note total** → `initiallyExpanded = true`, unconditionally.
- **Multiple notes** → `initiallyExpanded = isUnread(note)` using the snapshot.
  Read notes get `false` and keep today's truncation + "View all" fade.

Plumbing:

- `NoteWidget` gains an `initiallyExpanded` parameter (default `false`),
  forwarded to `_TruncatedNoteContent`.
- `_TruncatedNoteContent` gains an `initiallyExpanded` field; its State sets
  `_expanded = widget.initiallyExpanded` in `initState`.
- `ThreadPage._buildItemAtIndex` computes the flag per note from
  `state.notes.length` and `_initialReadAt`.

## Initial scroll (one-shot)

Runs **once** on the first load where notes are present, guarded by a
`_hasAppliedInitialScroll` flag so it does not re-fire on note syncs or
rebuilds. Pick a **target note**, then scroll so the **top** of that note sits
at the top of the viewport:

- **Single note** → target = that note. "Scroll to top" in the `reverse: true`
  list = jump to `maxScrollExtent`.
- **Multiple + has unread** → target = the **oldest unread** note. Scroll so
  its top aligns to the viewport top, pushing older read notes off the top.
- **Multiple + no unread** → no scroll; the list rests at its default position
  (bottom / newest note).

### Mechanism

`InfiniteListController` is focus-based and exposes no scroll-to-index, so the
underlying `ScrollController` is driven directly (via
`ScrollControllerContext.of(context)`), mirroring the existing pattern in
`lib/widget/list_view_selector.dart`.

- Attach a `GlobalKey` to the target note widget when `ThreadPage` builds it.
- In a post-frame callback after the first layout with notes present, scroll
  the `ScrollController` so the target's top aligns to the viewport top,
  accounting for the inverted alignment caused by `reverse: true`.
- Single-note case shortcuts to `maxScrollExtent`.

The exact offset math (RenderBox geometry vs. `Scrollable.ensureVisible`
alignment in a reversed sliver list) is an implementation-plan detail.

## Reversed-list reminder

The note list is built with `reverse: true`: index `0` is the newest note
(rendered at the bottom), index `notes.length - 1` is the oldest (rendered at
the top). Scroll offset `0` is the bottom (anchored); `maxScrollExtent` is the
top. "Oldest unread" is the unread note with the highest index. Alignment
semantics in `Scrollable.ensureVisible` are inverted under `reverse: true`.

## Out of scope / non-goals

- No per-note read tracking or schema changes.
- No "new messages" divider/separator UI.
- No inline collapse affordance (expanded notes stay expanded, as today).
- No change to the 750 ms mark-as-read behavior itself.

## Affected files

- `apps/plot/lib/page/thread.dart` — snapshot `readAt`, compute per-note
  `initiallyExpanded`, target-note `GlobalKey`, one-shot initial scroll.
- `apps/plot/lib/widget/note.dart` — `NoteWidget.initiallyExpanded` →
  `_TruncatedNoteContent.initiallyExpanded` → seed `_expanded` in `initState`.
