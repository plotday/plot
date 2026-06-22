# Durable Recurring Tasks + Backstop — Design

**Date:** 2026-06-22
**Status:** Approved (design); ready for implementation plan
**Author:** Kris Braun + Claude

## Problem

Self-rescheduling scheduled-task chains can die permanently with no backstop.

Connectors schedule deferred/periodic work via `Tasks.runTask({ runAt })` /
`Tasks.scheduleTask(key, …)`. Each scheduled occurrence is one row in a per-
twist-instance Durable Object, `CallbacksState`
(`workers/api/src/state/callbacks.ts`), DO id `idFromName(twistInstanceId)`.
A single per-DO alarm fires the soonest-due row: it re-enqueues the task into
`RUN_QUEUE` and **deletes the row** (`call_once` defaults to `true` for
scheduled rows), then re-arms the alarm to the next-soonest row.

The continuation of a *periodic* chain therefore lives in exactly two transient
places:

1. the in-flight `RUN_QUEUE` message, and
2. the connector callback's own "schedule the next occurrence" call at the end
   of a successful run (e.g. Gmail `selfHealCheck` → `scheduleSelfHealCheck()`
   → `runTask({ runAt: now + 1h })`).

There is **no durable record that a recurring task is supposed to keep
existing.** The next occurrence exists only if the current one runs to
completion and re-creates it. So any single broken link kills the whole chain
permanently and silently:

- the `RUN_QUEUE` message exhausts its retries and is dropped (no
  `dead_letter_queue` configured → Cloudflare's default 3 retries, then silent
  delete);
- the twist instance is `suspended_at` during the window, so
  `invokeWebhookCallback` throws `CallbackError("SUSPENDED")`, the queue
  consumer `ack()`s (drops) it, and nothing restarts the chain when suspension
  later clears;
- a deploy or DO eviction lands between fire and reschedule;
- the callback throws before reaching its reschedule call.

The only existing recovery sweeps (`recoverStuckSyncs`,
`recoverPendingConnections`, `clearStaleSuspensions`, `index.ts:350-376`,
twice hourly) are scoped to **initial sync only**
(`initial_sync_started_at IS NOT NULL AND initial_sync_completed_at IS NULL`).
Ongoing periodic maintenance is uncovered.

### Validation (claims confirmed against code)

| Claim | Evidence |
|---|---|
| Rows in `CallbacksState`, DO id `idFromName(twistInstanceId)` | `tasks.ts:43-44` |
| Scheduled rows `function_name="scheduledSend"`, `call_once` defaults true | `tasks.ts:71-78`; `callbacks.ts:294` |
| Single per-DO alarm to soonest future `call_at` | `callbacks.ts:845-868` |
| `alarm()` re-enqueues then deletes the row | `callbacks.ts:886-944` |
| Continuation = queue msg + connector reschedule | `gmail.ts:1059,1082-1100`, interval `gmail.ts:63` |
| Queue retry-exhaustion drops the message | `wrangler.jsonc:495-510` (no `dead_letter_queue`/`max_retries`); `tasks.ts:234-306` |
| Suspension drops the chain | `invoke-webhook.ts:111-156` → `tasks.ts:275-283` (`isCallbackError`→`ack`) |
| No general backstop | `recover-stuck-syncs.ts` predicates; `index.ts:350-376` |
| Gmail deadlock | self-heal renews the watch; only re-bootstrap is an inbound webhook (`gmail.ts:1933-1943`), impossible once the watch expires |

### Reliability foundation

Cloudflare DO alarms are **at-least-once**, **auto-retried on throw**
(exponential backoff from 2s, up to 6 retries), **single-alarm-per-DO**, and
**run without incoming requests**. A *set* alarm is durable through the storage
layer across eviction/hibernation/deploys. This is the durable, Cloudflare-
native mechanism the fix is built on. (Source: Cloudflare DO alarms docs.)

### Observed impact

A Gmail connection's hourly `selfHealCheck` chain stopped ~June 4 and never
restarted; live sync flat-lined 18+ days undetected, no exception anywhere
(a vanished chain is silent).

