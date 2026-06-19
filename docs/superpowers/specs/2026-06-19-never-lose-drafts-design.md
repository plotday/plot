# Never-lose drafts — design

**Date:** 2026-06-19
**Status:** Approved (design)

## Problem

A draft thread can currently be lost. Two behaviors on `NewThreadPage` destroy
draft content:

- `_finalizeDraftInBackground` (in `lib/state/priority.dart`) dedupes drafts per
  focus by **deleting** every draft but the most-recently-updated one filed at a
  priority.
- `_resetToFreshStart` (in `lib/page/new_thread.dart`), invoked when the user
  presses the New thread button / ⌘N while a `NewThreadPage` is already live,
  **reuses the existing draft id and clears it** — wiping the in-progress draft
  to start a new one.

Users may legitimately want several drafts in flight. We want drafts to be
durable, discoverable, discardable, and recoverable.

## Goals

1. A draft thread is never lost.
2. Users may keep multiple drafts at once.
3. Returning to New thread (back / button / shortcut, when not already on the
   page) shows the most recent draft in progress, alongside the others.
4. Pressing New thread again while composing saves the current draft and starts
   a fresh one.
5. `NewThreadPage` gains a **Drafts** section at the top, listing drafts as tiles
   styled like the other sections, each with a trailing ✕ to discard (archive).
6. With "show archived items" on, up to 5 most-recently-archived drafts appear in
   that section, restorable.

## Non-goals / future

- **Focus-affinity ordering.** Floating drafts/contacts/channels related to the
  current focus to the top of the picker is a desirable future tuning, but out of
  scope here. Drafts list by recency (`updated_at` desc) for now.
- No new schema, table, or sync change.

## Data model (no schema change)

Drafts are existing `thread` rows with `draft = true`. Status is derived from
`archived_at`:

| State              | Predicate                                   |
| ------------------ | ------------------------------------------- |
| Active draft       | `draft = true AND archived_at IS NULL`      |
| Discarded draft    | `draft = true AND archived_at IS NOT NULL`  |

Discarding sets `archived_at = now()` (soft-delete, reaches Flutter via the seq
cursor and is restorable). Restoring sets `archived_at = null`. This reuses the
existing `Thread.delete()` / unarchive paths in `lib/store/thread.dart`.

### Substantive vs skeleton drafts

A draft is **substantive** — eligible to be listed and preserved — when it has
any of:

- a non-empty title, or
- non-empty body text (note content), or
- ≥1 recipient (contact, group, or invite-email), or
- an attached link / external action, or
- a schedule (`at` / `on`).

A **skeleton** draft (none of the above — e.g. a draft the page mints just to
have something to compose into, never touched) is never listed and is **deleted**
(not archived) when abandoned, so the Drafts list stays clean and the archive
isn't polluted with empties.

A single pure predicate, e.g. `bool isSubstantiveDraft(Thread, Note)`, is the
source of truth and is unit-tested in isolation.

### Behaviors removed / changed

- Remove `_finalizeDraftInBackground`'s per-focus dedup deletion. Multiple
  drafts at the same focus now coexist. (The duplicate-cleanup that predates
  multi-draft support is no longer correct.)
- `_resetToFreshStart` no longer reuses + clears the existing draft id. The
  current working draft, if substantive, is left intact as a saved draft; the
  page mints a brand-new empty working draft. If the current working draft is a
  skeleton, it is reused/deleted rather than left dangling.

## Working-draft lifecycle

The "working draft" is `PriorityBloc.state.draft` + `draftNote` — what the
compose flow edits.

The two stated behaviors (return shows the most recent draft; New-thread-again
saves current and starts new) **collapse into one rule**:

> Every entry into New thread presents a **fresh empty working draft on the
> step-1 picker**, with all saved drafts listed in the Drafts section
> (most-recent first).

- **Return to New thread** (not already on the page): land on the picker; the
  most recent draft is at the top of the Drafts section, one tap to resume.
- **New thread again** (already composing): the in-progress draft is an autosaved
  `thread` row, so it simply remains in the Drafts list; the page mints a fresh
  working draft and resets to the picker.
- **Navigate away by any other means** (open a thread/priority): the working
  draft is already autosaved; if substantive it stays in the list, if skeleton it
  is cleaned up.

