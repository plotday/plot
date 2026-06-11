# `Connector.onContactsChanged` runtime dispatch — design

Date: 2026-06-10
Branch (core): `on-contacts-changed-dispatch`
Branch (public submodule): `feat/on-contacts-changed-dispatch`

## Problem

`Connector.onContactsChanged(thread, changes)` is declared in the SDK
(`public/twister/src/connector.ts`) with a default no-op, but **nothing in the
runtime ever calls it**. It is a dead callback: a connector that overrides it
would never be invoked when a user changes who a thread is shared with.

## Purpose (as clarified)

The callback exists to inform a connector when **thread-level sharing** is
changed inside the Plot app — i.e. when a user adds/removes a contact (or
changes a contact's role) on a thread the connector owns — so the connector can
reflect that membership change on the external service (e.g. add/remove a person
from a group DM, or rebuild an email's To/Cc/Bcc).

It is scoped to connectors with **thread-level sharing**
(`LinkTypeConfig.sharingModel: "thread"` — group DMs / multi-party chats) and
the email connector (`sharingModel: "message"`, To/Cc/Bcc). **Channel-level
sharing** (`sharingModel: "channel"`, e.g. adding someone to a Slack channel) is
explicitly out of scope.

## Connector audit (why this is plumbing today)

A full audit of every messaging connector found that **no connector can consume
this callback yet**:

| Connector | Group sharing | Can change membership on the external side? |
| --- | --- | --- |
| Slack (`dm`) | `sharingModel: "thread"` | No — `openConversation()` only; DM roster fixed at creation |
| Google Chat (`dm`) | `sharingModel: "thread"` | No — `createSpace()` with initial members; no member mutation API |
| MS Teams (`dm`) | `sharingModel: "thread"` | No member add/remove exposed in the Graph wrapper |
| WhatsApp / LinkedIn / Instagram | `sharingModel: "thread"` | No — shared Unipile `messaging.ts` interface has only `startChat()` |
| Gmail | `sharingModel: "message"`, declares `supportsContactChanges` | Open-roster, but **intentionally** does not override the callback — it rebuilds To/Cc/Bcc from current `thread.contacts × contact_meta` on the next outbound send |

**Conclusion:** every messaging platform has an immutable group roster, and Gmail
deliberately reads current state instead of reacting to the event. So this change
is **runtime plumbing**: make the callback fire correctly with an accurate diff so
it works the moment a connector gains a member add/remove API (which would require
extending, e.g., the Unipile messaging interface — a separate, larger effort).

This is built now (per decision) so the contract is ready; it ships unconsumed.

## Goals

- Fire `onContactsChanged(thread, changes)` on the connector that **owns** a
  thread whenever a user changes that thread's effective membership or a
  contact's role, from **any** endpoint that can make such a change.
- Compute an accurate diff: `added`, `removed`, `changed` (role transitions).
- Make the SDK role fields nullable, because thread-level (group-DM) sharing has
  no roles — only email has To/Cc/Bcc.

## Non-goals

- No connector is modified to consume the callback (none can).
- No external membership APIs (Unipile add/remove member, etc.).
- Channel-level sharing changes.
- No new DB view / migration: dispatch is direct (best-effort), mirroring the
  existing `onThreadToDo` connector path.

## Key domain facts

- `thread.contacts uuid[]` — everyone on the thread.
- `thread.dropped_contacts uuid[]` — subset of `contacts` soft-removed in
  message mode (retain visibility, excluded from the active recipient set).
- `thread.contact_meta jsonb` — `{ "<contactId>": { role?, addedBy? } }`.
- `thread.created_by uuid` — the user_id **or** twist_instance_id that created
  the thread. A connector-owned thread has `created_by` = the connector's
  twist_instance (which has `channel` rows).
- **Effective members** (what a connector cares about) =
  `contacts − dropped_contacts`, each with role `contact_meta[id].role ?? null`.

### Where membership changes enter the server

User edits in `apps/plot/lib/command/thread.dart` reach the server through **two**
endpoints, so the dispatch must live in both:

1. `POST /sync/threads` (`workers/api/src/app/sync/threads.ts` → `upsert_thread`)
   — non-message add/remove, message-mode **add**, and role changes (partial,
   additively-merged `contact_meta`).
2. `POST /thread/:id/share` (`workers/api/src/app/thread-share.ts`) — explicit
   add/remove/roleChanges, and message-mode **drop/undrop** (the only path that
   removes a member from a group-DM thread).

A version that watched only `/sync/threads` would fire on group-DM adds but
silently miss removals (drops). Hence: cover both.

## Architecture

### 1. Uniform snapshot + pure diff

Rather than translate each endpoint's request params, both call sites take a
**before/after snapshot** of `{ contacts, dropped_contacts, contact_meta }`
around their mutation and run one pure function:

```ts
type ContactsSnapshot = {
  contacts: string[];
  droppedContacts: string[];
  contactMeta: Record<string, { role?: string | null } | unknown>;
};

type ContactsDiff = {
  added: Array<{ contactId: string; role: string | null }>;
  removed: Array<{ contactId: string; role: string | null }>;
  changed: Array<{ contactId: string; from: string | null; to: string | null }>;
};

function computeContactsDiff(prev, next): ContactsDiff;
// effective(s) = Set(contacts) \ Set(dropped_contacts)
// role(s, id)  = contact_meta[id]?.role ?? null
// added   = effective(next) \ effective(prev)        → role from next
// removed = effective(prev) \ effective(next)        → role from prev
// changed = effective(prev) ∩ effective(next), role(prev) !== role(next)
```

Pure, dependency-free, trivially unit-testable. Resilient to partial
`contact_meta` payloads (we snapshot the *persisted* row, not the request) and to
any future mutation endpoint. Lives in a small module, e.g.
`workers/api/src/app/sync/contacts-diff.ts`.

### 2. Direct dispatch helper

`dispatchThreadContactsChanged(c, threadId, createdBy, diff)` —
mirrors the `onThreadToDo` direct dispatch in `schedules.ts`:

- No-op if `diff` is empty.
- In `c.executionCtx.waitUntil(...)`: open a fresh `createDb(c.env)`; confirm
  `createdBy` is a connector (`channel.twist_instance_id = createdBy` exists);
  build it via `twistFactory({ env, ctx, db })({ twistInstanceId: createdBy })`;
  call `twistWrapper.dispatch("Integrations", { itemType: "thread_contacts",
  item: { thread_id, ...diff } })`; `db.destroy()` in `finally`; never throw into
  the request (log + best-effort, matching the sibling pattern).

Lives alongside the diff helper (or in `thread-share.ts`'s neighbourhood) and is
imported by both endpoints.

### 3. `Integrations.dispatch()` handler

New branch in `workers/api/src/twist/tools/integrations.ts` for
`itemType === "thread_contacts"` (gated on `this.sourceProvider`, like the
`thread_schedule` / `schedule_contact` handlers):

- Require a `link` with `created_by = this.twistInstanceId` on `item.thread_id`;
  return `[]` otherwise.
- Build `thread` (`id`, `title`, `archived`, `meta` from the link row).
- Resolve every contactId referenced in `added/removed/changed` to an SDK
  `Contact` (`{ id, email, name }`) via a single `contact` table query.
- Return `[{ sourceMethod: "onContactsChanged", args: [thread, changes] }]`,
  where `changes` carries resolved `Contact` objects and the diff's roles.

`entrypoint.ts` already invokes `twist[sourceMethod](...args)` generically for
the `{ sourceMethod, args }` shape (same as `onThreadToDo` /
`onScheduleContactUpdated`), so **no entrypoint change is needed**.

### 4. SDK signature (public submodule)

`public/twister/src/connector.ts` `onContactsChanged`:

```ts
onContactsChanged(
  thread: Thread,
  changes: {
    added: Array<{ contact: Contact; role: string | null }>;
    removed: Array<{ contact: Contact; role: string | null }>;
    changed: Array<{ contact: Contact; from: string | null; to: string | null }>;
  },
): Promise<void>;
```

Roles become nullable (group-DM membership has no role). JSDoc updated to lead
with the thread-level-sharing/group-DM use case and note roles are email-specific.
Requires a changeset (`@plotday/twister` `minor`, `Changed:`), `pnpm build`, and a
separate public PR.

## Data flow (group-DM remove example)

1. User drops a member on a message-mode thread → client `POST /thread/:id/share`
   with `drop: [contactId]`.
2. `thread-share.ts` snapshots the thread, runs `update_thread_dropped_contacts`,
   snapshots again.
3. `computeContactsDiff` → `removed: [{ contactId, role: null }]`.
4. `dispatchThreadContactsChanged` sees `created_by` is a connector → `waitUntil`
   builds it and calls `Integrations.dispatch({ itemType: "thread_contacts", … })`.
5. Handler resolves the `Contact`, returns `onContactsChanged` →
   `entrypoint.ts` calls the connector's method (no-op today).

## Edge cases

- **Empty diff** (no membership/role change, e.g. a thread re-save): no dispatch.
- **Non-connector thread** (`created_by` is a user): no dispatch.
- **Partial `contact_meta`**: handled — we diff persisted snapshots, not requests.
- **`dropped_contacts` invariant** (⊆ `contacts`): effective-set subtraction is
  safe even if violated.
- **Self/own contact**: included if present in `contacts`; the connector decides
  relevance.
- **Request-scoped DB after response**: the helper opens its own `createDb`
  inside `waitUntil` and destroys it in `finally` (never uses `c.var.db` there).

## Testing

- **Unit** (`contacts-diff.test.ts`): add, remove, role change, drop=remove,
  undrop=add, no-op, simultaneous add+remove+role-change, absent-role → null.
- **Dispatch** (integration-style, fake recording connector): `POST /sync/threads`
  (add + role change) and `POST /thread/:id/share` (drop) each invoke
  `onContactsChanged` once with the expected `changes`; a user-owned (non-connector)
  thread does not dispatch.

## Files

- `public/twister/src/connector.ts` — nullable roles + JSDoc (submodule).
- `public/.changeset/<name>.md` — changeset (submodule).
- `workers/api/src/app/sync/contacts-diff.ts` — `computeContactsDiff` + dispatch helper (new).
- `workers/api/src/app/sync/contacts-diff.test.ts` — unit tests (new).
- `workers/api/src/twist/tools/integrations.ts` — `thread_contacts` handler.
- `workers/api/src/app/sync/threads.ts` — snapshot + dispatch around `upsert_thread`.
- `workers/api/src/app/thread-share.ts` — snapshot + dispatch around share mutations.
- dispatch test file (new).

## Out of scope / follow-ups

- Extending Unipile (`addMember`/`removeMember`) and wiring a real consumer.
- Channel-level sharing changes.
- A durable seq-view dispatch path (only if real-time reliability is later needed).
