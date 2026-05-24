# LinkedIn relations backfill — design

**Date:** 2026-05-24
**Branch:** `linkedin-unipile`
**Status:** approved, ready for implementation plan

## Goal

After enabling a LinkedIn connection, sync the user's full list of
1st-degree LinkedIn relations (connections) into Plot's contact store
so Plot's compose UI can offer them as recipients when starting a new
DM.

Pacing must stay within Unipile's documented safe envelope for
LinkedIn so we don't trigger account restrictions.

## Non-goals

- Per-relation profile fan-out (no extra "fetch full profile" call
  per relation). The relations list endpoint already returns enough
  to populate a contact.
- Creating a `link`/`thread` per relation. Relations populate the
  `contact` table only.
- Flutter compose UI changes. If Plot's recipient picker today only
  shows contacts that already have a thread, the small change to
  also show threadless contacts is a follow-up — out of scope here.
- Starting a brand-new LinkedIn chat from Plot. The Unipile call to
  open a new chat (`POST /chats`) is not yet wrapped. Out of scope.
- New webhook source registration. We already subscribe to the
  `users` webhook source for invitations; we extend its handler.

## Why these scope cuts

- The user said "we only need enough to be able to list contacts for
  sending a new DM" — listing is what this delivers. Compose UX and
  new-chat creation are independent and can be designed once we know
  the listing surface works end-to-end.
- Per-relation profile fetches would burn the documented ~100/day
  LinkedIn profile-retrieval ceiling within hours of starting a
  backfill for a normal-sized network. The list endpoint avoids
  that.

## Background

Unipile exposes `GET /users/relations?account_id=…` which returns the
connected LinkedIn account's full 1st-degree connections, paginated.
The Node SDK calls this `client.users.getAllRelations({ account_id })`.

Unipile's own provider-limits guidance says:

- Profile retrieval: ~100/day safe ceiling per account.
- Other actions: ~100/day combined.
- For initial relations sync: "retrieve the first page only a few
  times a day with randomly spaced intervals of several hours."
- Fixed-interval polling (every hour, 08:00 daily, etc.) is the #1
  detection signal — avoid.
- For going-forward additions, Unipile recommends the `users`
  webhook's `new_relation` event over polling. Unipile internally
  polls the relations list at randomized intervals to back the
  webhook.

The existing LinkedIn connector already keys 1:1 chats and
invitations by `linkedin:person:<profile-id>` via `source` /
`relatedSource`, and the contact-side dedup in
`workers/api/src/twist/tools/plot/contacts.ts` upserts on
`contact_external_account (provider, account_id)`. That means
contacts saved during relations backfill will be re-used when a chat
or invitation for that same person later arrives — no duplicate
contact rows.

## Architecture

Three layers, each isolated:

### 1. `UnipileClient` — HTTP wrapper

File: `workers/api/src/twist/tools/unipile/client.ts`

Add one method that mirrors `listChats`/`listMessages`:

```ts
listRelations(input: {
  accountId: string;
  cursor?: string | null;
  limit?: number;
}): Promise<UnipileRelationList>
```

Wraps `GET /users/relations?account_id=…&cursor=…&limit=…`.

New types in `workers/api/src/twist/tools/unipile/types.ts`:

- `UnipileRelation` — typed against the actual Unipile response.
  Likely an `Attendee`-shaped object; if so, alias to
  `UnipileAttendee` rather than duplicate.
- `UnipileRelationList = { object: "RelationList"; items:
  UnipileRelation[]; cursor: string | null }`.

### 2. `LinkedInMessaging` built-in tool

Interface: `libs/unipile/src/linkedin.ts`
Impl: `workers/api/src/twist/tools/unipile/linkedin.ts`

Add:

```ts
abstract listRelations(params: {
  channelId: string;
  cursor?: string | null;
  limit?: number;
}): Promise<LinkedInRelationPage>
```

Returns Plot-shaped, reusing the existing `LinkedInProfile`:

```ts
export type LinkedInRelationPage = {
  relations: LinkedInProfile[];
  nextCursor: string | null;
};
```

`normalize.ts` gets a `normalizeRelation()` that returns
`LinkedInProfile`. If the relation payload is `Attendee`-shaped, this
is `normalizeProfile` reused. Otherwise it's a small adapter.

The impl runs the same `assertAccount(channelId)` precondition as
every other method on this tool.

### 3. `LinkedIn` connector

