# Forward a Note — Design

- **Date:** 2026-07-03
- **Status:** Approved (design); ready for implementation planning
- **Scope:** Flutter app (`apps/plot`), API worker (`workers/api`), SDK + Gmail connector (`public/` submodule)

## Goal

Let a user **forward a note** to new recipients. Forwarding immediately opens a
fresh compose seeded with the note's own channel and a preview of the forwarded
note, where the user can add contacts and optionally write their own message.
When the target channel has built-in forwarding (email), the connector performs
a real upstream forward that carries the original message and its attachments.
Otherwise — including when the user changes the connection/channel — sending
creates a new item whose body is the user's message followed by the blockquoted
forwarded contents.

## Guiding principle: server owns the logic

All forward *assembly* and the *native-vs-fallback decision* live in the API
worker, not the app. The app's only contributions are (1) seeding the compose
surface and (2) attaching a pointer to the source note. This keeps app logic
minimal and lets us patch the forward rules, blockquote formatting, and
snapshotting by shipping a worker rather than an app release. The only
provider-specific code (Gmail MIME) lives in the connector, where it must.

## User-facing behavior

1. Every note gets a **Forward** action in its "…" menu (and optionally the
   hover toolbar). Available on connector-sourced notes (emails, messages) and
   plain Plot notes alike.
2. Selecting Forward **immediately opens a fresh compose** (`NewThreadPage`,
   jumping straight to the compose step) with:
   - **Via** defaulted to the source note's channel/connection (plain Plot if
     the note has no connector),
   - a reply-style **"Forwarding" takeover bar** showing a one-line preview of
     the source note, with an × that clears the forward and reverts to an
     ordinary new thread,
   - **empty recipients** and an **empty message box**.
3. The user can add contacts/groups and, via the existing connection picker,
   **change the connection/channel**. Changing away from the source connection
   automatically routes to the fallback path.
4. On send, the item is delivered per the decision matrix below.

## Native vs. fallback decision (server-side)

The API decides at note-ingest time from two facts it resolves server-side:
the source note's connection, and the target channel's `supportsForward`
capability.

| Condition | Result |
|---|---|
| Target connection **==** source connection **AND** target linkType declares `supportsForward` | **Native forward** — connector rebuilds the real upstream item (Gmail MIME forward, original attachments preserved) |
| Any other case: channel changed, channel has no native forward, or plain Plot target | **Fallback** — a new item whose body is the user's message followed by the **blockquoted** source content; source attachments copied onto the new item where feasible |

"Built-in forwarding" therefore lights up for **email on its own connection**;
everything else is the clean blockquote fallback.

## Architecture

### Client (Dart) — minimal

- **`ForwardNote` command** (`apps/plot/lib/command/note.dart`): modeled on
  `SplitNoteToNewThread` (which reads a note, creates a new thread, and routes
  to it). It resolves the source note's connection (source thread's primary
  link → `createdBy` twist instance + channelId + linkType) and opens
  `NewThreadPage` seeded with that connection choice and a forwarding marker.
  Added to the `noteCommands(...)` list (~823) so it shows in the "…" menu.
- **Compose seeding** (`apps/plot/lib/page/new_thread.dart`): jump directly to
  the compose step with Via pre-selected (as a `CreateLinkUserAction`, the same
  mechanism the connection picker uses) and the forwarding takeover bar active.
- **"Forwarding" takeover bar**: add a `ForwardingState` to the sealed
  `TopBarState` in `apps/plot/lib/widget/note_editor_top_bar.dart` (sibling to
  `ReplyingState`/`EditingState`), rendering a forward icon + "Forwarding"
  label + one-line `quotePreview` + × to clear. In new-thread compose mode the
  bar is currently driven by `ThreadBloc` (`replyTo`/`editingNote`); wire a
  path to feed `ForwardingState` from the `NewThreadPage` seed instead. The
  preview text comes from the local source note — no server round-trip needed
  just to render it.