## Scope of the affected surface

Two forms of recurring chain exist, both must migrate. Finite backfill chains
do **not** migrate (they terminate; the initial-sync watchdog already covers
them).

**Recurring — keyed `scheduleTask(key, …)` singleton form (17 chains):**

- Watch/subscription renewals (VARIABLE cadence, `expiry − 24h`): google-calendar,
  google-drive, google-chat (`ws-renewal`), outlook-calendar, airtable
  (`webhook-renewal`), jira.
- Webhook polling safety nets (FIXED 1–60 min): airtable (`poll`), apple-calendar,
  asana, google-tasks.
- Daily member/emoji syncs (24h nominal + rate-limit backoff): slack (members +
  emoji), google-chat (members), ms-teams (global members).

**Recurring — bare `runTask({runAt})` + `mailbox_self_heal_task` store + manual
`cancelTask` form (4 chains, the most fragile, includes the incident):**

- gmail: `selfHealCheck` (`gmail.ts:1094`, hourly) and watch renewal (`gmail.ts:818`).
- outlook-mail: `selfHealCheck` (`outlook-mail.ts:738`) and
  `renewMailboxSubscription` (`outlook-mail.ts:653`).

**Finite backfills (NOT migrated, 10 methods):** gmail/attio/granola/
google-calendar/apple-calendar/google-drive/github/google-tasks/google-contacts/
outlook-calendar `*syncBatch*`, and linkedin `syncRelationsPage` (jittered, stops
when cursor exhausted).

**No recurring chains (correctly):** fellow, linear, posthog, todoist,
instagram, whatsapp. (outlook-mail *does* have recurring chains — its self-heal
and subscription renewal, listed in the bare-`runTask` form above.)

≈ **21 recurring chains across ~13 connectors.** The private connectors
(`connectors/linkedin`, `instagram`, `whatsapp`) were checked explicitly;
only linkedin has task chains and they are finite.

## Goal & non-goals

**Goal:** make a recurring task's continuation **durable and platform-owned**, so
that a dropped queue message, a suspension, a deploy/eviction, or a throwing
callback costs **at most one beat** — never the whole chain — and provide a thin
backstop that resurrects chains that died before the fix (the June-4 incident)
or are lost to a rare bug.

**Non-goals:**

- Migrating finite backfill chains (covered by the initial-sync watchdog).
- A general distributed cron / exact-next-time durable scheduler (the safety-
  ceiling model below is deliberately simpler).
- Changing any connector's *business* logic (what a renewal/poll does) beyond the
  mechanical scheduling swap.

## Chosen approach

**Structural primitive + thin backstop**, entirely Cloudflare-native for the task
mechanism. The continuation moves from "transient queue message + app reschedule"
into the durable DO row + DO alarm. The connector's reschedule becomes an
*optimization* (precise timing), not a *correctness requirement*.

### 1. Core: the DO alarm owns the cadence

**SDK primitive** (added to the Tasks tool in `public/twister`):

```ts
// Durable recurring maintenance. The platform owns the cadence; the callback
// just does the work, idempotently. A dropped/suspended/crashed run loses ONE
// beat, never the chain. Recurring tasks are keyed: re-registering the same key
// atomically replaces the pending occurrence (one live row per key).
scheduleRecurring(
  key: string,
  callback: Callback,
  options: { intervalMs: number; firstRunAt?: Date },
): Promise<void>;

// Teardown reuses the existing keyed cancel (deleteByTaskKey).
cancelScheduledTask(key: string): Promise<void>;
```

`intervalMs` is a **safety ceiling**: the maximum gap between fires. `firstRunAt`
optionally sets the first (or, on re-register, the next) precise fire; it is
clamped so it can pull the fire *earlier* but never push it *later* than the
ceiling.

**DO schema** (`callbacks.ts`, migration-safe `ALTER TABLE ADD COLUMN` exactly
like the existing `task_key`/`key`/`meta` adds): add

```sql
recurring_interval_ms INTEGER   -- NULL = one-shot (today's behavior, unchanged)
```

