# LinkedIn: unify connection requests and DMs

## Problem

Incoming LinkedIn connection requests sync into Plot as `invitation` links;
direct messages sync as `message` links. They're disjoint — even though a
connection request from someone is followed (after acceptance) by a 1:1 DM
thread with that same person, Plot shows two unrelated threads.

In practice users want to act on a connection request and start messaging
in the same place. Acting also needs to reach LinkedIn — today, status
changes on the invitation link only hide things locally; the request stays
pending on LinkedIn.

## Goal

One thread per LinkedIn person (for 1:1 conversations). It carries
whatever lifecycle state applies — invitation pending, accepted with
messages, ignored, archived. Status changes write back to LinkedIn where
meaningful. Group chats stay separate (they have no single profile to
unify on).

## Design

### Two link types

In `connectors/linkedin/src/linkedin.ts`:

```typescript
const TYPE_CONVERSATION = "conversation"; // 1:1 (and invitations)
const TYPE_GROUP        = "group";        // group chats

const STATUS_PENDING  = "pending";
const STATUS_INBOX    = "inbox";
const STATUS_ARCHIVED = "archived";
const STATUS_IGNORED  = "ignored";

linkTypes = [
  {
    type: TYPE_CONVERSATION,
    label: "LinkedIn conversation",
    logo: "https://api.iconify.design/logos/linkedin-icon.svg",
    logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
    statuses: [
      { status: STATUS_PENDING,  label: "Pending"   },
      { status: STATUS_INBOX,    label: "Connected" },
      { status: STATUS_ARCHIVED, label: "Archived",  done: true },
      { status: STATUS_IGNORED,  label: "Ignored",   done: true },
    ],
  },
  {
    type: TYPE_GROUP,
    label: "LinkedIn group",
    logo: "https://api.iconify.design/logos/linkedin-icon.svg",
    logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
    statuses: [
      { status: STATUS_INBOX,    label: "Inbox"    },
      { status: STATUS_ARCHIVED, label: "Archived", done: true },
    ],
  },
];
```

The old `TYPE_MESSAGE` / `TYPE_INVITATION` constants go away.

### Link identity

Conversation links use the LinkedIn person id as their stable source key:

- **`source`**: `linkedin:person:{profileId}` (the canonical identifier)
- **`sources`**: also include `linkedin:chat:{chatId}` and/or
  `linkedin:invitation:{invitationId}` when known, so multi-source matching
  resolves either origin to the same link

Group links keep the existing chat-id keying:

- **`source`**: `linkedin:chat:{chatId}`

### Meta merging (schema change)

Today, `user.upsert_link` (`libs/db/schema/90-user-schema/80-upsert_link.sql:211-215`)
replaces `meta` wholesale whenever the upsert payload includes a `meta`
key. That breaks the unified-link approach: the chat sync would nuke the
invitation's `sharedSecret`, and vice versa.

Change `upsert_link` to **shallow-merge** the incoming `meta` into the
existing row:

```sql
meta = CASE WHEN p_link ? 'meta' THEN
    COALESCE(link.meta, '{}'::jsonb) || (p_link -> 'meta')
ELSE
    link.meta
END,
```

This is the standard JSONB `||` operator — top-level keys from the new
object replace existing same-named keys; existing keys not in the new
object are preserved.

**Backwards compatibility check.** I scanned every existing connector
(Apple Calendar, Attio, Asana, Gmail, GitHub, Fellow, Airtable, Slack,
Linear, Jira, etc.). All of them write a fixed-shape `meta` on every
save — none rely on "omit a key to clear it" semantics. Shallow merge
produces an identical final row for all current callers; only the new
multi-source LinkedIn pattern exercises the merge behavior.

A caller that genuinely wants to clear a meta key under merge semantics
can pass `{key: null}` (sets to JSON null, not absent — fine for our
purposes). Hard-deleting a key isn't supported; YAGNI.

With merge in place, `link.meta` becomes the single home for per-person
bookkeeping. No connector-side KV needed:

```typescript
link.meta = {
  syncProvider: "linkedin",
  channelId,
  profileId,
  // added by invitation sync:
  invitationId?: string,
  sharedSecret?: string,
  // added by chat sync (1:1):
  chatId?: string,
};
```

Invitation sync writes `{profileId, invitationId, sharedSecret, …}`.
Chat sync writes `{profileId, chatId, …}`. The merge combines them.
Either sync running second adds its keys without dropping the other's.

### Title and preview

