# Unipile Account Cleanup & Safety — Design

**Date:** 2026-06-03
**Status:** Approved (brainstorming) → ready for implementation plan
**Scope:** API worker only. No schema changes, no Twister/SDK changes, no public submodule.

## Problem

Unipile bills per connected account. In testing we accumulated **8 Unipile
accounts for a single LinkedIn identity** because:

1. **Teardown never deletes the Unipile account.** Removing a connection or
   removing/archiving the LinkedIn connector clears Plot's stored token and
   archives the `twist_instance`, but the Unipile account keeps existing (and
   keeps billing).
2. **Every reconnect mints a fresh account.** `/auth/hosted/success` completes
   a new hosted-auth flow, which creates a brand-new Unipile `account_id` each
   time. The old accounts are orphaned.
3. **Dev DB resets strand accounts.** Wiping the local database without first
   archiving connections removes every Plot-side reference, so the Unipile
   accounts can never be matched back and cleaned up from our data alone.

### Relevant facts about the current code

- The Unipile `account_id` is the LinkedIn **channel id**. It is stored as the
  auth token's `access_token` (`auth_token:<provider>:<actorId>` in the
  connector's DO store) and mirrored into the relational `channel` table as
  `channel.channel_id`.
- `UnipileClient` already has `getAccount(id)` and `deleteAccount(id)`. There is
  **no** `listAccounts()` yet.
- The LinkedIn identity (LinkedIn member id) is available as
  `UnipileAccount.connection_params.im.id`, and at auth-completion time as
  `profile.provider_id` (from `getOwnProfile`).
- Hosted-auth providers are identified by
  `PROVIDER_CONFIGS[provider].authMode === "hosted"` (LinkedIn today;
  WhatsApp/Instagram in future).
- Two teardown paths exist, both leak today:
  - `Integrations.removeAuth(provider, actorId)` — per-account "remove
    connection" (`DELETE /twist/:id/integrations/:provider/:actorId`). Clears
    the token; never deletes the Unipile account.
  - Connector removal via `deactivate()` (`DELETE /twist/:id` →
    `management.ts remove()`): disables channels, archives the
    `twist_instance`; never deletes the Unipile account.

## Goals

- Delete the Unipile account whenever a connection is genuinely torn down.
- Make a fresh connect self-heal: clean up any orphaned accounts for the same
  LinkedIn identity, including after a dev DB reset.
- Never let cleanup failures break a teardown or an auth completion.

## Non-goals (explicitly out of scope)

- **Scheduled reaper cron** that sweeps all unreferenced accounts. Considered;
  not selected. Flow B (connect-time sweep) is the chosen safety net.
- **Dev cleanup CLI script.** Considered; not selected.
- Deleting accounts on a plain **channel disable**. For single-channel LinkedIn
  the token survives a disable so the user can re-enable without re-auth (and
  without minting a new account). Deletion only happens on real teardown.

## Design

### Shared building blocks

1. **`UnipileClient.listAccounts()`** — wraps Unipile `GET /accounts`. Cursor
   loop (account counts per workspace are tiny, but paginate defensively).
   Returns `UnipileAccount[]`. Each item must expose `id` and the LinkedIn
   identity (`connection_params.im.id`). If the list endpoint returns a leaner
   shape that omits `connection_params`, fall back to `getAccount(id)` per
   listed account to read the identity (cheap given small N). This fallback is
   an implementation detail to verify against the live API.

2. **`deleteUnipileAccount(env, accountId)`** — single best-effort helper
   (new module `workers/api/src/twist/tools/unipile/account-cleanup.ts`), used
   by every deletion path. Calls `UnipileClient.deleteAccount`, treats `404`
   as already-gone (success), logs the outcome, and routes unexpected failures
   to `captureException`. **Never throws** — cleanup must never block a teardown
   or an auth completion.

### Flow A — delete on teardown

- **`Integrations.removeAuth(provider, actorId)`** — for hosted-auth providers
  only: read the `account_id` from the stored token **before** clearing it,
  then after the token is cleared call `deleteUnipileAccount`, **guarded** so we
  only delete when no other live hosted token still references that same
  `account_id`. This protects the channel-reassignment branch
  (`findAlternateOwner`); for personal hosted accounts (1:1 actor↔account) the
  guard always resolves to "delete".

