# Message-Sharing Thread Participants & Per-Message Recipient Changes — Design

**Date:** 2026-06-04
**Status:** Design (awaiting review)
**Scope:** `sharingModel: "message"` threads (email; the only message-mode connector today is Gmail). Thread-mode and channel-mode are explicitly out of scope and unchanged.

---

## Problem

Message-sharing threads (email) show **empty avatar groups** in the `ThreadWidget` list rows and in the `ThreadPage` header. Example: `https://app.plot.day/t/Cb4dQ8PbTozvstYETvSUx` (thread `019e2c5a-af0a-7e5a-980a-2ba147814721`).

### Root cause (grounded in production data)

The original hypothesis was that thread-level sharing isn't being set. The data says otherwise:

- The example thread has `thread.contacts` = **3** (the viewer + 2 external participants), `dropped_contacts` = 0. Every note carries explicit `access_contacts`.
- Across **all 6,795** non-archived email threads in prod: **0** have empty `thread.contacts`, and **0** have any `dropped_contacts`.

So `thread.contacts` *is* reliably populated as the union of participants. The empty avatars are a **rendering** choice, not missing data:

- For `sharingModel == message`, `SharedCommandButton` (used by **both** the list row and the header) derives the avatar set per-viewer from `thread.notes` via `Thread.deriveVisibleContacts(...)` instead of reading `thread.contacts`.
- In the **list**, `thread.notes` is never loaded → `deriveVisibleContacts` returns the empty set → no avatars.
- In the **header**, notes arrive a frame after the bloc's initial state → empty at first paint.

The `dropped_contacts` / 50%-removal heuristic (`reconcileThreadContacts`) has had **zero observed effect** in production and only ever runs on inbound `saveLink`.

### Key building-block facts (verified)

- **BCC is already safe.** Hidden-role contacts (Gmail declares `bcc` with `hidden: true`) are stripped **per-viewer at sync-out** by `stripHiddenRoleContactsFromThreads` (`workers/api/src/app/sync/viewer.ts`). A non-privileged viewer never receives BCC contacts in their copy of `thread.contacts`. Therefore rendering the overview directly from `thread.contacts` does **not** leak BCC.
- **Notes carry no per-recipient role.** `note.access_contacts` is a visibility set only; To/CC/BCC roles live solely at the thread level in `thread.contact_meta`. Membership deltas between messages are derivable today; role-transition deltas ("Sam to BCC") are not.

---

## Goals

1. **Goal 1 — overview.** `ThreadWidget` and the `ThreadPage` header show a good overview of everyone on the thread, even when individual messages didn't include all of them.
2. **Goal 2 — sensible reply default.** The reply composer defaults to a reasonable assumption of recipients "at that point in the thread."
3. Make it **easy to re-add** a thread participant who wasn't on the last message.
4. Surface per-message recipient changes inline, without clutter.

## Non-goals

- Thread-mode (Slack DMs, calendar) and channel-mode (Slack channels, Linear) behavior — unchanged.
- Role-transition delta lines ("Sam to BCC", "Moved Sam to CC") — deferred (needs per-note role storage).
- Removing the `dropped_contacts` column now — left in place (unused); a follow-up contract migration drops it.

---

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Avatar overview source (header + list) | Read `thread.contacts` (the union), same path thread-mode uses |
| Reply default audience | Participants of the most recent **visible** note (author ∪ `access_contacts`), minus self |
| Header avatar tap (message-mode) | **Read-only** participant overview; no thread-roster editing |
| Where recipients are edited | Only the composer's **Reply pill** |
| Per-message line trigger | Note's audience **differs from the immediately preceding note** |
| Per-message line styling | Interstitial **feed-update** line (right-aligned, author-name text size, equal spacing above/below) — not a tag/badge |
| Per-message line content (v1) | **Membership deltas** ("Added X", "Dropped X", "Dropped everyone except X"); role transitions deferred |
| 50% removal rule | Removed; `thread.contacts` becomes a monotonic union |

---

## Design

### 1. Data model

- **`thread.contacts` = monotonic union** of everyone ever on any message. Grows when any inbound or outbound message includes a new participant; **never auto-shrinks**.
- **`note.access_contacts` = that message's audience** (unchanged).
- The 50% rule is removed. `thread.dropped_contacts` is dead (0 rows) — we stop reasoning about it; `Thread.activeContacts` therefore equals `Thread.contacts`.

### 2. Avatar overview — fixes Goal 1

**`apps/plot/lib/widget/thread.dart` — `SharedCommandButton`** (currently ~`1021–1070`): in message-mode, stop computing `visibleContactIds` via `Thread.deriveVisibleContacts(...)`. Read the avatar set from **`thread.contacts`** through the existing `command.sharedDisplayActors` / `loadSharedDisplayActors()` path — i.e. the same code thread-mode already runs. `thread.contacts` is always present on the synced thread row, so list rows and first-paint headers populate correctly.

