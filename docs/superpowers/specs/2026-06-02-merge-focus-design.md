# Merge focus into another focus

**Date:** 2026-06-02
**Status:** Approved

## Summary

Replace the **Archive** command on a focus (priority) with **"Merge into…"**
whenever the focus contains threads. "Merge into…" opens a modal to pick a
target focus; selecting one moves every thread from the source focus into the
target and then archives the source focus.

When a focus has **no** live threads, keep the plain one-click **Archive**
command instead — there is nothing to merge.

The Inbox (root focus) is never offered Archive or Merge. As a side change,
the existing "leave team" behavior that was coupled to archiving the last
team focus is removed entirely: archiving/merging never affects team
membership.

## Background

- A **focus** is a `Priority` (`apps/plot/lib/store/priority.dart`). Focuses
  are now **flat** — there is no descendant/sub-focus nesting to account for.
- Threads are filed into a focus via `thread.priorityId` locally (the
  server's per-user `thread_priority` model is what actually re-files on
  sync; a thread `save()` with a changed `priorityId` is sufficient to
  propagate the move, exactly as `MoveToPriority` relies on today).
- The current Archive command is `TogglePriorityArchived`
  (`apps/plot/lib/command/priority.dart:366`). It is emitted by
  `prioritySecondaryCommands` (`priority.dart:1255`) for any focus that is
  `!root && !isViewer && !isPlot`, and it doubles as **Un-archive** for an
  already-archived focus. It currently contains a "leave team" branch
  (`priority.dart:391-465`) that runs a `ConfirmModal` and POSTs to
  `/sync/priority/archive-or-leave` when archiving the last top-level team
  focus.
- The store already enriches each `Priority` with computed `active` and
  `unreadComputed` flags by querying the `threads` table
  (`_getUnreadPriorityIds` / `_watchUnreadPriorityIds`,
  `priority.dart:658-704`) and attaching them via `Priority.fromStore`. This
  is the pattern we mirror for "has threads".
- `MoveThreadToPriority` (`apps/plot/lib/command/thread.dart:1779`) is the
  reference implementation for a focus-picker `CommandModal`: it lists
  focuses from `Priority.getRaw`, excludes the current focus, and pins Inbox
  at the bottom as a branded row.

## Goals

1. Show **"Merge into…"** in place of Archive on an active focus that has at
   least one live thread.
2. Keep **Archive** on an active focus with no live threads.
3. Keep **Un-archive** unchanged for archived focuses.
4. Never offer Archive/Merge on Inbox, viewer focuses, or the Plot system
   focus (unchanged gating).
5. Merge: re-file every thread from the source focus into the chosen target,
   then archive the source.
6. Remove the leave-team special handling from archiving.

## Non-goals

- No descendant/sub-focus re-parenting (focuses are flat).
- No undo beyond un-archiving the source focus (which will not pull the moved
  threads back).
- No "create a new focus" option inside the merge picker (merging into a
  brand-new empty focus is effectively a rename; can be added later).
- No confirmation dialog before the merge — choosing a destination is the
  deliberate act (consistent with the immediate `MoveToPriority`).

## Design

### 1. Detect "focus has threads" via an enrichment flag (Option 2.A)

The menu builders are synchronous and called from ~6 sites (sidebar kebab,
right-click `ContextMenu`, touch swipe, and three header menus), so a thread
count cannot be `await`ed at build time. Instead, attach a computed flag to
the `Priority` object, mirroring `active` / `unreadComputed`:

- Add a transient `hasThreads` field to `Priority` (no Drift column, no
  migration — it is computed enrichment like `active`).
- Add `_getNonEmptyPriorityIds(ids)` and `_watchNonEmptyPriorityIds()` that
  mirror the unread helpers:
  `SELECT DISTINCT priority_id FROM threads WHERE priority_id IN (ids) AND archived_at IS NULL`.
  (Definition of "has threads": at least one **non-archived** thread filed
  under the focus.)
- Thread the new set through:
  - `_enrichWithStatus` (the `get()` path) — compute the set and pass
    `hasThreads: nonEmptyIds.contains(p.id)` into `fromStore`.
  - the `watch()` combineLatest — add a fourth stream
    (`_watchNonEmptyPriorityIds()`), include it in the tuple, and pass
    `hasThreads` into `fromStore`.
  - `Priority.fromStore` and the `Priority` constructor — add the named
    field, following the established `active` / `unreadComputed` handling.
    (Heed the known `fromStore`-drops-fields gotcha — forward the new field
    everywhere `active` is forwarded, or it silently resets.)

