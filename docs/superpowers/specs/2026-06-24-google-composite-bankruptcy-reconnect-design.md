# Google Composite — Bankruptcy via Per-Account Reconnect (Design)

_2026-06-24. Refines the Phase-6 "bankruptcy" step of the Google composite-connection cutover. Supersedes
the "re-add prompt (banner)" idea and the "channel carry-over" idea explored earlier. Pairs with the cutover
runbook: `docs/superpowers/plans/2026-06-24-google-composite-cutover-runbook.md`._

## Goal

When the cutover replaces the three legacy Google connectors (Gmail / Calendar / Tasks) with the one combined
**"Google Mail, Calendar, and Tasks"** connector, each affected user should — with **one re-auth per Google
account** — end up with their Google data syncing again through the combined connector, with the owned/default
channels enabled exactly as a brand-new connection would have them.

Instead of a bespoke "reconnect" banner, the bankruptcy **provisions a combined connection per Google account
in a needs-auth state**, so it surfaces through Plot's existing "Reconnect" UX. Reconnecting is treated like a
fresh connect: granting scopes auto-enables the owned/default channels.

## Why this approach

- **Reuses existing UX, no new Flutter.** A `twist_instance_connection` with `needs_reauth_at` set already
  renders as the red "Reconnect X" sidebar tile + a reconnect affordance in Connections, and the composite
  re-auth widget already drives the OAuth (pre-filling the account via `accountHint → login_hint`). Pre-created
  needs-auth instances flow through all of it unchanged.