- No client-side role filtering is added: the client's `thread.contacts` is already BCC-stripped per-viewer server-side.
- `Thread.deriveVisibleContacts` becomes unused → removed (see §6).

### 3. Reply default — Goal 2

**`apps/plot/lib/widget/note_editor.dart` — `_replyAudience`** (currently ~`768–781`): derive the default audience from the **most recent visible note** instead of `thread.activeContacts`:

```
latest        = ThreadBloc state's notes.last   // notes are ordered ascending by created_at
defaultAudience = { latest.authorId } ∪ latest.accessContacts   // reply-all to the last message
display       = defaultAudience − self
```

**Draft initialization** (in `ThreadBloc`, where the reply draft is created/reset): set the draft's `access_contacts` to `defaultAudience` (including self per the note-author constraint) so the Reply-pill avatars, the picker pre-selection, and the actual send all agree. If there are no notes yet, fall back to `thread.contacts`.

This applies to the **reply composer in an existing message-mode thread**. New-thread compose (`apps/plot/lib/page/new_thread.dart`) is a separate flow where the user picks recipients explicitly — it is **unchanged** by this work.

- Excluding someone from a reply narrows **only the note**; it never shrinks `thread.contacts`.
- Adding a brand-new person in the picker grows `thread.contacts` (existing `threadContactsAdded` path in `editNoteRecipients`, `apps/plot/lib/state/thread.dart` ~`93–143`).
- The server keeps `resolveAccessContactsForSend`'s `null → thread.contacts` fallback (`workers/api/src/app/sync/notes.ts`) as a safety net; the client normally sends an explicit list.

### 3a. Reply recipient picker — three sections (Goal 3)

Reuses the pattern from the removed assignment picker (commit `d3696a092`: "Assigned" / "In this thread" / "Contacts"). `RecipientPickerModal` (`apps/plot/lib/widget/recipient_picker_modal.dart`) wraps `PickShared`, which builds commands via `buildSharedSelectionCommands` (`apps/plot/lib/command/share.dart` ~`174–254`). Today that emits two groups: **Shared** + **Share with** (selected actors excluded from suggestions).

Add an **opt-in** middle section so the reply picker shows:

1. **Recipients** — the current reply audience (default = latest-message participants; self pinned via `injectSelf`). Tap to remove.
2. **In this thread** — actors on `thread.contacts` (the union) **not** currently selected and not self. One tap re-adds them to *this reply*.
3. **Share with** — general MRU/search suggestions, with **both** the Recipients and the In-this-thread sets added to `excludeActorIds`. Typing a new email still invites (grows the thread union).

**Implementation:** extend `buildSharedSelectionCommands` with optional params (e.g. `List<ActorId> threadMemberIds`, `String? threadSectionTitle`). When provided, emit an "In this thread" `StaticCommandGroup` (members minus current selection minus self) between "Recipients" and "Share with", and union `threadMemberIds` into the suggestion group's `excludeActorIds`. Other callers (thread share, new-thread compose) pass nothing and are unaffected. `RecipientPickerModal` passes the thread union and titles the selected group "Recipients".

### 4. Header interaction

**`SharedCommandButton.onPress`** (`apps/plot/lib/widget/thread.dart` ~`1185–1191`): in message-mode, replace the `PickThreadShared` (thread-editing) action with a **read-only participant overview** — a non-editable list of the thread's participants (the privileged sender additionally sees BCC roles, since the server only sends those to them). No add/remove. The composer's **Reply pill** remains the only place to edit a reply's audience.

- Thread-mode keeps `PickThreadShared` (editable roster). Channel-mode keeps its read-only channel title. Only message-mode changes here.

### 5. Per-message recipient-change line

A new interstitial element in the notes feed.

- **Trigger:** rendered between note `N-1` and note `N` when `audience(N) ≠ audience(N-1)`. The first note never gets one.
  - `audience(note)` = `note.accessContacts?.toSet()`, falling back to `thread.contacts.toSet()` when null (legacy notes).
- **Styling:** a feed-update line, **right-aligned**, text sized like author names, muted color, with vertical spacing equal above and below so it reads as an event between the two notes (not a badge attached to either). Implemented as a list-level insertion where both adjacent notes are in scope (the notes feed builder in `apps/plot/lib/page/thread.dart`), in a new widget `apps/plot/lib/widget/recipient_change_line.dart`.
- **Content (v1 — membership deltas).** A static helper `Thread.recipientChangeLabel({previous, current, self ids, nameLookup})` returns the label string (or null = no line). Phrased from the reader's perspective; self excluded from named lists.

  Let `added = current − previous − self`, `removed = previous − current − self`, `currentOthers = current − self`.
  - `added` and `removed` both empty → `null`.
  - `removed` non-empty, `added` empty, `currentOthers.length == 1`, **and `removed.length >= 2`** → **"Dropped everyone except {that one}"**. (The `removed >= 2` guard is deliberate: when exactly one person leaves, "Dropped {Alex}" is clearer than "Dropped everyone except {Paul}". Both phrasings come from the brainstorm examples; count decides which reads better.)
  - `removed` non-empty, `added` empty (the remaining cases, incl. a single drop) → **"Dropped {names}"**.
  - `added` non-empty, `removed` empty → **"Added {names}"**.
  - both non-empty → **"Added {addedNames}, dropped {removedNames}"**.

  Name formatting (`{names}`): 1 → `A`; 2 → `A and B`; 3 → `A, B and C`; >3 → `A, B +N`.

  *(Phrasing is presentational and easily tuned during implementation; these are the defaults.)*

