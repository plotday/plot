# "Add connection" activation performance — design

Date: 2026-06-25
Status: Design (approved direction: Levers A + B)

## Problem

Clicking **"Add connection"** (the Save button in the channel-setup modal,
`EditSource`) on a new Google composite ("Gmail & Calendar") connection takes a
long time. The connection bundles four products (Mail, Calendar, Tasks,
Contacts), so a typical setup enables **many** channels at once (several
calendars + Gmail labels + tasks + contacts).

This is distinct from the earlier "Continue with Google" / OAuth round-trip
(`onAuth` → `getChannels`). That path stays synchronous by design; it is only
sped up here as a secondary item (§D).

## Root cause

"Add connection" calls `SaveSource` → `POST /twist/draft/:id/activate` →
`activateDraft` (`workers/api/src/twist/management.ts:834`). The hot path is the
channel-enable loop (`management.ts:1136-1179`):

```
for (const { provider, syncableId } of syncables) {
  await twistWrapper.callCallback([integrationsPath], "enableSync",
                                  provider, syncableId, contact.id, undefined);
}
```

It enables channels **one at a time, serially**, each a full `callCallback` RPC
into the runtime. Each `enableSync` (`integrations.ts:3926`) itself performs
several round-trips **per channel**:

- `getChannelAccess(provider, actorId)` — re-reads the **entire** channel-access
  tree from the connection's Durable Object **on every iteration** (an N+1; the
  tree is identical across channels).
- `buildSyncContext({ forActor, provider })` — another DO RPC; also performs an
  atomic read-and-clear of `recovery_pending`.
- `applyChannelEnabled(...)` — DB/KV writes (channel row, `channel_config`,
  `markChannelSyncStarted` which stamps `initial_sync_started_at` on the
  connection row).
- the connector's **`onChannelEnabled` dispatch runs inline** as part of the
  same round-trip.

Then two more `callCallback`s per provider (`initAutoEnableDefault`,
`initAutoThreadingDefault`).

Total synchronous cost ≈ **N serial heavyweight RPCs × several sub-round-trips
each** — linear in channel count, which is large for the composite.

This code path already carries a documented scar from the same class of bug: a
comment at `enableSync` (`integrations.ts:3968-3972`) records that enabling used
to re-invoke `getChannels` inline, which "for Google Drive paginates every folder
across every drive inline and blocks the HTTP response for many seconds." The
fix below is the durable, structural version of that lesson.

### What actually must be awaited

- **Must be synchronous** (cheap — DB/KV writes): persisting the **channel-enabled
  state** via `applyChannelEnabled` (channel rows enabled + `channel_config` +
  `markChannelSyncStarted`). This is what makes the connection reflect the user's
  selection, sync to the client, and show the "Syncing X" spinner.
- **Does NOT need to block the response**: the connector's **`onChannelEnabled`
  dispatch**. By contract (and as verified in the composite — see
  `connectors/google/src/google.ts` `onCalendarChannelEnabled` etc.),
  `onChannelEnabled` only *queues* background work via `runTask` (webhook setup,
  initial backfill). The UI already shows "Syncing X" from
  `initial_sync_started_at` and flips on `channelSyncCompleted` later, so running
  the dispatch after the response is invisible to the user.

## Goals

- "Add connection" returns in time that is roughly **constant in channel count**,
  not linear.
- The activate response no longer depends on how heavy any connector's
  `onChannelEnabled` is (durability of the pattern, not just this connector).
- No regression: every selected channel ends up enabled and syncs; the
  "Syncing X" → synced transition still happens; failures still surface.

## Non-goals

- Changing the OAuth / `onAuth` / `getChannels` flow's synchronous contract
  (only parallelized — §D).
- Touching the shared `entrypoint.ts` dispatch handlers' inline behavior for
  other callbacks. The change is contained to the Integrations tool + the
  activate caller.

## Design

### A. Collapse the serial per-channel loop into one batch (de-N+1 + parallel)

Introduce a **batch enable** on the Integrations tool and call it **once per
provider** from `activateDraft` instead of `enableSync` per channel:

`enableSyncBatch(provider, channelIds: string[], actorId, titles?)`

1. Read the channel-access tree **once** (`getChannelAccess`).
2. Build the `SyncContext` **once** (`buildSyncContext`) — this also makes the
   `recovery_pending` read-and-clear happen once, matching the existing
   `buildRecoveryDispatches` "build context once so all channels share it"
   semantics (`integrations.ts:979`).
3. For each channel: resolve title/`linkTypes` from the single tree read, then
   `applyChannelEnabled` to persist enabled state. These per-channel persists may
   run concurrently. `applyChannelEnabled` also calls `markChannelSyncStarted`,
   which stamps the connection-level `initial_sync_started_at`; the batch must
   ensure that connection-level stamp is applied (the plan confirms whether it is
   safe to apply once for the batch vs. idempotently per channel — both are
   acceptable as long as `initial_sync_started_at` ends up set).
4. Collect the `onChannelEnabled` dispatch entries for all channels (do not run
   them inline — see B).

`activateDraft` then issues **one** `enableSyncBatch` call per provider (the
composite is a single provider, "google") plus the two `init*Default` calls,
instead of N + 2 serial `callCallback`s.

This alone turns the synchronous cost from `O(N)` round-trips into `O(1)`.

### B. Defer the `onChannelEnabled` dispatch off the response (durable)

`enableSyncBatch` persists enabled state synchronously (A) and then **enqueues**
the collected `onChannelEnabled` dispatches to run in a **background execution**,
rather than running them inline, then returns. "Add connection" returns as soon
as state is persisted.