File: `connectors/linkedin/src/linkedin.ts`

Three additions:

1. New state shape, persisted via `this.set`/`this.get`:

   ```ts
   type RelationsSyncState = {
     cursor: string | null;          // null = next call fetches page 1
     completed: boolean;             // true once nextCursor === null
     lastCompletedAt: number | null; // ms epoch of last full pass
     lastPageAt: number;             // last successful page (for diagnostics)
   };
   ```

2. New scheduled task method `syncRelationsPage(channelId: string)`.
   Decoupled from `syncBatch` so the existing chat/invitation cadence
   is unaffected.

3. New scheduled task method `refreshRelationsList(channelId: string)`
   that rearms the backfill state after a completed pass.

In `onChannelEnabled`, after kicking off `syncBatch`, initialize
relations state and schedule the first `syncRelationsPage` with
`runAt: now` (no jitter on the very first call — see "Dev
ergonomics" below).

In `onChannelDisabled`, clear `relations_state_${channel.id}`
alongside the existing keys.

## Sync orchestration

### Backfill loop — `syncRelationsPage(channelId)`

1. Read `relations_state_${channelId}` (default to fresh state if
   absent).
2. If `state.completed === true`, return without rescheduling. The
   periodic refresh task is what un-completes it later.
3. Call `this.tools.linkedin.listRelations({ channelId, cursor:
   state.cursor, limit: 100 })`.
4. Map each `LinkedInProfile` to `NewContact` via the existing
   `profileToContact()` helper at
   `connectors/linkedin/src/linkedin.ts`. This already handles
   `email` → `publicIdentifier@linkedin.invalid` fallback, name,
   avatar, and `source: { provider: AuthProvider.LinkedIn,
   accountId: profile.id }`.
5. `await this.tools.integrations.saveContacts(contacts)`.
6. Write new state:
   - `cursor = result.nextCursor`
   - `completed = result.nextCursor === null`
   - `lastCompletedAt = completed ? Date.now() : state.lastCompletedAt`
   - `lastPageAt = Date.now()`
7. If `!completed`, schedule the next call with a jittered delay
   uniformly in `[2h, 4h]`:
   ```ts
   const HOUR = 60 * 60 * 1000;
   const delayMs = 2 * HOUR + Math.random() * 2 * HOUR;
   const next = await this.callback(this.syncRelationsPage, channelId);
   await this.runTask(next, { runAt: new Date(Date.now() + delayMs) });
   ```
   No jitter helper is introduced — single call site.
8. If `completed`, schedule `refreshRelationsList(channelId)` with
   jittered delay in `[18h, 30h]`.

### Refresh loop — `refreshRelationsList(channelId)`

1. Reset state: `cursor = null`, `completed = false`,
   `lastCompletedAt` unchanged.
2. Schedule `syncRelationsPage(channelId)` immediately (`runAt: now`).
   The page-1 fetch is the only LinkedIn call this turn does.

### Webhook for going-forward additions

`onWebhookEvent` already handles a discriminated-union event arg
(`message.received`, `invitation.received`). Add a third branch:

```ts
| { kind: "relation.new"; profileId: string }
```

Handler:

1. `const attendee = await this.tools.linkedin.getAttendee?.(...)` —
   the tool currently exposes `getAttendee` on the underlying
   `UnipileClient` but not yet through `LinkedInMessaging`. Add a
   thin `getProfile({ channelId, profileId })` method on
   `LinkedInMessaging` that wraps `client.getAttendee` and returns a
   normalized `LinkedInProfile`.
2. Map to `NewContact` via `profileToContact()`.
3. `saveContacts([contact])`.

The translation from raw Unipile `users.new_relation` event to our
shape lives in whichever file already translates `users.*` events
for invitations (the existing webhook plumbing — exact file located
during implementation). No new webhook source is registered; the
`users` source is already subscribed.

### Why this is rate-safe

- Backfill pages every 2–4h with full uniform jitter. A 5k-connection
  account at 100/page → ~50 pages → ~6 days median. Matches Unipile's
  "first page only a few times a day at random intervals" guidance.
- Refresh re-arms once per 18–30h. No fixed clock-time triggers
  anywhere.
- Only the *list* endpoint is hit during backfill. No per-relation
  profile fetches → the documented ~100/day profile-retrieval ceiling
  is untouched. The webhook's `getProfile` lookups are at most a
  handful per day for normal account activity.
- Once `completed`, no relations-endpoint calls happen until the
  refresh task fires.

## Failure handling

- `UnipileApiError` from `listRelations`: do NOT advance the cursor.
  Reschedule the same page with a longer backoff window — `[4h, 8h]`
  — so we don't immediately retry into the same rate-limited window.
  Log via `console.warn` / `console.error` (twist runtime has no
  PostHog access; see project convention in CLAUDE.md).
- `saveContacts` failure: let it throw. The twist runtime's task
  machinery handles retry; cursor stays put so we don't lose
  relations on a transient DB hiccup.
- Webhook handler failure (e.g. `getProfile` 404 because the profile
  was deactivated between event and lookup): log and swallow. A
  later refresh pass will catch it if it reappears.

## Dev ergonomics

The very first `syncRelationsPage` after `onChannelEnabled` runs
immediately (`runAt: now`), not jittered. Reasoning: a fresh local
enable shouldn't wait 2–4 hours before doing anything visible. One
immediate page is also what a real user produces on first connect —
no different from the safety standpoint.

Implementation: in `onChannelEnabled`, schedule the first
`syncRelationsPage` with `runAt: new Date()`. Subsequent reschedules
inside `syncRelationsPage` itself are always jittered.

## Testing

Unit tests:

- `workers/api/src/twist/tools/unipile/normalize.test.ts` — add cases
  for `normalizeRelation` (or `normalizeProfile` against a relation
  payload) covering:
  1. Relation with `specifics.public_identifier` + `specifics.headline`.
  2. Relation missing `public_identifier` (restricted profile).
  3. Relation with no `specifics`.
- `workers/api/src/twist/tools/unipile/client.test.ts` — add a
  `listRelations` test that asserts request path/query
  (`/users/relations?account_id=…`) and parses a paginated response.
  Mirror the existing `listChats` test.

Connector tests: none added. `connectors/linkedin/` has no test
harness today and introducing one would dwarf the feature. The
connector's new code is a straight pipeline (state-read → tool call
→ map → `saveContacts` → state-write → reschedule-or-stop); the only
branch is `nextCursor === null`.

