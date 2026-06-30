# Show note commands during the send (undo) window

**Date:** 2026-06-29
**Branch:** `note-commands-during-send`

## Problem

When a note is sent it enters a 5-second "undo send" window (see
`PendingSend`, `apps/plot/lib/state/pending_send.dart`). During this window
`NoteWidget` (`apps/plot/lib/widget/note.dart`, footer block ~250–426)
**replaces its entire footer** with a single right-aligned `sending ✕` cancel
button. That throws away the normal footer, including the bottom-left
`NoteCommands` row (mark to-do, add reaction, reply, more) plus any
already-applied tag/reaction chips.

As a result, the user cannot act on a note they just sent until the window
elapses — they can't immediately mark it to-do, react, etc.

## Goal

During the send window, surface the bottom-left note commands exactly as on
any other note, while keeping the `sending ✕` undo affordance visible. Actions
take effect instantly in the UI and sync when the window commits (≤5s), or are
pulled back with the note if the user undoes.

**Decision (confirmed with user):** Acting on the note does **not** end the
undo window. The 5s undo stays available; the action rides along with the note
(held push) and commits with it — or is reverted with it on undo. We do **not**
commit-on-action.

## Why this is mostly already supported

The sent note is a **real, saved row** (`draft:false`); only its remote *push*
is held via `PendingSend` + `Store.pushHeldNoteIds`. The commands operate on
that real row, so they already function — they're just not rendered.

The push hold filter (`Store._buildHoldFilter`, `apps/plot/lib/store/store.dart`
~1475) **already covers `note_tags` and `note_reactions`** (they share the
parent note's id). So a to-do or reaction added during the window is held
alongside the note and pushed together when `PendingSend.commit()` releases the
hold — correct ordering, no extra work.

## Changes

### 1. Footer layout — `apps/plot/lib/widget/note.dart` (~250–426)

Stop discarding the footer in the `sending` branch. Always render the existing
`Stack`:

- **Right slot** (`Positioned right:0`): conditionally
  `sending ? <sending ✕ button> : <author/timestamp>`. The `sending ✕` button
  keeps its current tooltip ("Cancel" + Esc shortcut) and its ghost-padding
  right-alignment (`Transform.translate`).
- **Left slot** (`Align centerLeft` overlay): `NoteCommands(...)` rendered in
  **both** states, unchanged, with `showCommands: _hovered`.

Behavior this produces, matching a normal note:
- On a fresh send with no tags, the left side is empty until hover; on hover the
  to-do / add-reaction / reply / more buttons appear.
- Adding a tag (e.g. a to-do) makes its chip always-visible (it's a real row).
- The existing `NoteCommands` gradient-fade background truncates left-side
  content cleanly against the right slot, same as it does against
  author/timestamp today.

No new widget, no changes to the command classes, no change to `NoteCommands`.

### 2. Undo-orphan fix — `apps/plot/lib/store/store.dart` (`_buildDraftFilter`)

This change makes it possible to react to a still-held note and then **undo**.
`undo()` flips the note to `draft + archived` and releases the hold. The draft
filter already excludes `note_tags` of a draft note from the push claim, but it
does **not** cover `note_reactions`. Without a matching clause an orphaned
reaction could push against a note that was never sent (server 404).

Add the mirroring clause for `note_reactions`:

```
note_reactions → ' AND id NOT IN (SELECT id FROM notes WHERE draft = 1)'
```

### 3. No change to `PendingSend`

`start` / `commit` / `undo` / `flush` / timer all stay exactly as-is. The window
runs its normal course; actions simply ride along.

## Out of scope

- Commit-on-action / ending the window early when the user acts (explicitly
  rejected above).
- Any change to which commands `NoteCommands` shows, or to command behavior.
- Touch/long-press path changes — `ShowNoteCommands` already works on the real
  row.

## Testing

- **Unit:** add a `_buildDraftFilter` case asserting the `note_reactions`
  clause, mirroring existing draft-filter tests.
- **Manual (run-app), per prior undo-send testability wall:**
  1. Hover a note inside its send window → bottom-left commands appear; `sending
     ✕` stays on the right.
  2. Mark to-do during the window → the to-do chip shows and persists; `sending
     ✕` remains; after the window the note + to-do sync.
  3. Add a reaction during the window, then hit undo → the note disappears and
     no orphaned reaction is pushed (no 404 in sync).

## Risk / backwards compatibility

Low. The note row is unchanged structurally (same keyed row, same 30px footer
height); only the footer's children change. No schema/migration. The draft
filter addition is defensive and consistent with the existing `note_tags`
handling.
