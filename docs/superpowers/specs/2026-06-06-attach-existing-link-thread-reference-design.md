# Attach existing items as thread references (instead of navigating)

**Date:** 2026-06-06
**Status:** Approved — ready for implementation plan
**Scope:** `apps/plot` only. No DB migration, no server changes.

## Problem

In the note editor's "Add link" flow (the link button on `NoteEditor`,
including on `NewThreadPage`), picking an existing link that belongs to a Plot
thread currently **navigates to that thread**, abandoning whatever the user was
composing. Because nearly every `Link` row carries a `threadId`, this means the
picker is effectively useless for *attaching* an existing item — selecting one
almost always navigates away.

Two changes are wanted:

1. Picking an existing item should **attach it as a non-primary reference** to
   the current note, never navigate.
2. The picker should additionally surface **Plot threads themselves**,
   including notes-only / non-connection threads (which have no `Link` row and
   therefore never appear today).

Separately, the modal's **"Create new …" connector functionality is removed** —
that capability is now provided directly from `NewThreadPage`'s two-step
compose flow, so it is redundant inside the link modal.

## Behavior

The "Add link" modal becomes a pure *attach an existing reference* picker, used
identically in **all** note editors (new-thread composer and existing threads).

| User picks… | Today | New |
|---|---|---|
| Existing link on a Plot thread (incl. connector links like a Linear issue) | navigate to that thread | attach `ThreadUserAction(threadId, title, priorityId)` |
| A **Plot thread** found by search (incl. notes-only, non-connection) | not surfaced at all | attach `ThreadUserAction(...)` |
| A link with an external URL and **no** `threadId` | attach `ExternalUserAction` | unchanged |
| A pasted brand-new URL | attach `ExternalUserAction` | unchanged |
| "Create new …" connector target | `CreateLinkUserAction` | **removed** (done from `NewThreadPage`) |

The attached thread reference is **non-primary by construction**: it lives in
the note's `actions` list and renders as a `ThreadLinkButton`. It never becomes
the thread's primary link (which only originates from a connector or a
create-link action) and therefore never affects composer copy or the thread's
sharing model.

## Why `ThreadUserAction` (not a thread-level link row)

There is no server-side concept of one Plot thread linking another besides a
note action. `ThreadUserAction` (`type: "thread"`, `{threadId, title,
priorityId}`) is the established mechanism for referencing another thread from
note content, and it already renders via `ThreadLinkButton`
(`lib/widget/note_action.dart`).

A client-created `ThreadUserAction` round-trips through sync intact:

- `POST /sync/notes` stores `note.actions` **verbatim** (passes `p_actions`
  straight into `upsert_note`; no validation/transformation).
- On pull, the server **enriches** `type: "thread"` actions by filling in fresh
  `title` and `priorityId` from the referenced thread — it never generates,
  rewrites, or drops them.
- The client's note pull preserves `actions` unless the local row has pending
  changes.

So `threadId` is the authoritative reference; `title`/`priorityId` are display
metadata. We set them client-side for immediate render and the server refreshes
them on every pull.

## Surfacing Plot threads in the picker

Notes-only Plot threads have **no `Link` row**, and the modal queries only the
`Link` store (`listRecent()` even requires `sourceUrl IS NOT NULL`). To surface
them, the modal must search the **thread** store.

The existing facility is `Thread.searchRemote(query, {archived: false})`
(`lib/store/thread.dart`), which hits `/sync/threads/search`, hydrates results
locally, and returns full `Thread` objects (including `priorityId`, needed to
build a complete `ThreadUserAction`).

Per design decision, threads are surfaced **on text search only** (a "Threads"
group), not as a "recent threads" list in the empty state.

**Offline limitation (accepted for v1):** `Thread.searchRemote` is
network-backed; there is no exposed local thread search. Offline, the "Threads"
group is empty but link/URL picking still works. Wiring local FTS
(`thread_fts`) is a possible later follow-up.

## Components to change (all `apps/plot/lib`)

### 1. `widget/link_input.dart` — `LinkModal`

