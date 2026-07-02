# LinkedIn connection-request note + Accept/Ignore actions

**Date:** 2026-07-01
**Status:** Approved (design)
**Area:** `connectors/linkedin` (private connector)

## Problem

An inbound LinkedIn connection request (invitation) that arrives with **no
personal message** produces a thread whose title is the inviter's name and
whose body is completely empty. In the app this reads as a mystery item —
there is no note explaining what it is, no way to see who the person is, and
no visible action to accept it. (Requests that *do* carry a personal message
already get a note authored by the inviter, so they are legible; bare requests
are the gap.)

Accepting is currently only possible via a hidden path — moving the thread to
the "Connected" status calls `acceptInvitation` in `onLinkUpdated`. There is
no way to ignore a request from inside Plot even though the underlying tool
supports it.

## Goal

Make every inbound connection request self-explanatory and actionable:

1. A connector-authored note that states the request and shows who the person
   is (name → profile link, plus their LinkedIn headline).
2. Two action buttons on that note — **Accept** and **Ignore** — matching
   LinkedIn's own two options.

## Feasibility (all primitives already exist)

- **Action buttons in a note**: `Note.actions: Array<Action>` supports
  `ActionType.callback`, rendered as buttons that invoke a connector method via
  `this.callback(this.method, ...args)`.
- **Ignore**: `this.tools.linkedin.ignoreInvitation({ channelId, invitationId })`
  already exists on the tool and the Unipile client — it is simply never wired
  into the connector today.
- **Accept**: `this.tools.linkedin.acceptInvitation({ channelId, invitationId })`
  already exists and is used by the status→"Connected" write-back in
  `onLinkUpdated`.
- **Profile link + headline**: note content is markdown; `inv.inviter` carries
  `name`, `subtitle` (the LinkedIn headline), and `profileUrl`.
- **Connector-authored note**: notes take an `author`; system-voice notes are
  an established pattern in this connector.

## Design

### Note

On any inbound invitation — **bare and with-message alike** — the connector adds
one system note authored by the connector, keyed per invitation so it is
idempotent across re-syncs.

Content (`contentType: "html"` / markdown):

> **[Héctor Hernán Godoy](profileUrl)** requested to connect.
> Designer | Product/Investment Manager

- The name is a markdown link to `inv.inviter.profileUrl`.
- The second line is `inv.inviter.subtitle` (the headline) and is omitted when
  the inviter has no headline.
- For requests that also carry a personal message, this system note sits
  **above** the inviter's existing message note, so the thread reads
  "X requested to connect" then their actual message.

### Actions

Two `ActionType.callback` buttons attached to the note:

- **Accept** → `this.callback(this.onAcceptInvitation, { channelId, invitationId })`.
  The handler routes through the **existing** accept path: calls
  `acceptInvitation`, sets the link `status` → `inbox` ("Connected"), and
  reuses the current `invitation_writeback:${invitationId}` idempotency flag.
  It then rewrites the note: removes both buttons (`actions: []`) and updates
  content to reflect the accepted state ("Connected").
- **Ignore** → `this.callback(this.onIgnoreInvitation, { channelId, invitationId })`.
  New handler: calls `ignoreInvitation`, archives the thread (`archived_at`),
  and clears the buttons. This wires up the already-present `ignoreInvitation`
  tool method. Guard with the same per-invitation flag so accept/ignore are
  mutually exclusive and each fires at most once.

### Lifecycle / reconciliation

- **Idempotency**: both handlers short-circuit on the existing
  `invitation_writeback:${invitationId}` flag, so a double-tap or a re-fired
  callback is a no-op. The flag records which action was taken (`accept` /
  `ignore`).
- **Out-of-band resolution**: if the user accepts/ignores the request directly
  on LinkedIn, incremental sync sees the invitation leave the pending list.
  The connector then clears the note's buttons and updates its content — to
  "Connected" when it became a 1st-degree relation, otherwise just removes the
  actions (no misleading "Connected" for a request that was ignored elsewhere).
- **Stale buttons after action**: pressing a button updates the note in place
  (via a keyed `NoteUpdate`) so the resolved state is reflected without a full
  re-sync.

## Scope guard (YAGNI)

- No "ignore with a reason", no message-on-accept, no re-invite flow.
- Exactly the two options LinkedIn itself offers: Accept and Ignore.
- No new statuses beyond the existing `pending` / `inbox`; Ignore uses archive.

## Files expected to change

- `connectors/linkedin/src/linkedin.ts`
  - `buildInvitationLink`: always emit the connector-authored note with the
    name-link + headline content and the two callback actions; keep emitting
    the inviter's message note below it when present.
  - New handlers `onAcceptInvitation` / `onIgnoreInvitation` (callback targets)
    that perform the write-back, update link status / archive, and rewrite the
    note's actions/content.
  - Incremental-sync reconciliation for invitations that leave the pending list.
- No SDK (`public/twister`) change: all required types/methods already exist.
- No built-in-tool change: `acceptInvitation` and `ignoreInvitation` already
  exist on `this.tools.linkedin`.

## Open items deferred to the user (already answered)

- **Note style**: sentence + headline (chosen over headline-only).
- **Ignore semantic**: archive the thread (chosen over a distinct "Ignored"
  status).