- **Connector removal (whole twist)** — the two removal routes
  (`DELETE /twist/:id` → `deleteTwist`, `DELETE /twist/:id/archive-activities`
  → `archiveAndDeleteTwist`) call those functions **without** the `deactivate`
  factory, so `deactivate()` / `preDeactivate` do **not** run on removal
  (verified). Rather than broadly enabling the deactivate lifecycle (which would
  change behavior for every connector), the routes fire a **best-effort
  background** cleanup (`c.executionCtx.waitUntil`, fresh `createDb` connection):
  load the twist's providers from `TWIST_CONFIG` KV, and if any provider is
  hosted (`PROVIDER_CONFIGS[p].authMode === "hosted"`), delete every
  `channel.channel_id` for the instance — for hosted connectors the
  `channel_id` **is** the Unipile `account_id`. The twist_instance is only
  soft-archived (`archived_at`), so `channel` rows still exist when this runs.
  Flow B is the backstop either way.

### Flow B — orphan sweep on connect (dev-reset & double-connect safety)

In `/auth/hosted/success`, after `onAuth` completes we already know the new
`account_id` and the LinkedIn identity (`profile.provider_id`). Then, **in the
background** via `c.executionCtx.waitUntil(...)` using a **fresh DB connection**
(`createDb(c.env)` opened and `destroy()`-ed inside the task — never reuse
`c.var.db` inside `waitUntil`):

1. `listAccounts()` → select every account whose LinkedIn identity matches the
   just-connected identity **and** whose `id !== newAccountId`.
2. Delete each via `deleteUnipileAccount`, **unless** it is still referenced by
   an **enabled** `channel` row under a **non-archived** `twist_instance` (one
   cheap SQL query). This guard protects the rare case of two distinct Plot
   users on the same LinkedIn login. In a dev post-reset DB no such rows exist,
   so every stale same-identity account is swept.

Why this covers the DB-reset case: identity matching reads Unipile directly
(`listAccounts`), not Plot's data, so it works even when every Plot-side
reference was wiped. The new account is protected by the explicit
`id !== newAccountId` exclusion (it has no `channel` row yet at sweep time,
since enabling happens after auth completes).

### Error handling

Every Unipile call in both flows is best-effort: failures are logged and sent to
`captureException`, never surfaced to the user, never abort the primary
operation (token removal, twist archival, or the auth-completion redirect).

## Testing

Unit tests under `workers/api/src/twist/tools/unipile/` (alongside the existing
`client.test.ts`):

- `listAccounts` — response parsing and cursor pagination; identity fallback via
  `getAccount` when `connection_params` is absent on list items.
- `removeAuth` — deletes the Unipile account for a hosted provider; **skips**
  deletion when another live hosted token still references the same
  `account_id`; no-ops for non-hosted providers.
- Connect-time sweep — selects the correct deletion set (same identity,
  excluding the new account) and respects the live-channel guard (does not
  delete an account referenced by an enabled channel under a non-archived
  twist_instance).

## Files touched

- `workers/api/src/twist/tools/unipile/client.ts` — add `listAccounts()`.
- `workers/api/src/twist/tools/unipile/types.ts` — list-response shape if needed.
- `workers/api/src/twist/tools/unipile/account-cleanup.ts` — **new** helper + test.
- `workers/api/src/twist/tools/integrations.ts` — `removeAuth` deletion + guard.
- `workers/api/src/app/authBridge.ts` — background connect-time orphan sweep.
- `workers/api/src/app/twists.ts` — background hosted-account cleanup on the
  `DELETE /twist/:id` and `/archive-activities` removal routes.

## Open implementation questions (resolve during build, not blocking)

1. Does Unipile `GET /accounts` include `connection_params.im.id` on list items,
   or is the per-account `getAccount` fallback required? Plan handles both.

_(Resolved during planning: `preDeactivate` is **not** dispatched on the removal
routes, so connector-removal cleanup lives at the routes in `twists.ts`, not in
a lifecycle hook.)_