Landing always uses a fresh empty working draft (not the most-recent draft
pre-loaded as the active target). This avoids accidentally overwriting a resumed
draft when the user then picks a target, and matches the approved "land on the
picker, drafts listed" choice. Resuming a specific draft is always an explicit
tap on its tile.

The current `setPriority` chain-draft auto-resume (which forces a focus's draft
into the editor) no longer drives `NewThreadPage`'s working draft; the page
starts fresh and surfaces drafts through the section instead.

## Drafts section UI

A new **Drafts** `PillGridSection`, pinned **at the top** of the step-1 picker,
above People & twists / Channels / Private notes. It is **global** — drafts from
all focuses — ordered by `updated_at` desc.

Each draft is a tile styled to match the section rows (same row chrome,
hover/keyboard highlight, keyboard navigation), rendered one per line:

- **Leading icon**: the draft's icon (link favicon / twist / link glyph) or a
  default draft glyph when none.
- **Label**: title; else a preview snippet from the body; else recipients
  ("To: Bob, Alice"); else "Untitled draft".
- **Trailing ✕**: discard (archive) — see below.
- **Tap (row body)**: load the draft as the working draft and jump to compose
  (resume editing where it left off).

Because the existing sections render as wrapping pills, the Drafts section is
implemented as full-width row-tiles that reuse the section's visual chrome and
keyboard navigation (e.g. a list/block variant of `PillGridItem`/section), rather
than wrapping chips, so titles and the trailing action have room.

## Discard & restore

- **Discard (✕):** archives immediately (`archived_at = now()`), defined as a
  command (`DiscardDraft`) per the commands convention. Recoverable via the
  show-archived toggle. An optional brief "Draft discarded" confirmation may be
  shown; no blocking confirm dialog.
- **Show archived items on** (`localPreferences.showAllPriorities`, the existing
  global archived-visibility flag): the Drafts section additionally lists up to
  **5** most-recently-archived drafts (`archived_at` desc). These tiles show a
  **restore** icon instead of ✕; tapping the tile restores
  (`archived_at = null`) and resumes the draft in compose. Restore is a command
  (`RestoreDraft`).

## Components & responsibilities

- `lib/store/thread.dart` — query helpers: list active substantive drafts
  (global, recency order); list up to N most-recently-archived drafts. Reuse
  `idx_threads_draft`.
- Pure helper (e.g. in `lib/state/compose_targets.dart` or a small new file) —
  `isSubstantiveDraft` predicate + draft-tile label derivation; unit-tested.
- `lib/state/compose_targets.dart` (`ComposeSections` / `ComposeTargetsBloc`) —
  carry the drafts list (active + optional archived) so the picker renders them
  reactively, consistent with how people/channels/focuses are loaded.
- `lib/page/new_thread.dart` — build the Drafts section at the top; wire tap
  (resume), ✕ (discard), restore; change `_resetToFreshStart` to preserve the
  current substantive draft and mint a fresh one; mint a fresh working draft on
  fresh entry; clean up skeleton drafts on abandon.
- `lib/state/priority.dart` — remove per-focus dedup deletion; provide a "mint a
  fresh working draft" path and a "preserve current + start fresh" path.
- `lib/command/thread.dart` (or `lib/command/...`) — `DiscardDraft`,
  `RestoreDraft` commands.

## Testing

- Pure unit tests: `isSubstantiveDraft` across each substantive dimension and the
  all-empty skeleton case; draft-tile label derivation fallbacks.
- Store/query tests: active substantive drafts list (global, recency, excludes
  archived & skeletons); archived drafts list capped at 5, recency order.
- Behavior tests: New-thread-again preserves the prior substantive draft and
  starts fresh (no id reuse / clear); skeleton working draft is cleaned up on
  abandon; discard archives; restore unarchives; show-archived surfaces ≤5
  archived drafts with restore affordance.
- `flutter analyze` clean.

## Edge cases

- Discarding the draft currently loaded as the working draft: archive it and
  reset the picker to a fresh working draft.
- Resuming an archived draft (restore path) while the show-archived toggle later
  turns off: the now-active (unarchived) draft stays in the active list.
- No drafts: the Drafts section is omitted entirely (like other empty sections).
- More than 5 archived drafts: only the 5 most-recently-archived show; the rest
  remain archived and reachable through normal archived browsing, not this
  section. (Surfaced cap — not silent.)
