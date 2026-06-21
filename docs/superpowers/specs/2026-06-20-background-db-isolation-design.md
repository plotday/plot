# Background DB Isolation — Design

**Date:** 2026-06-20
**Status:** Approved (design); ready for implementation plan
**Author:** Kris Braun + Claude

## Problem

Plot's user-facing API and its background processing share one database with **no
resource isolation between them**. When a background workload misbehaves — most
recently the classify "57014 storm" (PostHog `019ed53e`), where one mega-user's
multi-second scoring query was retried in a loop — it degrades the latency of the
user-facing sync hot path.

Today both the `api` worker (HTTP sync handlers **and** five queue consumers) and
the `classify` worker connect through **one shared Hyperdrive config**
(`831ea7d10ef54346b084baaa1a46dfa6`, `origin_connection_limit = 80`) to **one
Cloud SQL instance** (`plot-prod`, **1 vCPU / 3.75 GB**, ZONAL, ~97 usable
connections). The only thing between background load and the frontend is per-queue
`max_concurrency` caps plus `statement_timeout` / `lock_timeout`. Those bound *how
many* background jobs run, not *how much damage* one can do to the frontend.

This spec addresses the **structural** gap so that future background regressions —
not just the current classify query — cannot degrade the frontend the same way.
The current classify query cost is being fixed separately; that is out of scope
here.

### Two failure channels

Background work degrades the frontend through two distinct channels, which need
different fixes:

- **Channel A — connection starvation.** Background consumes Hyperdrive / Cloud SQL
  connection slots, so frontend requests cannot acquire a connection. Fixable with
  a connection-quota partition.
- **Channel B — CPU/IO saturation.** A heavy background query pegs the single vCPU,
  so frontend queries run slow even when they get a connection. On a 1-vCPU
  instance this is the dominant risk. A connection quota does **not** fix it — only
  physical separation (read replica) fully does. Self-throttling backoff partially
  mitigates it.

## Goal & non-goals

**Goal:** ship cheap, structural guardrails now so any background workload (current
or future) cannot starve the frontend of connections (Channel A, fully) and yields
the shared CPU when the DB is hot (Channel B, partially). Lay groundwork and
document the read-replica follow-up that completes Channel B.

**Non-goals:**

- Fixing the specific classify scoring-query cost (tracked separately).
- Standing up the read replica now (documented follow-up, gated on re-measurement).
- A dedicated background Postgres login role (deferred — see "Deferred hardening").
- Any change to the frontend HTTP request path's behavior or latency.

## Chosen approach

**Layered:** connection-quota partition + self-throttling backoff now; read replica
later. Backoff signal is **each background batch observing its own DB latency**
(no new infrastructure). This was selected over connection-quotas-only (leaves
Channel B unaddressed), backoff-only (no hard connection guarantee), and
replica-now (heavier infra, deferred).

## Design

### 1. The two lanes (organizing principle)

Draw the isolation line at **invocation type, not worker**:

- **Frontend lane** = HTTP sync request handlers (`fetch()`). This is what we
  protect; it **never** backs off.
- **Background lane** = everything dispatched via `queue()` or `scheduled()`: the
  `api` worker's five queue consumers (`run`, `updates-v2`, `twist-logs`,
  `webhook`, `extract`), the `classify` worker, and the cron sweep.

The `api` worker straddles both lanes, so it binds **two** Hyperdrive configs and
selects per invocation.

### 2. Connection-quota partition (Channel A)

Split the single Hyperdrive config into two, each with its own
`origin_connection_limit`, summing to today's 80 so the origin's total connection
load is unchanged:

| Lane       | Hyperdrive binding        | `origin_connection_limit` | Used by                                      |
| ---------- | ------------------------- | ------------------------- | -------------------------------------------- |
| Frontend   | `HYPERDRIVE` (existing)   | **50** (reserved)         | HTTP sync handlers                           |
| Background | `HYPERDRIVE_BG` (new)     | **30** (capped)           | all queue consumers + classify + cron sweep  |