- **Mechanism:** run the dispatch off the HTTP response via the activate route's
  `executionCtx.waitUntil` (with a fresh db + twist factory, per the AGENTS
  "never use `c.var.db` in waitUntil" rule), invoking a `recoverConnection`-style
  Integrations method (`dispatchEnabledChannels`) that rebuilds the
  `onChannelEnabled` dispatch entries for the just-enabled channels — the same
  "run `onChannelEnabled` dispatches via an RPC into the runtime" the
  recover-pending sweep already performs. For a fresh enable the context is
  `recovering: false` (a normal initial sync), so it does **not** reuse the
  `recovery_pending` flag, whose semantics are re-auth/history-rewalk specific.
- **Durability / error handling:** state persistence (A) stamps
  `initial_sync_started_at` synchronously. If the deferred dispatch is ever lost
  (worker eviction) so that `onChannelEnabled` never runs, the connection sits in
  `initial_syncing` with **no near-future scheduled callback** — exactly the
  orphan signature the **`recoverStuckSyncs`** watchdog
  (`workers/api/src/scheduled/recover-stuck-syncs.ts`) detects
  (`nextScheduledCallbackAt === null` → `isSyncStillBatching` false). It flags
  `recovery_pending`; the recover-pending sweep re-dispatches `onChannelEnabled`,
  bounded to `MAX_INITIAL_SYNC_ATTEMPTS` (3), then surfaces "Reconnect." So the
  watchdog is the backstop — no channel is stranded. (Future hardening: upgrade
  `waitUntil` to a durable run-queue enqueue; the mechanism exists but is out of
  scope.)

### Data flow (after)

```
"Add connection" (SaveSource)
  → POST /twist/draft/:id/activate
  → activateDraft:
      activate twist (unchanged)
      per provider: enableSyncBatch(provider, [channelIds], actor, { dispatch: false })
          read tree once; build context once
          persist enabled state for all channels (mark sync started)
      init{AutoEnable,AutoThreading}Default per provider
      returns channel-dispatch descriptors
  → route: returns immediately (state persisted)
  → route: executionCtx.waitUntil → dispatchEnabledChannels per provider   ← B
[background] onChannelEnabled per channel → runTask(webhook setup, initial backfill)
[client] shows "Syncing X" from initial_sync_started_at, flips on channelSyncCompleted
[backstop] recoverStuckSyncs re-dispatches if the deferred task was ever lost
```

### D. Secondary: keep `onAuth` synchronous but parallelize enumeration

Unrelated to the activate path, but part of "connect feels slow": the composite's
`getChannels` enumerates products **serially** in `composeChannels`
(`public/connectors/google/src/compose.ts:39-47`, a `for … await` loop over
products). Replace with `Promise.all` over products so the four independent
Google API enumerations (Gmail labels, Calendar list, Task lists, Contacts) run
concurrently. `onAuth`/`getChannels` stays fully synchronous; it just stops
paying the sum of four serial round-trips. This doubles as the canonical
"parallelize independent enumeration" example for §C.

### C. Guidance so connectors don't reintroduce this

The recurring mistake (annotated in `enableSync` and lived again here) is heavy
work on the connect/enable critical path. Document the contract where connector
authors look:

- **`public/connectors/AGENTS.md`** — a short **"Connect / enable-path performance
  contract"** section (or fold into the existing `onChannelEnabled` pitfall #15):
  - `onChannelEnabled` is dispatched **off the user's critical path** (the runtime
    persists channel state, then runs `onChannelEnabled` in the background). It
    must still use `runTask` for any heavy work — the background task has the
    normal runtime budget — and must not assume it runs before the user sees the
    connection.
  - `getChannels` runs synchronously during connect; keep it lean and
    **parallelize independent enumeration with `Promise.all`, never serial
    `await` loops** (cite the composite `composeChannels` fix from §D as the
    example).
- **Code comments** at `enableSyncBatch` / `dispatchEnabledChannels` explaining
  the synchronous-persist / deferred-dispatch boundary.

## Testing

- **Server (core):**
  - Regression test that activating with N selected channels issues a
    **constant** number of `callCallback`s (one batch per provider + the two
    `init*Default`), not `O(N)` — via a spy `twistWrapper`.
  - `enableSyncBatch` reads the tree once / builds context once / persists every
    channel; with `{ dispatch: false }` it persists but returns no inline
    `__dispatch`.
  - `dispatchEnabledChannels` emits a non-recovery `onChannelEnabled` dispatch per
    still-enabled channel.
  - `buildOnChannelEnabledEntry` extraction is behavior-preserving.
  - Orphan recovery is already covered by `recover-stuck-syncs.test.ts` (the
    "no scheduled callback ⇒ orphaned" path).
- **Connector (public):** `composeChannels` parallelization keeps channel output
  identical (order-preserving) and runs products concurrently.

## Rollout / PR split

- **core** (`workers/api`): Levers A + B in `integrations.ts`
  (`enableSyncBatch`, `dispatchEnabledChannels`, `buildOnChannelEnabledEntry`),
  `management.ts` (`enableActivatedChannels`, return descriptors), `twists.ts`
  (route `waitUntil`) + tests.
- **public** (submodule): §D `composeChannels` `Promise.all` + §C
  `connectors/AGENTS.md` guidance. Independent of core; mergeable on its own.
- No schema changes. No change to the shared `entrypoint.ts` dispatch handlers'
  inline path.

## Open questions for the plan

- Resolved: Lever B uses `executionCtx.waitUntil` + the `recoverStuckSyncs`
  backstop (durable run-queue enqueue noted as future hardening).
- Whether `enableSyncBatch` should also subsume `setChannels`' auto-seed path so
  the cutover seed and user activate share one batch entry point (nice-to-have;
  not required for the perf fix).