**Add thread search & a thread result variant:**
- Add a `Thread? thread` variant to `_LinkItem` (e.g. `_LinkItem.thread(...)`).
- On a non-URL text search, also call `Thread.searchRemote(text,
  archived: false)` and append a `SelectGroup(title: 'Threads', …)` of matched
  threads. (URL searches keep resolving against the `Link` store as today.)
- Add an `itemBuilder` case for the thread variant: a thread/link icon plus the
  thread title.
- In the result mapping, a picked thread item returns
  `LinkModalResult.thread(thread)`. An existing **link** with a non-null
  `threadId` continues to resolve its `Thread` and return
  `LinkModalResult.thread(thread)` (unchanged resolution; only the downstream
  meaning changes from navigate → attach).

**Remove all "Create new …" plumbing:**
- Delete the `createTargets` field, the `loadCreateTargets()` call, and both
  "Create new" `SelectGroup`s (empty-state and matching-search).
- Delete the `_LinkItem.createExternal` variant and `isCreateExternal`.
- Delete the `createTargetTile(...)` `itemBuilder` branch and the
  `LinkModalResult.create(...)` result handling.
- Delete the `LinkModalResult.create` constructor and the
  `isCreateAction` / `createAction` members.

### 2. `command/add_link.dart` — `AddLink`

- Remove the `onNavigateToThread` constructor parameter and the
  `result.isThread → onNavigateToThread` branch.
- Remove the `result.isCreateAction` branch (no longer produced).
- New `result.isThread` handling: build
  `ThreadUserAction(threadId: thread.id, title: thread.title,
  priorityId: thread.priorityId)` and append to `currentActions`, **deduped by
  `threadId`** (don't add a thread reference that's already attached).
- `result.isLink` (external URL → `ExternalUserAction`) unchanged.

### 3. `widget/note_editor.dart`

- Remove the `onNavigateToThread` field and its pass-through to `AddLink`.
- Add `UserActionType.thread` to the attachment-row filter (~lines 1136–1143)
  so a draft `ThreadUserAction` renders in the attachment row with the "✕"
  remove affordance, consistent with file/external attachments. Use the thread
  title (fallback "Thread") as the row label and a thread/link icon.

### 4. `page/new_thread.dart`

- Remove the now-unused `onNavigateToThread: (thread) =>
  context.run(ChangeCurrentThread(thread))` callback passed to `NoteEditor`
  (two call sites).

### 5. `widget/connection_targets.dart`

- Delete `createTargetTile(...)` (used only by the link modal).
- **Keep** `CreateTarget`, `loadCreateTargets()`, `connectionTargetTile()`, and
  `CreateTarget.toUserAction()` — all still used by the `NewThreadPage` compose
  flow (`new_thread.dart`, `state/compose_targets.dart`,
  `widget/compose/*`, `widget/connection_chip.dart`).

## Non-goals

- No DB migration, no server/worker change, no schema change.
- No `FONT_CACHE_VERSION` bump unless a new FontAwesome glyph is introduced
  (reuse an existing thread/link icon).
- No local thread-search (FTS) wiring; remote search only for v1.
- No "recent threads" group in the empty state (search-only).

## Risks / edge cases

- **Dedup:** appending the same thread reference twice must be prevented
  (dedup by `threadId` in `AddLink`).
- **Removing navigation is global:** `AddLink` is used only by note editors;
  removing `onNavigateToThread` affects new and existing threads alike (this is
  the intended "everywhere" behavior).
- **Stale display metadata:** if a referenced thread is later deleted or access
  is lost, `title`/`priorityId` may go stale/null; `ThreadLinkButton` already
  disables its tap when `priorityId == null`.

## Verification

- `flutter analyze` clean on changed files (and broadly, since
  `connection_targets.dart` / `link_input.dart` are widely imported).
- Manual (run-app) check: in both the new-thread composer and an existing
  thread, the link button opens the modal; searching a Plot thread title
  (including a notes-only thread) shows it under "Threads"; picking it adds a
  removable thread chip to the note and does **not** navigate; picking a
  connector-backed link adds a thread reference to its Plot thread; pasting a
  URL still attaches an external link; no "Create new …" entries appear.