- **Per-account granularity** (the user's requirement): a user with personal Gmail+Calendar and a work Gmail
  sees **two** "Reconnect Google" connections (one per account), each independently reconnectable or
  archivable.
- **"Fresh-connect" channel behavior, no carry-over.** Rather than copying + namespace-translating the old
  channel selections, reconnect enables the owned (`enabledByDefault`) channels — the same set a new user gets
  — keeping the migration simple and the result predictable.
- **No pre-reconnect billing.** Connection limits count only instances with ≥1 enabled channel
  (`limits.ts` `getPersonalConnectionCount`), and provisioned instances start with none, so users aren't billed
  for connections they haven't reconnected.

## How reconnect already refreshes channels (the load-bearing fact)

`Integrations.onAuth` (workers/api/src/twist/tools/integrations.ts) **always** returns a
`getChannels → setChannels` dispatch on every (re)auth (≈ integrations.ts:3577–3588), independent of recovery.
So on reconnect of a provisioned instance: the token is bound, `getChannels` runs with the new token and
returns the namespaced channels (each carrying `enabledByDefault`), and `setChannels` mirrors them. That gives
`setChannels` the hook it needs to enable the owned defaults — no extra trigger required.

## Components

### 1. Schema — `twist_instance_connection.seed_default_channels` (flag)

Add a `boolean NOT NULL DEFAULT false` column `seed_default_channels` to `twist_instance_connection`
(`libs/db/schema/50-tables/96-twist_instance_connection.sql`). When `true`, the next `setChannels` for that
connection enables the owned/default channels, then sets it back to `false`. The bankruptcy migration sets it on
provisioned connections; nothing else sets it.

Why a flag instead of "currently zero enabled channels": gating purely on zero enabled channels would also
re-enable defaults for a user who **deliberately disabled every channel** on an active connection and later
re-auths. The flag scopes the behavior to exactly the bankruptcy-provisioned connections — no regression for
existing connections. The flag is **one-shot** (cleared after it fires), so it cannot linger.

Schema-change workflow: edit the schema file → `pnpm gen-migration` → `pnpm apply-migrations` (worktree DB) →
commit the regenerated `libs/db/src/types.ts`.

### 2. Server — `setChannels` "seed owned defaults" special case

In `Integrations.setChannels(provider, actorId, channels)` (integrations.ts ≈ 619), after the existing
mirror-to-DB step and independent of the existing `auto_enable_new_channels` path:

1. Look up the connection row for `(twist_instance_id, provider, actor_id)`; read `seed_default_channels`.
2. If the flag is set **and** the instance currently has **no enabled channels** (defensive — the flag should
   only ever be set on a fresh instance): from the flattened incoming `channels`, select those with
   `enabledByDefault === true` and enable each via the same `applyChannelEnabled` path the auto-enable branch
   uses, collecting the `onChannelEnabled` dispatch entries.
3. Clear the flag (`seed_default_channels = false`) in the same transaction so it fires exactly once.
4. Return the collected dispatches (merged with any from the existing auto-enable path) so the runtime fires
   `onChannelEnabled` for the seeded channels → sync resumes.

Blast radius is tight: the branch is inert unless `seed_default_channels` is set, which only the bankruptcy
migration does. Existing connectors and normal connects are unaffected. (Verify during implementation that the
server-side `Channel` type carries `enabledByDefault` through `getChannels → setChannels`; the client already
consumes it, so it is expected to be present.)

### 3. Bankruptcy provisioning migration (manual prod SQL — in the runbook)

Run after the combined connector is deployed (its catalog `twist` row exists). Per user, per **distinct Google
account** found across their active legacy Gmail/Calendar/Tasks instances (grouped by
`twist_instance_connection.actor_id`):

1. **Provision** one combined Google `twist_instance` (`twist_id` = the combined connector's twist for the
   environment, `owner_id` = the user, `team_id` = the legacy instance's team, `draft = false`, `name`
   disambiguated by the account email only when the user has >1 Google account).
2. **Bind the account, needs-auth, seed-on-reconnect**: insert a `twist_instance_connection`
   (`provider='google'`, `actor_id` = that account's contact, `needs_reauth_at = now()`,
   `seed_default_channels = true`). The `seq` triggers on both tables bump automatically so clients sync the
   new needs-auth connection.
3. **Archive** the legacy Gmail/Calendar/Tasks instances + their catalog `twist` rows
   (`archived_at = now()`) — as in the existing runbook (never delete; synced tables).

One combined instance **per (account × team)**. The existing re-auth account-match guard
(`AUTH_ACCOUNT_MISMATCH_ERROR`) ensures the user re-auths with the bound account; `accountHint` pre-selects it.

### 4. Flutter — no changes

The provisioned needs-auth instances render through the existing reconnect surfaces (sidebar
`ConnectionStatusTile`, Connections list, composite re-auth widget). The connection's `accounts` array
populates from `twist_instance_connection.actor_id`, so the composite re-auth widget pre-fills the correct
Google account.

## End-to-end reconnect flow

1. User sees "Reconnect Google (kris@work)" (needs-auth) in the sidebar / Connections.
2. Taps reconnect → composite re-auth widget → "Continue with Google" (account pre-filled) → OAuth.
3. `onAuth`: binds token to the existing instance (account-match enforced), clears `needs_reauth_at`, returns
   `getChannels → setChannels`.
4. `setChannels`: `seed_default_channels` is set + no enabled channels → enables owned (`enabledByDefault`)
   channels → `onChannelEnabled` fires → sync resumes. Flag cleared.
5. The connection now shows the granted products syncing, owned defaults enabled — identical to a fresh
   connect.

## Testing

- **Unit (server, vitest):** `setChannels` with the flag set + a channel list mixing
  `enabledByDefault: true/false` → enables only the owned ones, returns their dispatch entries, clears the
  flag. Flag set but channels already enabled → no-op (defensive guard). Flag unset → unchanged behavior
  (existing auto-enable path untouched). Flag set, second `setChannels` → no-op (one-shot).
- **Migration (local):** apply the schema migration to the worktree DB; regenerate types; `diff-schema-
  migrations` clean. Provisioning SQL validated in a rolled-back transaction (parses, correct columns; 0 rows
  locally as the legacy connectors aren't deployed to dev).
- **Live (human-gated, in the runbook):** with a real Google account, reconnect a provisioned instance and
  confirm owned channels enable + sync resumes on one re-auth; convergence onto existing threads via
  globally-unique `source` keys.

## Edge cases / risks

- **Account-match strictness:** reconnect must use the bound account; `accountHint` guides it; mismatched
  account → `AUTH_ACCOUNT_MISMATCH_ERROR` (acceptable — surfaced to the user).
- **User archives instead of reconnecting:** fine — they can archive the needs-auth instance; no data loss
  (legacy threads/links remain as historical content).
- **`enabledByDefault` absent on server `Channel`:** confirm during implementation; if absent, thread it
  through `getChannels → setChannels` (small connector/SDK touch) — flagged, not assumed.
- **Token sharing per `{provider}:{actor_id}`:** one combined instance per account avoids the multi-instance
  shared-token concern entirely (one connection per account).

## Scope

In: schema flag, `setChannels` special case (+ tests), provisioning SQL + runbook update. Out (unchanged from
the runbook): deploying the connector + running the SQL in prod (deploy-gated); the optional `filterText`
catalog search aliases; any Flutter change.