- **On send**, the draft note carries the user's message content, the target
  `CreateLinkUserAction`, and **`fwdNoteId`** pointing at the source note.
  Nothing else — no blockquoting, no attachment copying, no native/fallback
  branching in Dart.
- **Rendering a forwarded note** (`apps/plot/lib/widget/note.dart`): when the
  viewer is the note's author and `fwdNoteId` resolves to a locally available
  source, render the user's message + a compact "link to original
  message/thread" beneath it, and **suppress** any server-materialized forward
  snapshot on the note. Otherwise (recipient) render the user's message + the
  forwarded snapshot. This is the one piece of forward *rendering* logic in the
  app; it depends only on locally held data so the author's view is identical
  before and after sync (see "Rendering" below).

### Data model

- **New synced column `fwd_note`** (source note reference), sibling to the
  existing `re_note`:
  - Remote schema: add to `libs/db/schema/50-tables` (note table), following the
    `re_note` pattern; generate a migration (`pnpm gen-migration`), apply
    locally, regenerate and commit `libs/db/src/types.ts`.
  - Flutter store: add `fwdNoteId` (`NoteId?`) to `apps/plot/lib/store/note.dart`
    (parallel to `reNoteId` at column 123), with a Drift migration step
    (`Store.migration.onUpgrade`, bump `Store.schemaVersion`; last full-reset
    was v243, so this is an incremental `addColumn`). Include it in the note
    sync serialization (`NotesBase.toBase`).
  - We use a **distinct field** rather than overloading `reNoteId` with an
    intent flag, so the existing reply write-back logic (`reNoteKey` targeting)
    is untouched and the two intents cannot be confused.
  - `fwdNoteId` also drives the **author-only "link to original" affordance** —
    no extra data is needed for the author's view; the link resolves the source
    note/thread locally.