**Risk to verify in the plan:** the header / current-focus menus
(`page/priority.dart:267`, `widget/unified_header.dart:954,974`) must receive
an **enriched** `Priority`. The sidebar list already is (via `watch`). If the
current-focus object is not enriched with `hasThreads`, enrich it at that
build site (these header menus are built before opening a `CommandModal`, so
an async enrichment there is acceptable). The right-click `ContextMenu`
(`widget/priority.dart:266`) is fed by the enriched sidebar list, so it needs
no change.

### 2. Branch the command slot

In `prioritySecondaryCommands` (`priority.dart:1255`), replace the single
`TogglePriorityArchived` entry (keeping the same outer gating
`!root && !isViewer && !isPlot`) with:

```
if (priority.archivedAt != null)
  TogglePriorityArchived(priority)        // "Un-archive" — unchanged
else if (priority.hasThreads)
  MergeFocusInto(priority)                // "Merge into…" — new
else
  TogglePriorityArchived(priority)        // "Archive" — empty focus
```

### 3. `MergeFocusInto` — the picker

A `ShowCommands` subclass (title "Merge into…", icon `PlotIcon.move`) that
builds its `CommandModal` via `commandsBuilder`, closely reusing
`MoveThreadToPriority._getMoveCommands`:

- Source: `Priority.getRaw(order: PriorityOrder.recent)` (non-archived).
- Partition out the root (Inbox); exclude the source focus
  (`p.id != source.id`).
- Build `MergeFocus(source, target)` commands for each remaining focus, plus
  an Inbox row pinned at the bottom (`label: 'Inbox', glyph: PlotIcon.inbox`)
  when the source is not itself the root.
- Prompt: `Merge "<source title>" into…`.
- No secondary "Add a focus" command (non-goal).

### 4. `MergeFocus` — the action

A `Command` run when a target is selected:

1. Look up **every** thread filed under the source focus
   (`priorityId == source.id`, no archived filter — so archived threads move
   too and nothing is stranded under the archived source).
2. For each, `thread.copyWith(priority: target).save()`, wrapped in a single
   transaction for atomicity. The thread `save()` is what syncs the
   re-filing. **Skip** the per-thread `/sync/priority-moves` "learning
   signal" — a bulk merge is a deliberate re-file, not N classifier-training
   events. (Consider a bulk update for large focuses; mind the
   txn-zone-capture gotcha when dispatching pushes.)
3. Archive the source: `source.copyWith(archivedAt: Value(DateTime.now())).save()`.
4. If the source was the currently-open focus, return
   `CommandRoute(PriorityRoute(target))` so the user follows their threads to
   the target; otherwise `CommandDone`. Drift watch streams refresh the
   sidebar and feed.
5. Wrap unexpected failures in a `catch` that calls
   `Tracker.captureException` and surfaces a `CommandMessage` error.

Because filing is per-user, a merge only re-files the current user's view and
archives the current user's source focus. Teammates' filings and their copy
of the focus are untouched.

### 5. Remove leave-team handling

Strip the team branch from `TogglePriorityArchived.run`
(`priority.dart:391-465`) so Archive/Un-archive is a plain `archivedAt`
toggle for all focuses (the behavior the non-last-team-priority path already
takes). Remove the now-dead `/sync/priority/archive-or-leave` call and the
`countOtherTopLevelTeamPriorities` usage from this command. Leave the server
endpoint in place (unused) for backward compatibility. This removes the
in-app path to leave a team via archiving, which is intended.

## Testing

- Unit/widget coverage where practical for the command branch selection
  (archived → Un-archive; active+threads → Merge; active+empty → Archive)
  and for `MergeFocus` re-filing + archiving.
- Manual verification via the `run-app` skill:
  - A focus with threads shows "Merge into…"; merging moves all its threads
    into the chosen target and archives the source; if the source was open,
    the view follows to the target.
  - An empty focus shows "Archive" and archives in one click.
  - Inbox shows neither.
  - Archiving a (formerly team-coupled) focus no longer prompts to leave a
    team.
- `flutter analyze` clean on changed files.

## Files touched (anticipated)

- `apps/plot/lib/store/priority.dart` — `hasThreads` field, enrichment
  helpers, `fromStore` / constructor / `_enrichWithStatus` / `watch`.
- `apps/plot/lib/command/priority.dart` — branch in
  `prioritySecondaryCommands`; remove leave-team flow from
  `TogglePriorityArchived`.
- `apps/plot/lib/command/thread.dart` *(or a new command file)* —
  `MergeFocusInto` + `MergeFocus` (may live in `command/priority.dart`
  instead, beside the other priority commands).
- Possibly `apps/plot/lib/page/priority.dart` /
  `apps/plot/lib/widget/unified_header.dart` — ensure the current-focus
  `Priority` passed to the header menus is enriched with `hasThreads`.
- `docs/updates.md` (+ `docs/features.md`) — user-facing note at finalize.