Recurring tasks always carry a `task_key`, so the existing replace-on-create in
`create()` already guarantees one live row per key.

**`create()` clamp** (recurring only):

```
effective call_at = min(firstRunAt ?? now, now + intervalMs)
```

and persist `recurring_interval_ms = intervalMs`.

**`alarm()` change** — for a due row with `recurring_interval_ms` set: after
enqueuing to `RUN_QUEUE`, **advance** the same row to `call_at = now +
recurring_interval_ms` instead of deleting/nulling it. The advance runs in the
per-row `finally`, **independent of whether the enqueue succeeded**, so the next
occurrence is durably persisted the instant this one fires. Per-row try/catch is
preserved so one bad row never aborts the sweep, and `updateAlarm()` always
re-arms (we must not rely on the alarm's 6-retry budget — the handler must not
throw out).

**How each cadence shape uses it:**

- **Fixed-cadence** (self-heal, polls, daily syncs): register once with
  `intervalMs`; the callback does **not** reschedule. The DO re-arms every
  interval forever. Rate-limit backoff = re-register with an earlier
  `firstRunAt`.
- **Variable-cadence renewals**: register with `intervalMs` = a safe
  sub-watch-lifetime ceiling and `firstRunAt = expiry − 24h`. On success the
  callback re-registers with the new precise `firstRunAt` (singleton replace
  keeps one row, preserves the ceiling). If that run is **dropped/suspended/
  crashed**, the ceiling row armed at fire time re-fires it — the chain
  self-heals on the next ceiling beat.

**Why this kills the root cause:** the durable "this recurring task must exist"
record is the self-advancing DO row plus the durable DO alarm. Every failure mode
in the problem statement now costs at most one beat:

| Failure | Old result | New result |
|---|---|---|
| Queue message dropped (retry exhaustion / storm) | chain dead | ceiling re-fires next interval |
| Instance suspended during window | chain dead, never resumes | beats no-op until resume, then continues |
| Deploy / DO eviction between fire & reschedule | chain dead | next occurrence already persisted at fire time |
| Callback throws before reschedule | chain dead | ceiling re-fires next interval |

### 2. `RUN_QUEUE` dead-letter queue (hardening, folded in)

Add a `dead_letter_queue` to the `RUN_QUEUE` consumer (both `development` and
`production` in `workers/api/wrangler.jsonc`) so a transient storm does not
silently drop a beat in the first place. With the recurring primitive a dropped
beat already self-heals, so the DLQ is belt-and-suspenders: it preserves the
exact in-flight message for observability/manual replay rather than losing it.

- New queue `run-dlq-<env>` as the consumer's `dead_letter_queue`, with a
  consumer that logs/captures the dead-lettered message (owner-attributed, like
  the existing `captureException` path in `processQueue`) so silent drops become
  visible. Keep `max_retries` at the current effective value (or set it
  explicitly) so behavior before the DLQ is unchanged.

### 3. Thin backstop (already-dead chains + rare row loss)

A recurring row is self-perpetuating once it exists; the backstop only handles
chains with **no** row — died before migration (June-4) or lost to a bug.

- **(a) Re-assert on deploy.** Extend each migrated connector's `upgrade()`
  (runs once per active instance on a new version deploy) to idempotently
  re-register its recurring tasks. Deploying the migration **resurrects every
  already-dead chain** with zero new infra. Gmail/Outlook already have an
  `upgrade()`.
- **(b) Low-frequency reconcile sweep.** Generalize the `recover-stuck-syncs`
  liveness idea: over **active** connections, call a new DO method
  `hasLiveRecurringTask(twistInstanceId)`
  (`SELECT 1 FROM callbacks WHERE twist_instance_id = ? AND
  recurring_interval_ms IS NOT NULL LIMIT 1`); for a connection that *expects*
  maintenance but has none live, re-dispatch the connector's existing idempotent
  `onChannelEnabled(recovering: true)` so it re-registers. Gate candidates on a
  marker stamped when a connection first registers a recurring task, so
  webhook-only connectors (linear/todoist — no maintenance, correctly) are never
  false-flagged. Runs on the existing 5-min cron at a low frequency (e.g. hourly).