- **Structured forward snapshot** (server-populated, for the recipient view):
  the materialized forwarded content is stored on the note as a **distinct,
  suppressible payload separate from `note.content`** (which always holds only
  the user's own message). Keeping it structured and separate is what lets the
  author suppress it while recipients render it, and keeps external-egress
  formatting (blockquote / MIME) out of the Plot-internal representation. Exact
  representation — a dedicated `UserAction` subtype on the note vs. a separate
  snapshot note — is pinned in the implementation plan; the requirement is that
  it be independently suppressible in the author's renderer.
- **SDK types** (consumed server-side only):
  - `LinkTypeConfig.supportsForward?: boolean`
    (`public/twister/src/tools/integrations.ts`), modeled on
    `supportsFileAttachments`.
  - `CreateLinkDraft.forward?: { key: string }`
    (`public/twister/src/connector.ts`) — the upstream message key to forward.

### Server (`workers/api`) — owns assembly, decision, egress

On ingest/dispatch of a note that carries `fwd_note`:

1. **Resolve** the source note → its content, attachment actions, and connector
   `key` + link (source thread's primary link).
2. **Decide** native vs. fallback per the matrix (compare the target
   `CreateLinkUserAction` connection to the source note's connection; read the
   target linkType's `supportsForward`).
3. **Native path:** call the connector's create path with
   `CreateLinkDraft.forward = { key }` (approach A — reuse `onCreateLink`
   rather than adding a new hook; smaller SDK surface, single template
   obligation for connector authors). The connector rebuilds the real upstream
   item from the key.
4. **Fallback path:** assemble the outbound body as
   `user message + blockquote(source content)`, copy the source note's
   attachment `UserAction`s onto the new item where feasible, then create the
   item — via `onCreateLink` for a connector target, or as a plain Plot note
   for a Plot target.
5. **Materialize** the forwarded content into the note as the structured
   snapshot payload (§ Data model) so recipients see it; the author's client
   suppresses this in favor of the `fwdNoteId` link (see "Rendering" below).

### Snapshot / materialization (visibility)

Unlike reply — whose `reNoteId` points to a note in the *same* thread that all
participants can already see — **forward crosses a trust boundary**: the
recipients of a forward generally *cannot* see the original source note. So the
forwarded content must be **captured (snapshotted) into the new item
server-side**, not rendered as a live cross-thread pointer. The materialized
forwarded content is decoupled from the source note's ACL, so recipients see it
regardless of their access to the original. The client's compose preview
(takeover bar) is a local convenience only; the authoritative forwarded content
is produced by the server at send time and syncs back to the client.

Materialization applies to **both** paths for the Plot-internal view, so any
Plot-using recipient sees what was forwarded regardless of delivery mode:

- **Fallback:** the outbound external item body is the user message +
  blockquoted source content + copied attachments; the Plot-internal note
  carries the same forwarded content as a structured snapshot.
- **Native:** the connector additionally emits the real upstream forward
  externally (the MIME), while the Plot note still carries the snapshot so Plot
  participants see it without depending on the source note's ACL.
  Reconciliation with the connector-returned key follows the normal write-back
  path.

### Rendering: identical before and after sync

The forwarded note must render **identically from the moment it is saved
locally through and after server sync**, in both native and fallback delivery.
The delivery mode is therefore invisible to the note's appearance. We achieve
this by rendering per viewer:

- **Author view** (the person who forwarded): render the user's own message
  plus a compact **link to the original message/thread** shown *under* the note.
  This link is derived entirely from `fwdNoteId` — data the author's client
  already holds at local-save time — so it is present on the very first frame
  and does not change when the server syncs. When the server's materialized
  forward snapshot arrives, the author's client **suppresses** it (the author
  already has access to the original, so the compact link is shown instead).
  Result: content + link, identical before and after sync, native or fallback.
- **Recipient view:** render the user's message plus the **forwarded snapshot**
  (original sender/title, quoted content, copied attachments). Recipients get no
  "link to original" — they may lack access to it — and they never held an
  optimistic local copy, so there is no before/after transition to reconcile.

Because the author's rendering is a pure function of `note.content` + locally
resolved `fwdNoteId` (and never of the server-added snapshot), the
"identical before/after" guarantee falls out structurally rather than from
timing.

## Connector / SDK changes (public submodule → separate PR + changeset)

- **Twister** (`public/twister/src/`):
  - `LinkTypeConfig.supportsForward?: boolean`
    (`tools/integrations.ts`).
  - `CreateLinkDraft.forward?: { key: string }` (`connector.ts`).
  - **Changeset** required (`public/.changeset/`, `@plotday/twister` minor;
    `Added:` prefix). Rebuild twister; `pnpm install` in this repo.
- **Gmail connector** (`public/connectors/gmail/src/`):
  - Set `supportsForward: true` on the email linkType.
  - Add `buildForwardMessage` (near `buildReplyMessage`, `gmail-api.ts:1382`):
    build a forward MIME — `Fwd:` subject, quoted original body, and the
    original attachments re-attached (re-fetched by the retained message id via
    `getAttachment`, `gmail-api.ts:363`; a `format=raw` fetch may be added if a
    faithful copy of the original MIME is preferred over reconstruction).
  - Branch `onCreateLink` (`sync.ts:1867`) on `draft.forward` to build a
    forward instead of a new email.
  - Tests mirror the existing reply-builder tests (subject, quoted body,
    re-attached parts).
- **Outlook and other native forwards are fast-follows** (Outlook has a native
  `POST /me/messages/{id}/createForward`, `graph-mail-api.ts`), gated behind
  the same `supportsForward` flag; until then Outlook uses the fallback.

## Testing

- **Server (workers/api):** native-vs-fallback decision matrix; fallback body
  assembly (user message + blockquote + copied attachments); `fwd_note`
  resolution; materialization into the new thread; recipient visibility of the
  snapshot.
- **SDK/Gmail:** `buildForwardMessage` MIME (subject, quoted body, re-attached
  parts), mirroring the reply-builder tests.
- **Flutter:** `ForwardNote` seeds compose with the correct default Via and an
  active forwarding takeover bar; clearing the bar reverts to a normal new
  thread; `fwdNoteId` round-trips through save/sync; Drift migration test.
- **Rendering guarantee (Flutter widget):** the author's forwarded note renders
  identically pre-sync (no snapshot payload yet) and post-sync (snapshot present
  but suppressed) — content + link-to-original in both — for native and
  fallback alike; a recipient view of the same note renders the forwarded
  snapshot and no link-to-original.

## Scope boundaries

**In:** Flutter forward UX (command, compose seeding, takeover bar); `fwd_note`
column (remote + Drift); SDK `supportsForward` + `CreateLinkDraft.forward`;
server-side decision, fallback assembly, and materialization; Gmail native
forward.

**Out (fast-follows):** Outlook and other native forwards; inline trimming of
forwarded content in compose; forwarding multiple notes at once; forwarding an
entire email thread (vs. a single message/note).

## Risks / notes

- **No optimistic "pop":** the author's forwarded note renders identically
  before and after sync because the author view derives purely from
  `note.content` + locally resolved `fwdNoteId` and suppresses the
  server-materialized snapshot (see "Rendering"). The server still owns
  assembly/egress; it just doesn't alter what the author sees.
- **Attachment copying on the fallback path** depends on the source note's
  attachment `UserAction`s being resolvable/copyable in the new thread's
  context; where an attachment can't be re-referenced it degrades to a
  named reference in the quoted block.
- **`docs/email-gaps.md`** already tracks "Forward action" (Tier 2 #5) and the
  `f` keyboard-shortcut gap — update it when this ships.
- **Finalization:** public submodule PR + changeset; add a `docs/updates.d/`
  fragment (user-facing: "Forward emails and messages to new people"); update
  `docs/features.md`; new `catch` blocks call `captureException`.

## Key file reference map

| Concern | Location |
|---|---|
| Per-note command list / "…" menu | `apps/plot/lib/command/note.dart` (`noteCommands` ~823, `SplitNoteToNewThread` 759 template, `ShowNoteCommands` 891) |
| Note model + `reNoteId` sibling | `apps/plot/lib/store/note.dart` (class 203, `reNoteId` col 123, `NotesBase.toBase` 172) |
| Note rendering (author link vs. recipient snapshot) | `apps/plot/lib/widget/note.dart`; action rows via `NoteActionWidget` (`apps/plot/lib/widget/note_action.dart`) |
| Compose flow / seeding | `apps/plot/lib/page/new_thread.dart` (steps, `_applyConnectionChoice` 1167, connection field 2335) |
| Connection choice model | `apps/plot/lib/widget/compose/connection_choice.dart`; `CreateLinkUserAction` (`apps/plot/lib/store/user_action.dart:431`) |
| Takeover bar (`TopBarState`) | `apps/plot/lib/widget/note_editor_top_bar.dart` (`ReplyingState` 26); computed at `note_editor.dart:790` |
| SDK capability + draft | `public/twister/src/tools/integrations.ts` (`LinkTypeConfig`, `supportsFileAttachments` 211); `public/twister/src/connector.ts` (`CreateLinkDraft` 149) |
| Reply write-back analog | `public/twister/src/connector.ts:656` (`onNoteCreated`); `thread.meta.reNoteKey` |
| Gmail create + reply/MIME | `public/connectors/gmail/src/sync.ts:1867` (`onCreateLink`); `gmail-api.ts:1237/1382` (new/reply builders), `363` (`getAttachment`) |
| Outlook native forward (fast-follow) | `public/connectors/outlook-mail/src/graph-mail-api.ts` (`/createReply`; add `/createForward`) |
| Existing gap doc | `docs/email-gaps.md:57` (Forward action), `:136` (`f` shortcut) |
