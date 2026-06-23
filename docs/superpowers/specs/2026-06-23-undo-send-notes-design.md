# Undo send for notes — design

Date: 2026-06-23
Status: Approved (pending spec review)

## Summary

Add a 5-second "undo send" window when a user sends a note, covering both
**adding a note to an existing thread** and **the first note of a brand-new
thread**. During the window the note renders in the thread view, but the footer
slot that normally shows the author name + timestamp instead shows an **xs ghost
button labeled `SENDING` with an `✕`**. After 5 seconds the note really sends and
the footer reverts to the usual author + timestamp. Clicking the button — or
pressing **Esc** in the NoteEditor while a send is pending — pulls the note's
content back into the NoteEditor and cancels the send. If the app is closed or
the user signs out while a note is `SENDING`, the note is committed (sent)
immediately.

The feature is implemented by **deferring the existing draft → published
promotion by 5 seconds** rather than inventing a new note state. A note is
already a local-only `draft` until "send," and a new thread is already
`draft=true` until its first note publishes; undo simply postpones that
promotion and renders the still-draft note optimistically in the meantime.

## Scope

In scope:

- Sending a new note into an existing thread.
- Sending the first note of a new thread (new-thread compose flow).

Out of scope:

- **Editing** an existing note (the `editingNote` path in `note_editor.dart`)
  keeps its current immediate-save behavior — no undo window.
- Any change to how *other* devices/users see a note once it has actually been
  sent.

## Behavior

### The SENDING window

- **One in flight at a time.** Only a single note may be in its `SENDING` window
  at any moment. If the user submits another note while one is pending, the
  pending note **commits immediately** (publishes + pushes) and the new note
  starts its own fresh 5-second window.
- **Duration: 5 seconds.**
- **Rendering during the window:** the note appears in the thread view exactly
  as a normal note, except the ~30px footer row's author/timestamp cluster
  (avatar + "You"/name + "•" + relative time) is replaced, in the same
  right-aligned position, by an **xs ghost button**: the text `SENDING` followed
  by an `✕` icon. No countdown ring or numeric timer — just the label and X.
- **Commit (timer fires):** the note is published (`draft=false`) and pushed to
  remote; the footer flips to the normal author + timestamp. For a **new
  thread**, the thread is *also* promoted `draft=false` and pushed at this same
  moment (the thread was not promoted earlier — see below).

### Undo

Triggered by **either**:

1. Clicking the `SENDING ✕` ghost button, or
2. Pressing **Esc** in the NoteEditor while a send is pending.

Effect:

- Cancel the 5-second timer.
- Remove the note from the thread view.
- Move the note's full content — body, links, file attachments, mentions,
  access settings — back into the NoteEditor (resume-draft).
- **Existing thread:** the thread is otherwise unchanged.
- **New thread:** the user **stays in the thread view**. The thread remains
  `draft=true` (it was never promoted). If the user re-sends, it commits and
  promotes normally. If the user **abandons** it (navigates away without
  re-sending), it resurfaces in the NewThreadPage **drafts** list — a natural
  consequence of it still being a draft.

### Editor already has text at undo time

If the user sent a note and then began typing a *new* note before undoing, the
restored content **replaces** whatever is currently in the NoteEditor. With the
one-at-a-time rule and a 5-second window this is predictable and the simplest
correct behavior. (We do not attempt to merge the two bodies.)

### App close / sign-out while SENDING

- The pending note is **committed immediately** — published + pushed, and (for a
  new thread) the thread promoted `draft=false`. Undo is no longer possible.
- If the device is **offline** at that moment, the note is still finalized
  locally (published, marked pending-for-sync) so it will be sent on the next
  sync. We do **not** block the close/sign-out waiting on the network.

### Non-graceful crash

The spec only requires *graceful* close / sign-out to send. On a hard crash the
un-committed note survives as a `draft` (recoverable in the editor), and a
new-thread draft surfaces in the drafts list — it simply isn't auto-sent.

## Mechanism

### Why deferring the draft promotion is the right lever

From the codebase:

- A composed note lives as `draft=true` (local-only, never pushed) until send;
  `Note.save()` skips all thread-level side effects while `draft=true`.
- A new thread is created `draft=true` and is invisible to other devices/users
  and excluded from feeds until promoted; promotion to `draft=false` currently
  happens inside `PriorityBloc.add()` at the moment the first note is sent.
- There is **no periodic background push** that would sweep up a pending note;
  pushes are triggered explicitly. So a note we deliberately leave un-pushed
  will stay un-pushed until we push it (modulo another note push — which the
  one-at-a-time rule prevents, since we commit the prior send first).

Therefore "undo send" = keep the note (and, for new threads, the thread) in its
existing `draft` state for 5 more seconds, render it optimistically, and only
then run the existing publish/promote/push steps.

### Components