**"Inside Cloudflare" boundary (explicit):** the *task mechanism* is 100%
Cloudflare — the DO alarm, no Postgres. Layer (b)'s *discovery* reads
`twist_instance_connection` (Postgres) because the set of active connections
lives only there; there is no reliable Cloudflare-native enumeration of them, and
this mirrors the existing `recover-stuck-syncs` sweep. Discovery-only Postgres use
was accepted; the core durability guarantee does not depend on it.

## Migration plan (all recurring chains)

- **Keyed `scheduleTask` chains (17):** swap to `scheduleRecurring(key, cb,
  { intervalMs, firstRunAt })`. Renewals pass `intervalMs` = safe ceiling and
  `firstRunAt = expiry − 24h`; polls/daily-syncs pass `intervalMs` = the existing
  interval and omit `firstRunAt` (or set `now + interval`). Rate-limit backoff
  keeps working as an earlier `firstRunAt` re-register.
- **Bare-`runTask` self-heal chains (4: gmail ×2, outlook-mail ×2):** replace
  `runTask({runAt}) + mailbox_self_heal_task store + cancelTask` with
  `scheduleRecurring(key, …)` + `cancelScheduledTask(key)`; delete the manual
  token bookkeeping. Add the `upgrade()` re-assert.
- **Finite backfills (10):** untouched.

Both `public/connectors/*` (submodule) and `connectors/*` (private) are in scope;
private connectors have no recurring chains but are confirmed in the sweep.

## Testing

TDD throughout (`superpowers:test-driven-development`):

- **DO unit (`@cloudflare/vitest-pool-workers`):** alarm advances a recurring row
  instead of deleting; ceiling clamp (`min(firstRunAt, now+interval)`);
  singleton replace preserves one row and the ceiling; advance happens even when
  enqueue throws; `hasLiveRecurringTask` true/false; one-shot rows behave exactly
  as today (regression).
- **Sweep unit:** candidate selection (active, expects-maintenance, no live
  recurring row) — mirrors `recover-stuck-syncs.test.ts`; webhook-only connectors
  excluded.
- **DLQ:** dead-lettered message is logged/captured with owner attribution.
- **Per-connector:** `pnpm build` + existing connector tests for each migrated
  connector; spot-check that teardown cancels the recurring key.

## Backward compatibility & changeset

- DO schema: `recurring_interval_ms` is nullable; existing rows and deployed
  one-shot callbacks behave unchanged (NULL ⇒ today's path).
- SDK: `scheduleRecurring` is a new method; no existing signature changes.
  Migrated connectors' callbacks keep compatible signatures (optional params at
  end only).
- **Twister change requires a changeset** (`public/.changeset/*.md`,
  `@plotday/twister` minor, `Added:` prefix) per project rules.
- `RUN_QUEUE` DLQ: new queue + consumer; pre-DLQ retry behavior preserved.

## Risks & alternatives considered

- **Safety-ceiling vs exact-next-time scheduler.** Chosen: ceiling + optional
  precise `firstRunAt`. A renewal heartbeat may fire somewhat more often than
  strictly necessary; the callback short-circuits cheaply when not near expiry
  (this is already how self-heal works). Rejected the exact-next-time durable
  scheduler as more complex for no reliability gain — the ceiling *is* the
  guarantee.
- **Backstop layer (b) Postgres discovery.** Kept for defense-in-depth and to
  resurrect pre-migration dead chains beyond the deploy re-assert. Could be
  dropped for a pure "structural only" variant relying on (a) + the self-
  perpetuating row; retained per the approved "structural + thin backstop"
  choice.
- **Alarm must never throw out.** The advance/​re-arm path is wrapped so the
  handler never exhausts the 6-retry alarm budget; per-row failures are caught
  and logged.

## Out of scope

- Fixing connector business logic beyond the scheduling swap.
- The initial-sync watchdog (already covers finite backfills).
- A generic cross-instance task registry in Postgres (explicitly avoided).