Manual verification plan (executed during implementation):

1. Enable the LinkedIn channel locally against a Unipile sandbox.
2. Confirm one page lands in `contact` + `contact_external_account`
   with `(LinkedIn, <profile-id>)`.
3. Re-run `syncRelationsPage`; confirm cursor advances.
4. Force `nextCursor = null`; confirm task stops rescheduling, sets
   `completed = true`, and schedules a refresh.
5. Receive a chat message from that user on LinkedIn; confirm the
   chat link reuses the existing contact (no duplicate
   `contact_external_account` row).

## Files touched

- `workers/api/src/twist/tools/unipile/types.ts` — new
  `UnipileRelation` + `UnipileRelationList`.
- `workers/api/src/twist/tools/unipile/client.ts` — new
  `listRelations()`.
- `workers/api/src/twist/tools/unipile/client.test.ts` — new test.
- `workers/api/src/twist/tools/unipile/normalize.ts` — new
  `normalizeRelation()` (or reuse `normalizeProfile`).
- `workers/api/src/twist/tools/unipile/normalize.test.ts` — new
  cases.
- `workers/api/src/twist/tools/unipile/linkedin.ts` — implement
  `listRelations` + `getProfile`.
- `libs/unipile/src/linkedin.ts` — abstract `listRelations` +
  `getProfile`; export `LinkedInRelationPage`.
- `libs/unipile/src/types.ts` — `LinkedInRelationPage` type.
- `libs/unipile/src/index.ts` — re-export new types if needed.
- `connectors/linkedin/src/linkedin.ts` — new state shape, new
  `syncRelationsPage` + `refreshRelationsList` methods, scheduling
  hooks in `onChannelEnabled`/`onChannelDisabled`, new
  `relation.new` webhook event branch.
- Wherever the existing `users.*` webhook payload is translated for
  the connector (located during implementation) — add
  `new_relation` → `{ kind: "relation.new", profileId }`.

No schema changes, no migrations, no Flutter changes.

## Out of scope follow-ups to track

1. **Compose UI surfacing threadless contacts.** Verify during
   implementation; if Plot's recipient picker only shows contacts
   with a thread today, file a small follow-up for the Flutter
   change.
2. **`POST /chats` wrapper.** Required to actually start a brand-new
   LinkedIn DM from Plot. Needs its own design once compose is
   wired.