1. **`PendingSend` controller (single slot)** — new, e.g.
   `lib/state/pending_send.dart`. Holds the in-flight draft note id, its thread
   id, an `isNewThread` flag, the finalized note (content + resolved
   actions/mentions/access), and a 5-second `Timer`. A single slot is sufficient
   because only one send is in flight. Exposes:
   - `start(...)` — register a pending send and arm the timer.
   - `commit()` — publish the draft + push; promote the thread if new; clear.
   - `undo()` — cancel timer; return the finalized draft for the editor to
     resume; clear. Leaves the thread as draft for the new-thread case.
   - `isPending(noteId)` — for the note footer to decide whether to render
     `SENDING`.
   - `flush()` — synchronous-ish commit used by close/sign-out hooks.
   - A change signal (Listenable/stream) so the thread view + note footer rebuild
     when a send starts/commits/undoes.

2. **`note_editor.dart`** — on submit (`_onNoteSubmitted` /
   `_onNewThreadSubmitted`), finalize the draft exactly as today (resolve
   attachments, mentions, access, reply restrictions) **but keep it
   `draft=true`**, hand it to `PendingSend.start(...)`, and clear the editor. Do
   **not** publish/push here, and for a new thread do **not** promote the thread.
   Add Esc handling: if a `PendingSend` is active, Esc triggers
   `PendingSend.undo()` and restores the returned draft into the editor instead
   of blurring.

3. **`note.dart` (`NoteWidget`)** — the footer checks
   `PendingSend.isPending(note.id)`; if true, render the `SENDING ✕` ghost button
   in place of the author/timestamp row; tapping it calls `PendingSend.undo()`
   and routes the restored content back to the active NoteEditor.

4. **`thread.dart` (`ThreadBloc`)** — render the single pending draft note in the
   thread's note list even though it is `draft=true` (normally draft notes are
   not shown in the thread body). Provide the entry points the editor/footer use
   to start/commit/undo, and emit state so the list updates.

5. **`new_thread.dart` / `PriorityBloc`** — when sending the first note of a new
   thread, create the thread and navigate into its thread view **without**
   promoting it out of draft; promotion happens later inside
   `PendingSend.commit()`. (Today `PriorityBloc.add()` promotes immediately —
   that step moves into the deferred commit.)

6. **`window.dart` + `base.dart`** — call `PendingSend.flush()` from the
   `_onExitRequested` shutdown drain and from `Base.signOut()` (before clearing
   identity), so a pending note is committed before the app closes / the session
   ends.

### Restore-to-editor detail

Because the in-flight note is still a `draft`, "move it back into NoteEditor" is
essentially *resume editing this draft*: the editor re-adopts the finalized
draft (content + actions + mentions) returned by `PendingSend.undo()`, replacing
its current contents. The new-thread case keeps the same draft thread, so the
existing draft-resume machinery applies.

## Files touched (anticipated)

- `lib/state/pending_send.dart` — **new** `PendingSend` controller.
- `lib/widget/note_editor.dart` — defer publish/promote; Esc → undo; restore.
- `lib/widget/note.dart` — `SENDING ✕` footer rendering + tap-to-undo.
- `lib/state/thread.dart` — render pending draft note; start/commit/undo wiring.
- `lib/page/new_thread.dart` and/or `PriorityBloc` — create+navigate new thread
  as draft; promote at commit instead of at submit.
- `lib/widget/window.dart` — flush on app close.
- `lib/base.dart` — flush on sign-out.

## Testing

- **Existing-thread send:** submit → note shows `SENDING`; after 5s footer shows
  author + timestamp and the note is pushed.
- **Undo via button** and **undo via Esc:** note leaves the thread, content
  returns to the editor, nothing pushed.
- **New-thread send:** submit → navigates into thread view, thread stays draft,
  note shows `SENDING`; after 5s thread promotes (`draft=false`) and both push.
- **New-thread undo + abandon:** content returns to editor, thread stays draft,
  navigating away surfaces it in the NewThreadPage drafts list.
- **One-at-a-time:** submitting a second note while one is `SENDING` commits the
  first immediately, then starts the second's window.
- **Editor-has-text on undo:** restored content replaces current editor text.
- **Close / sign-out while SENDING:** note is committed (online: pushed; offline:
  finalized locally, sent on next sync).

## Open considerations

- Exact widget styling of the xs ghost button (size, color) follows existing
  ghost-button conventions; it must fit within the ~30px footer height without
  shifting layout.
- If `ThreadBloc` already had an optimistic-emit path for added notes, the
  pending render reuses it; otherwise a minimal "render this one draft" branch is
  added.
- **Risk to verify during planning:** a still-`draft` *thread* must be viewable
  in the thread view during the new-thread SENDING window. Draft threads are
  filtered out of *feeds*, but navigating directly to a thread by id may already
  render fine; if the thread view itself filters `draft=true`, that filter needs
  a narrow exception for the one pending-send thread. Confirm before implementing
  the new-thread path.