Both configs point at the **same** Postgres user (no new DB role in this phase).
Each Hyperdrive config maintains its own independent pool to the origin, so the
background pool physically cannot exceed 30 connections — no queue fan-out (even a
1000-job sweep) can consume the frontend's 50 reserved slots. The numbers are
tunable via `scripts/deploy-hyperdrive` and the Terraform in `infra/hyperdrive/`.

**Consequence to accept:** the `api` worker's queue consumers are configured for up
to ~60 combined concurrency and `classify` for 4. Under load they will collectively
exceed the 30-connection background quota and **wait on Hyperdrive** for a slot.
That is the intended throttle: background throughput degrades gracefully under load
instead of starving the frontend. Queue `max_concurrency` values may be tuned down
later to avoid spinning up isolates that only wait, but that is an optimization, not
required for correctness.

**Connection routing:** `createDb(env)` becomes lane-aware. Introduce explicit
factories — `createFrontendDb(env)` / `createBackgroundDb(env)` (or a single
`createDb(env, lane)`) — that select `HYPERDRIVE` vs `HYPERDRIVE_BG` (falling back
to `DATABASE_URL` in local dev, where there is one local Postgres and the lane is
irrelevant). HTTP handlers and `withUserDb` request paths use the frontend factory;
`queue()` / `scheduled()` entry points and the `classify` worker use the background
factory.

**Pool options:** preserve today's per-lane connection options and close the
existing gap — the background pool should set
`idle_in_transaction_session_timeout` (the `classify` worker's pool does not set it
today). Concretely:

- Frontend: `statement_timeout=30000`, `idle_in_transaction_session_timeout=120000`,
  `lock_timeout=10000` (unchanged from today's `api` pool).
- Background: `statement_timeout=30000`, `idle_in_transaction_session_timeout=120000`,
  `lock_timeout=5000` (adds the missing idle-in-txn reap; keeps classify's tighter
  lock timeout).

### 3. Self-throttling backoff (Channel B, partial)

A shared `backgroundGuard` helper that every background batch handler runs through.
Background queries running slow *is itself* the CPU-pressure proxy: "my queries are
slow → the shared DB is hot → yield." No new infrastructure, reacts within one
batch.

Mechanism:

- **Timed probe at batch start.** Measure connection-acquire time (and the first
  query). Slow acquire = the background pool is saturated / the DB is hot.
- **Warm-isolate memory.** Maintain an EWMA of recent query latency plus a
  recent-timeout flag in a **module-global**, so signal carries across batches on a
  warm isolate. (Best-effort; cold isolates simply start clean.)
- **Decision.** If the probe/EWMA exceeds a threshold, or the previous batch on this
  isolate hit a `57014` (statement timeout) / connection-acquire failure, **defer**
  the whole batch via `message.retry({ delaySeconds })` using exponential backoff +
  jitter (so a fleet of background isolates does not thunder back together) instead
  of processing it.
- **Mid-batch abort.** On a `57014` / connection error mid-batch, stop processing
  the remaining messages and defer them — do not keep hammering a hot DB. This
  generalizes the ack-and-defer pattern `classify` already has for `57014` into a
  reusable guard applied across all background lanes.

The guard is the partial Channel-B mitigation: it makes background voluntarily yield
the shared vCPU under pressure. It does **not** fully isolate CPU — only the replica
follow-up does.

Threshold values (acquire-time ceiling, EWMA ceiling, base delay, max delay, jitter)
are constants tuned conservatively at first (favor *not* deferring frontend-neutral
work) and adjusted after observing PostHog counters (below).

### 4. Observability

Emit PostHog counters from the guard so we can see it working and tune thresholds:

- `bg.deferred` (with `reason: probe_slow | ewma_high | prior_timeout`,
  `lane`/`queue`, `delaySeconds`).
- `bg.timeout_abort` when a batch aborts mid-flight on `57014`/connection error.

These are counters, not exceptions (do **not** `captureException` for expected
backoff — consistent with the existing `classify.deferred_timeout` convention).

### 5. Code placement & files

- `libs/db/` — lane-aware `createDb` factories + the `backgroundGuard` pressure
  helper (both workers depend on `@plotday/db`).
- `workers/api/src/env.ts`, `workers/classify/src/env.ts` — add `HYPERDRIVE_BG` to
  `Bindings`.
- `workers/api/wrangler.jsonc`, `workers/classify/wrangler.jsonc` — second
  Hyperdrive binding (production env); the `queue()` / `scheduled()` entry points
  switch to the background factory and wrap processing in `backgroundGuard`.
- `workers/api/src/index.ts`, `workers/classify/src/index.ts` — wire the background
  factory + guard at the queue/scheduled entry points; classify's existing `57014`
  handling folds into the shared guard.
- `infra/hyperdrive/` — add the second Hyperdrive config (Terraform);
  `scripts/deploy-hyperdrive` updated to manage two configs and the 50/30 limits.

### 6. Documented follow-up (NOT built now)

**Read replica for the background lane.** Stand up a Cloud SQL read replica and
route heavy background **reads** (classify scoring, sweeps) to it so they never
touch the primary's CPU/IO — the true Channel-B fix. Pairs with the
ZONAL → REGIONAL/HA capacity work already on the roadmap. Gated on re-measuring
primary CPU after this ships; if backoff + quota already keep frontend latency
healthy, the replica can wait.

### 7. Deferred hardening (NOT built now)

**Dedicated background Postgres login role with `CONNECTION LIMIT 30`.** Two
Hyperdrive configs on the same user give the *practical* guarantee, but Hyperdrive
pools are "soft" and can transiently overshoot their limit. A dedicated background
role with a hard DB-level `CONNECTION LIMIT` would make the cap absolute even on
overshoot. Deferred because it adds a new login role, a secret in 1Password, and the
secrets-pipeline steps; revisit if overshoot proves to matter in practice.

## Testing

- **Backoff logic (TDD, unit).** The decision function is pure: given measured
  acquire/EWMA latencies and a prior-timeout flag → returns `process` or
  `defer(delaySeconds)`. Unit-test the threshold decision, the EWMA update, and the
  jittered exponential-backoff delay computation (inject the randomness source so it
  is deterministic in tests).
- **Mid-batch abort.** With a fake message batch and a stubbed DB that throws
  `57014` on the Nth query, assert the remaining messages are deferred (retried)
  and `bg.timeout_abort` is emitted.
- **Lane routing (unit).** Assert `createFrontendDb` / `createBackgroundDb` select
  the correct Hyperdrive binding, and fall back to `DATABASE_URL` when the binding
  is absent (local dev).
- **Quota (infra, not unit).** Verify via Terraform plan that two configs exist with
  limits 50 and 30; manually confirm with a local psql connection-flood that the
  background pool cannot exceed its cap. Sum (80) ≤ origin usable (~97).

## Risks & mitigations

- **Background throughput drop under load.** Expected and acceptable — background is
  async and bounded by its quota by design. Surfaced via `bg.deferred` counters;
  tune the 50/30 split or queue concurrency if drainage is too slow.
- **False-positive deferrals** (backoff fires when the DB is fine). Start with
  conservative thresholds and observe `bg.deferred` reasons before tightening;
  deferral only delays background work, never drops it.
- **Local dev parity.** Local dev has one Postgres and no Hyperdrive; the factories
  fall back to `DATABASE_URL` so both lanes resolve to the same local DB and the
  guard is a no-op-fast path. No dev workflow change.
- **Warm-isolate EWMA is best-effort.** Cold isolates start without history; the
  per-batch probe still provides an immediate signal, so correctness does not depend
  on the module-global persisting.
