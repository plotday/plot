# LinkedIn invitation: accept state

## Problem

Incoming LinkedIn connection requests sync into Plot as links of type
`invitation` with one of two statuses: `pending` or `archive` (labelled
"Archived"). Neither status writes back to LinkedIn — moving an invitation to
"Archived" only hides it locally; the request stays pending on LinkedIn until
the user goes to LinkedIn and acts on it.

The Unipile tool already exposes `acceptInvitation` and `ignoreInvitation`
(`workers/api/src/twist/tools/unipile/linkedin.ts:144,156`). The connector
just never calls them.

## Goal

Let the user accept (or ignore) a LinkedIn connection request from inside
Plot, and have that decision reach LinkedIn.

## Design

### Status config

In `connectors/linkedin/src/linkedin.ts`, the invitation `linkType` gets a
new `accepted` status and renames `archive` to `ignored`:

```typescript
const STATUS_ACCEPTED = "accepted";
const STATUS_IGNORED  = "ignored";

linkTypes = [
  // ...message type unchanged (still uses STATUS_INBOX / STATUS_ARCHIVE)...
  {
    type: TYPE_INVITATION,
    label: "Connection request",
    logo: "https://api.iconify.design/logos/linkedin-icon.svg",
    logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
    statuses: [
      { status: STATUS_PENDING,  label: "Pending"  },
      { status: STATUS_ACCEPTED, label: "Accepted", done: true },
      { status: STATUS_IGNORED,  label: "Ignored",  done: true },
    ],
  },
];
```

- `STATUS_ARCHIVE = "archive"` stays declared in the file because the
  `message` link type still uses it. Only the invitation type stops
  referencing it.
- Both terminal states set `done: true` so Plot's UI and tag logic treat
  them as resolved (consistent with Gmail's `archived` status pattern at
  `public/connectors/gmail/src/gmail.ts:124`).
- No `tag:` on either status. Connection-request resolution doesn't need to
  surface as a thread tag.

### Write-back via `onLinkUpdated`

The connector currently has no `onLinkUpdated` override. We add one,
scoped to invitations:

```typescript
override async onLinkUpdated(link: Link): Promise<void> {
  if (link.type !== TYPE_INVITATION) return;

  const meta = (link.meta ?? {}) as Record<string, unknown>;
  const channelId    = meta.channelId    as string | undefined;
  const invitationId = meta.invitationId as string | undefined;
  const sharedSecret = meta.sharedSecret as string | undefined;
  if (!channelId || !invitationId || !sharedSecret) return;

  // Idempotency: Unipile rejects re-accepting/re-ignoring a resolved
  // invitation, and Plot can re-fire onLinkUpdated for unrelated edits
  // (e.g. note changes) on the same link.
  const flagKey = `invitation_writeback:${invitationId}`;
  if (await this.get<string>(flagKey)) return;

  try {
    if (link.status === STATUS_ACCEPTED) {
      await this.tools.linkedin.acceptInvitation({
        channelId, invitationId, sharedSecret,
      });
    } else if (link.status === STATUS_IGNORED) {
      await this.tools.linkedin.ignoreInvitation({
        channelId, invitationId, sharedSecret,
      });
    } else {
      return; // pending or unknown — nothing to write back
    }
    await this.set(flagKey, link.status);
  } catch (error) {
    // Invitation may have been resolved out-of-band (e.g. accepted on
    // mobile). Log and stop retrying a stale invitation — the next sync
    // will reflect reality.
    console.warn(
      `LinkedIn invitation write-back failed (${invitationId}, ${link.status})`,
      error
    );
    await this.set(flagKey, link.status);
  }
}
```

Notes:
- `meta.channelId`, `meta.invitationId`, and `meta.sharedSecret` are all
  written into the invitation link by `buildInvitationLink`
  (`connectors/linkedin/src/linkedin.ts:431-437`), so they're available
  whenever `onLinkUpdated` fires for an invitation.
- `console.warn` (not PostHog) matches the existing convention in the
  connector and the user-memory rule that twists/connectors run sandboxed
  with no `captureException` access.
- The flag is keyed on `invitationId`, not link id, so even if the link is
  rebuilt from a later sync we still treat the invitation as written back.

### Sync interaction

Once accepted or ignored on LinkedIn, the invitation drops out of
`listReceivedInvitations`. `syncBatch`'s `lastInvitationHighWaterMs`
already filters by send time, so resolved invitations are not refetched.
The local link stays at its chosen terminal status — the correct end
state.

### Backwards compatibility

The connector is new and not in production. Existing invitation links
with `status: "archive"` should be rare or non-existent. We rename the
status key directly without a migration. If old `archive`-status
invitation links surface later, the UI will show the raw status string
until the user picks a new status; a one-line `onLinkUpdated` fixup can
be added then.

## Files touched

- `connectors/linkedin/src/linkedin.ts` — status constants, statuses
  array for the invitation link type, new `onLinkUpdated` override.

No changes to:
- `workers/api/src/twist/tools/unipile/*` (tool already exposes
  `acceptInvitation` / `ignoreInvitation`).
- `public/twister/src/` (no SDK type changes).
- Flutter app (statuses are surfaced generically from the link type
  config).

## Out of scope

- Migrating any existing `archive`-status invitation links.
- Tagging accepted invitations with `Tag.Done` or another thread tag.
- Surfacing a "View on LinkedIn" affordance distinct from the existing
  `sourceUrl` on the link.
- Outbound: sending new connection requests from Plot.