- **Replaces** `NoteBadge` + `Thread.noteBadgeLabel` (the divergence-vs-superset badge from the earlier plan).
- **Deferred:** role-transition lines ("Sam to BCC") — needs per-note role storage.

### 6. Cleanup / removal (all message-mode-scoped)

The monotonic union is **already enforced by the DB**: `user.upsert_thread` (`libs/db/schema/90-user-schema/80-upsert_thread.sql` ~`305–335`) unions `v_existing.contacts || v_input_contacts` for an attested caller (which inbound connector sync is) and never shrinks `thread.contacts`. So no new union logic is needed server-side — we just delete the dead 50%/`dropped_contacts` machinery:

- **`workers/api/src/twist/tools/plot/link.ts`** (~`184–228`): delete the message-mode `dropped_contacts` reconciliation block entirely, plus the now-unused imports (`reconcileThreadContacts`, `updateThreadDroppedContacts`, `getSharingModelForChannel`). `thread.contacts` keeps unioning via `upsert_thread`.
- **`workers/api/src/twist/sharing.ts` — `reconcileThreadContacts`:** delete the function (its only callers were `link.ts` and its own test). Delete `sharing.test.ts`. **Keep** `updateThreadDroppedContacts` — still used by the user-facing `workers/api/src/app/thread-share.ts` endpoint.
- **`apps/plot/lib/store/thread.dart`:** remove `deriveVisibleContacts` (now unused) and `noteBadgeLabel` (replaced by `recipientChangeLabel`).
- **`apps/plot/lib/widget/note_badge.dart`** and its usage in `apps/plot/lib/widget/note.dart`: removed/replaced by the recipient-change line.
- **Keep unchanged:** `stripHiddenRoleContactsFromThreads` (`viewer.ts`) — the BCC strip is what makes the overview safe.
- **`thread.dropped_contacts` column:** left in place (unused). Follow-up contract migration to drop it (and `Thread.droppedContacts` / `activeContacts` in Dart) once clients no longer reference it.

---

## Components & boundaries

| Unit | Responsibility | Depends on |
|---|---|---|
| `SharedCommandButton` (overview) | Render avatars from `thread.contacts`; message-mode tap → read-only overview | `thread.contacts`, sharing model |
| Reply default (`_replyAudience` + draft init) | Default reply audience = latest note's participants | `ThreadBloc.notes`, `note.{authorId,accessContacts}` |
| `buildSharedSelectionCommands` (+ "In this thread") | Three-section reply picker; one-tap re-add | `thread.contacts`, `ShareCandidatesCache` |
| `recipientChangeLabel` + `RecipientChangeLine` | Compute & render membership-delta feed line | consecutive `note.access_contacts`, name lookup |
| `reconcileThreadContacts` (server) | Union incoming participants into `thread.contacts` | inbound `saveLink` |

---

## Testing & verification

- **Server (vitest):** rewrite `workers/api/src/twist/sharing.test.ts` for the union semantics (adds newcomers; never drops; dedupes; stable order; empty-previous = incoming). Add/adjust a case in the `link.ts` inbound path if unit-testable.
- **Flutter:** no widget-test harness — verify with the `run-app` skill against a real Gmail thread (the example thread `Cb4d…`):
  1. **List rows** show participant avatars (previously empty). ✅ Goal 1
  2. **Header** shows the same overview at first paint. ✅ Goal 1
  3. **Reply pill** defaults to the latest message's participants; opening the picker shows them pre-selected. ✅ Goal 2
  4. Picker has a **"In this thread"** section letting you one-tap re-add a thread participant not on the last message. ✅ Goal 3
  5. Tapping the **header** avatar shows a read-only participant list (no edit affordance).
  6. A message whose recipients differ from the prior message shows the **feed-update line** with the correct membership delta; consecutive same-audience messages show none. ✅ Goal 4
  7. A thread that recently narrowed to 2 people keeps the reply at 2 (does not re-expand to the full roster).

---

## Follow-ups (out of scope)

1. **Role-transition deltas** ("Sam to BCC", "Moved Sam to CC") — requires per-note recipient-role storage (schema + compose/send persistence).
2. **Contract migration** dropping `thread.dropped_contacts` (and the Dart `droppedContacts` / `activeContacts` accessors) after clients stop referencing them.
3. **Delta-line phrasing tuning** with real usage (thresholds for "Dropped everyone except X", truncation counts).