- 1:1 conversation title: `profile.fullName` (drop the "Connection
  request from" prefix).
- Group title: `chat.title || joinParticipantNames(others)` (unchanged
  logic).
- Preview: prefer `chat.lastMessagePreview` if a chat exists, fall back
  to `invitation.message || inviter.headline`.

### Sync

Drop the `OPTIONS_SCHEMA` options entirely — `importMessages` and
`importInvitations` both become unconditional. The full options export
is removed and `build(Options, ...)` is dropped from `build()`. The
sync-state shape stays the same (watermarks per source).

`syncBatch` keeps two passes (invitations, then chats):

1. **Invitations.** For each `inv`, write a conversation link keyed on
   `inv.inviter.id`, with `status: STATUS_PENDING`, sources
   `[linkedin:person:{inviter.id}, linkedin:invitation:{inv.id}]`, and
   `meta: { syncProvider, channelId, profileId, invitationId,
   sharedSecret }`. Notes get the invitation message authored by the
   inviter.

2. **Chats.** For each `chat`:
   - **1:1**: pick the other participant; write a conversation link
     keyed on that participant id with `status: STATUS_INBOX`, sources
     `[linkedin:person:{other.id}, linkedin:chat:{chat.id}]`, and
     `meta: { syncProvider, channelId, profileId, chatId }`. Notes get
     every message.
   - **Group**: write a group link keyed on chat id with
     `status: STATUS_INBOX` and `meta: { syncProvider, channelId,
     chatId }`. Current logic.

Status precedence when both shapes exist for the same person: the chat
overrides (a 1:1 chat only exists once the invitation has been
accepted on LinkedIn, so showing Pending after that is wrong). Concretely,
if the chat sync runs after the invitation sync, the second `saveLink`
flips status to `STATUS_INBOX`.

### Write-back via `onLinkUpdated`

```typescript
override async onLinkUpdated(link: Link): Promise<void> {
  if (link.type !== TYPE_CONVERSATION) return;

  const meta = (link.meta ?? {}) as Record<string, unknown>;
  const channelId    = meta.channelId    as string | undefined;
  const invitationId = meta.invitationId as string | undefined;
  const sharedSecret = meta.sharedSecret as string | undefined;
  if (!channelId) return;
  if (!invitationId || !sharedSecret) return; // no invitation to act on

  // Idempotency: each invitation can only be accepted/ignored once.
  const flagKey = `invitation_writeback:${invitationId}`;
  if (await this.get<string>(flagKey)) return;

  const status = link.status;

  // Map Plot status to LinkedIn action. Archived from Pending is
  // treated as Ignore on LinkedIn (user wants this off their plate);
  // the local status stays Archived per their click.
  let action: "accept" | "ignore" | null = null;
  if (status === STATUS_INBOX)         action = "accept";
  else if (status === STATUS_IGNORED)  action = "ignore";
  else if (status === STATUS_ARCHIVED) action = "ignore";
  if (!action) return; // STATUS_PENDING — nothing to do

  try {
    if (action === "accept") {
      await this.tools.linkedin.acceptInvitation({
        channelId, invitationId, sharedSecret,
      });
    } else {
      await this.tools.linkedin.ignoreInvitation({
        channelId, invitationId, sharedSecret,
      });
    }
    await this.set(flagKey, action);
  } catch (error) {
    // Invitation may have been resolved out-of-band; stop retrying.
    console.warn(
      `LinkedIn invitation write-back failed (${invitationId}, ${action})`,
      error
    );
    await this.set(flagKey, action);
  }
}
```

Status semantics summary:

| Local status   | LinkedIn action (Pending → here) | After flag set |
| -------------- | -------------------------------- | -------------- |
| `pending`      | —                                | —              |
| `inbox`        | `acceptInvitation`               | local only     |
| `archived`     | `ignoreInvitation` *             | local only     |
| `ignored`      | `ignoreInvitation`               | local only     |

\* User picked "Archived" but the only LinkedIn-side action that
"removes" a pending invitation is ignore. Local label stays Archived
(matches what they clicked); write-back fires once. After the flag is
set, later Connected ↔ Archived flips are local only.

The status key on the conversation type stays `inbox` for code-level
consistency with the group type and the rest of Plot's conventions —
only the user-facing label differs.

For conversations that started as chats (no invitation ever existed),
`invitationId` is absent from `link.meta`; `onLinkUpdated` returns
early and Inbox/Archived behave as local-only state, matching today's
message behavior.

### Existing local test data

There's one local test connection with invitation/message data already
synced. Nothing's deployed and no migration burden — disable +
re-enable the LinkedIn channel after these changes ship to re-run
initial sync and overwrite everything in the new shape.

## Files touched

- `libs/db/schema/90-user-schema/80-upsert_link.sql` — switch the
  `meta` CASE branch from wholesale replace to `link.meta || (p_link ->
  'meta')` shallow merge.
- `libs/db/migrations/<timestamp>_link_meta_shallow_merge.sql` —
  generated via `pnpm gen-migration -- link_meta_shallow_merge`. Just
  the `CREATE OR REPLACE FUNCTION upsert_link` rebuild.
- `connectors/linkedin/src/linkedin.ts` — link types, status
  constants, identity keying, `syncBatch` rewrite (drop options,
  switch to person-id keying for 1:1), `onLinkUpdated` override,
  removal of `Options` tool and `OPTIONS_SCHEMA`.

No SDK / type changes (`public/twister/src/`) or Flutter changes.

## Open questions

1. **Status precedence on second write.** `upsert_link` always writes
   `status` when present in the payload (`80-upsert_link.sql:201-205`).
   So when chat sync runs after invitation sync for the same person, the
   chat-side `STATUS_INBOX` will override `STATUS_PENDING` as intended.
   But this also means a manual `STATUS_IGNORED` could be re-flipped to
   `STATUS_INBOX` by a subsequent chat sync — unlikely (ignored
   invitations don't generate chats) but worth confirming in
   implementation. May want to omit `status` from chat-sync upserts when
   the link already exists, or only set it on the initial insert.

## Out of scope

- Outbound: sending new connection requests from Plot.
- Auto-archiving the local thread on LinkedIn (no `setChatRead` /
  archive write-back for the message side — chat archive stays local
  only).
- Surfacing connection state visually beyond the status itself.
