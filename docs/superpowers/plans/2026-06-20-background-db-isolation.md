# Background DB Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop background processing (classify queue, twist/queue callbacks, cron sweeps) from degrading the user-facing sync API by partitioning DB connections into a reserved frontend lane and a capped background lane, and making background work self-throttle when the shared DB is hot.

**Architecture:** Two Hyperdrive configs front the one Cloud SQL instance — `HYPERDRIVE` (frontend, `origin_connection_limit=50`, reserved for HTTP request handlers) and `HYPERDRIVE_BG` (background, `origin_connection_limit=30`, used by everything dispatched via `queue()`/`scheduled()` plus the classify worker). The DB factories make **background the default** (`createDb`/`withDb` → `HYPERDRIVE_BG`) with an explicit `createFrontendDb`/`withFrontendDb` for the request path, so a missed call site fails safe to the capped lane. A shared `background-guard` in `@plotday/worker-util` records background query latency / timeouts into a module-global and lets queue dispatchers shed (defer) a batch before it piles onto a saturated DB.

**Tech Stack:** Cloudflare Workers, Cloudflare Hyperdrive, Cloudflare Queues, Kysely + `pg`, Cloud SQL Postgres, Terraform (`infra/hyperdrive/`), Vitest, pnpm workspaces.

## Global Constraints

- **Connection split:** frontend `HYPERDRIVE` = **50**, background `HYPERDRIVE_BG` = **30**; sum (80) must stay ≤ ~97 usable origin connections. Unchanged total from today's single config (80).
- **No dedicated DB role this phase.** Both Hyperdrive configs authenticate as the existing `api` Postgres user. The DB-level `CONNECTION LIMIT` hardening is an explicitly deferred follow-up.
- **Background is the default lane.** `createDb(env)` / `withDb(env)` resolve `HYPERDRIVE_BG ?? HYPERDRIVE ?? DATABASE_URL`. Frontend request paths must call `createFrontendDb` / `withFrontendDb` (resolve `HYPERDRIVE ?? DATABASE_URL`).
- **Lane routing rule (mechanical):** any site that passes `c.env` / uses `c.var` (Hono request context) is frontend → frontend factory. Any site that passes `env` / `this.env` (queue, scheduled, Durable Object) is background → default factory.
- **Local dev / tests:** no Hyperdrive bindings exist; both lanes fall back to `DATABASE_URL` → same local Postgres. The guard is a fast no-op when the DB is responsive. No dev-workflow change.
- **Error-capture policy:** expected backoff/deferral emits PostHog **counter** events (`bg.deferred`, `bg.timeout_abort`), never `captureException`. Matches the existing `classify.deferred_timeout` convention.
- **Never deploy from this work.** Creating the real `HYPERDRIVE_BG` Cloudflare config and changing pool sizes are production mutations the user runs (documented runbook in Task 9). All code/config is authored so local dev and tests pass without any Cloudflare resource.
- **Backoff tunables are conservative first-cut constants** (favor *not* deferring), tuned later from `bg.deferred` counters.

---

### Task 1: Add `HYPERDRIVE_BG` binding + env types

**Files:**
- Modify: `workers/api/src/env.ts` (the `Bindings` type, around line 166–170)
- Modify: `workers/classify/src/index.ts` (the `Env` interface, around line 26–31)
- Modify: `workers/api/wrangler.jsonc` (the production-env `hyperdrive` array, ~line 383)
- Modify: `workers/classify/wrangler.jsonc` (the production-env `hyperdrive` array, ~line 54)

**Interfaces:**
- Produces: `env.HYPERDRIVE_BG?: Hyperdrive` (api) and `env.HYPERDRIVE_BG?: { connectionString: string }` (classify), consumed by the factories in Task 2 / Task 4.

- [ ] **Step 1: Add `HYPERDRIVE_BG` to the api `Bindings` type**

In `workers/api/src/env.ts`, directly under the existing `HYPERDRIVE` line:

```ts
export type Bindings = {
  readonly HYPERDRIVE?: Hyperdrive;
  // Background-lane Hyperdrive config (separate origin_connection_limit) so
  // queue/scheduled/DO work can't starve the frontend's reserved connections.
  // Absent in local dev/tests → factories fall back to DATABASE_URL.
  readonly HYPERDRIVE_BG?: Hyperdrive;
  readonly DATABASE_URL?: string;
  // ...rest unchanged
```

- [ ] **Step 2: Add `HYPERDRIVE_BG` to the classify `Env` interface**

In `workers/classify/src/index.ts`:

```ts
export interface Env extends ClassifyEnv {
  readonly DATABASE_URL?: string;
  readonly HYPERDRIVE?: { connectionString: string };
  readonly HYPERDRIVE_BG?: { connectionString: string };
  readonly POSTHOG_API_KEY: string;
  readonly POSTHOG_HOST: string;
}
```

- [ ] **Step 3: Add the production binding to both wrangler configs**

In `workers/api/wrangler.jsonc`, extend the production `hyperdrive` array (keep the existing `HYPERDRIVE` entry, add a second). The `id` is a placeholder until Task 9 creates the real config; the `localConnectionString` points at the same local Postgres so dev works now:

```jsonc
"hyperdrive": [
  {
    "binding": "HYPERDRIVE",
    "id": "831ea7d10ef54346b084baaa1a46dfa6",
    "localConnectionString": "postgresql://postgres:postgres@localhost:54322/postgres"
  },
  {
    "binding": "HYPERDRIVE_BG",
    "id": "REPLACE_WITH_HYPERDRIVE_BG_ID",
    "localConnectionString": "postgresql://postgres:postgres@localhost:54322/postgres"
  }
],
```

Make the identical addition to `workers/classify/wrangler.jsonc`'s `hyperdrive` array.

- [ ] **Step 4: Typecheck both workers**

Run: `pnpm --filter @plotday/api run lint && pnpm --filter @plotday/classify run lint`
Expected: PASS (the new optional binding is referenced nowhere yet; this only proves the types/JSON are valid).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/env.ts workers/classify/src/index.ts workers/api/wrangler.jsonc workers/classify/wrangler.jsonc
git commit -m "feat(db): declare HYPERDRIVE_BG background-lane binding"
```

---

### Task 2: Lane-aware DB factories in the api worker

**Files:**
- Modify: `workers/api/src/db.ts` (the `createDb` function ~line 20, `withDb` ~line 66)
- Test: `workers/api/src/db.test.ts` (add cases; file already exists)

**Interfaces:**
- Produces:
  - `resolveConnectionString(env, lane): string` where `lane` is `"frontend" | "background"` — pure, exported for testing.
  - `createDb(env)` / `withDb(env, fn)` — **background lane** (unchanged signatures; now resolve `HYPERDRIVE_BG ?? HYPERDRIVE ?? DATABASE_URL`).
  - `createFrontendDb(env)` / `withFrontendDb(env, fn)` — **frontend lane** (resolve `HYPERDRIVE ?? DATABASE_URL`).
- Consumes: `env.HYPERDRIVE`, `env.HYPERDRIVE_BG`, `env.DATABASE_URL` from Task 1.

- [ ] **Step 1: Write the failing test for connection-string resolution**

Add to `workers/api/src/db.test.ts`:

```ts
import { resolveConnectionString } from "./db";

describe("resolveConnectionString", () => {
  const FE = "postgres://fe";
  const BG = "postgres://bg";
  const DIRECT = "postgres://direct";

  it("background lane prefers HYPERDRIVE_BG", () => {
    const env = {
      HYPERDRIVE: { connectionString: FE },
      HYPERDRIVE_BG: { connectionString: BG },
      DATABASE_URL: DIRECT,
    } as any;
    expect(resolveConnectionString(env, "background")).toBe(BG);
  });

  it("frontend lane prefers HYPERDRIVE and ignores HYPERDRIVE_BG", () => {
    const env = {
      HYPERDRIVE: { connectionString: FE },
      HYPERDRIVE_BG: { connectionString: BG },
      DATABASE_URL: DIRECT,
    } as any;
    expect(resolveConnectionString(env, "frontend")).toBe(FE);
  });

  it("background falls back to HYPERDRIVE then DATABASE_URL (local dev)", () => {
    expect(
      resolveConnectionString({ HYPERDRIVE: { connectionString: FE } } as any, "background")
    ).toBe(FE);
    expect(
      resolveConnectionString({ DATABASE_URL: DIRECT } as any, "background")
    ).toBe(DIRECT);
  });

  it("frontend falls back to DATABASE_URL", () => {
    expect(
      resolveConnectionString({ DATABASE_URL: DIRECT } as any, "frontend")
    ).toBe(DIRECT);
  });

  it("throws when nothing is configured", () => {
    expect(() => resolveConnectionString({} as any, "background")).toThrow();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pnpm --filter @plotday/api exec vitest run src/db.test.ts -t resolveConnectionString`
Expected: FAIL with `resolveConnectionString is not a function` (not exported yet).

- [ ] **Step 3: Implement the factories**

In `workers/api/src/db.ts`, replace the `createDb` function (lines 19–60) with the lane-aware version and add the helpers. Keep the existing `options` strings verbatim — both lanes get `idle_in_transaction_session_timeout`; the only per-lane difference today is `lock_timeout` (frontend 10s, background 5s, matching the classify worker's tighter contention fast-fail):

```ts
export type DbLane = "frontend" | "background";

/** Resolve the connection string for a lane. Background prefers the capped
 *  HYPERDRIVE_BG pool; frontend prefers the reserved HYPERDRIVE pool. Both fall
 *  back to DATABASE_URL in local dev/tests (where neither binding exists). */
export function resolveConnectionString(env: Bindings, lane: DbLane): string {
  const cs =
    lane === "frontend"
      ? env.HYPERDRIVE?.connectionString ?? env.DATABASE_URL
      : env.HYPERDRIVE_BG?.connectionString ??
        env.HYPERDRIVE?.connectionString ??
        env.DATABASE_URL;
  if (!cs) {
    throw new Error(
      `No database connection for ${lane} lane: set HYPERDRIVE/HYPERDRIVE_BG or DATABASE_URL`
    );
  }
  return cs;
}

function createDbForLane(env: Bindings, lane: DbLane) {
  const connectionString = resolveConnectionString(env, lane);
  const lockTimeoutMs = lane === "frontend" ? 10000 : 5000;
  const pool = new pg.Pool({
    connectionString,
    max: 1,
    // See the original note: -c GUCs survive Hyperdrive pooling. Background uses
    // the tighter lock_timeout (5s) to fast-fail contention; both reap abandoned
    // in-transaction backends after 2 min.
    options: `-c statement_timeout=30000 -c idle_in_transaction_session_timeout=120000 -c lock_timeout=${lockTimeoutMs}`,
  });
  pool.on("error", (err) => {
    const logger = createLogger({ source: "pg_pool" });
    logger.error("DB pool error", err, { pg_code: (err as any)?.code });
  });
  return new Kysely<DB>({ dialect: new PostgresDialect({ pool }) });
}

/** Background-lane Kysely instance (HYPERDRIVE_BG). DEFAULT for queue/scheduled/DO
 *  work. Call once per unit of work; always destroy it. */
export function createDb(env: Bindings) {
  return createDbForLane(env, "background");
}

/** Frontend-lane Kysely instance (HYPERDRIVE, reserved). Use ONLY from HTTP
 *  request handlers (sites that have `c.env`). */
export function createFrontendDb(env: Bindings) {
  return createDbForLane(env, "frontend");
}
```

Then add a `withFrontendDb` alongside `withDb`. Refactor `withDb` to delegate to a shared `withDbForLane` so the retry logic is not duplicated:

```ts
async function withDbForLane<T>(
  env: Bindings,
  lane: DbLane,
  fn: (db: Kysely<DB>) => Promise<T>
): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; ; attempt++) {
    if (attempt > 0) {
      const delayMs = transientRetryDelayMs(lastError, attempt);
      if (delayMs > 0) await new Promise((r) => setTimeout(r, delayMs));
    }
    const db = createDbForLane(env, lane);
    try {
      await sql`SET statement_timeout = 30000`.execute(db);
      return await fn(db);
    } catch (error) {
      lastError = error;
      if (attempt < maxRetriesFor(error)) continue;
      throw error;
    } finally {
      await db.destroy();
    }
  }
}

/** Background-lane withDb (DEFAULT). */
export async function withDb<T>(
  env: Bindings,
  fn: (db: Kysely<DB>) => Promise<T>
): Promise<T> {
  return withDbForLane(env, "background", fn);
}

/** Frontend-lane withDb. Use ONLY from HTTP request handlers. */
export async function withFrontendDb<T>(
  env: Bindings,
  fn: (db: Kysely<DB>) => Promise<T>
): Promise<T> {
  return withDbForLane(env, "frontend", fn);
}
```

- [ ] **Step 4: Run the resolution test to verify it passes**

Run: `pnpm --filter @plotday/api exec vitest run src/db.test.ts -t resolveConnectionString`
Expected: PASS (all 5 cases).

- [ ] **Step 5: Run the full db test file + lint to confirm no regression**

Run: `pnpm --filter @plotday/api exec vitest run src/db.test.ts && pnpm --filter @plotday/api run lint`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/db.ts workers/api/src/db.test.ts
git commit -m "feat(db): lane-aware DB factories (background default, frontend explicit)"
```

---

### Task 3: Route frontend request paths to the frontend lane

**Files:**
- Modify: `workers/api/src/middleware/db.ts` (the `dbMiddleware`, line 14)
- Modify: every non-test site that opens a DB from Hono request context (`createDb(c.env)` / `withDb(c.env, ...)`). Known set (verify with the audit grep in Step 1): `app/sync/*.ts` (threads.ts, notes.ts, links.ts, capture.ts, priorities.ts, schedules.ts, note-retry-send.ts, contacts-changed-dispatch.ts, twist-instances.ts), `webhook.ts:1020`, `sdk/twist.ts:491`.

**Interfaces:**
- Consumes: `createFrontendDb` / `withFrontendDb` from Task 2.

- [ ] **Step 1: Enumerate the exact frontend sites (audit grep)**

Run from `workers/api/src`:

```bash
grep -rn --include='*.ts' -E 'createDb\(c\.env\)|withDb\(c\.env' . | grep -v '.test.ts'
```

This is the authoritative list to change in Step 3. Record the count; you will re-run it in Step 4 to confirm zero remain.

- [ ] **Step 2: Switch `dbMiddleware` to the frontend factory**

In `workers/api/src/middleware/db.ts`:

```ts
import { createFrontendDb } from "../db";
// ...
export const dbMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  const db = createFrontendDb(c.env);
  c.set("db", db);
  try {
    await next();
  } finally {
    await db.destroy();
  }
};
```

- [ ] **Step 3: Switch every `c.env` site to the frontend factory**

For each file from Step 1, update the import and the call:
- `createDb(c.env)` → `createFrontendDb(c.env)`
- `withDb(c.env, ...)` → `withFrontendDb(c.env, ...)`

Add `createFrontendDb` / `withFrontendDb` to the existing `from "../db"` (or `"../../db"`) import in each file. Do **not** touch sites that pass `env` or `this.env` — those stay on the background default. Example (`app/sync/threads.ts:946`):

```ts
import { createFrontendDb } from "../../db";
// ...
const db = createFrontendDb(c.env);
```

- [ ] **Step 4: Re-run the audit grep to confirm none remain**

Run: `grep -rn --include='*.ts' -E 'createDb\(c\.env\)|withDb\(c\.env' workers/api/src | grep -v '.test.ts'`
Expected: **no output** (every request-context site now uses the frontend factory).

- [ ] **Step 5: Lint + run the sync test suite**

Run: `pnpm --filter @plotday/api run lint && pnpm --filter @plotday/api exec vitest run src/app/sync`
Expected: PASS (tests use `{ DATABASE_URL }` → both factories fall back to local DB, so behavior is identical).

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/middleware/db.ts workers/api/src/app workers/api/src/webhook.ts workers/api/src/sdk/twist.ts
git commit -m "feat(db): route frontend request paths to the reserved frontend lane"
```

---

### Task 4: Point the classify worker at the background lane

**Files:**
- Modify: `workers/classify/src/db.ts` (`createDb` ~line 33, its pool `options` ~line 52)

**Interfaces:**
- Consumes: `env.HYPERDRIVE_BG` from Task 1.

- [ ] **Step 1: Resolve the background connection string and add the idle-txn reap**

In `workers/classify/src/db.ts`, update `createDb` to prefer `HYPERDRIVE_BG` and close the missing `idle_in_transaction_session_timeout` gap noted in the spec:

```ts
export function createDb(env: {
  DATABASE_URL?: string;
  HYPERDRIVE?: { connectionString: string };
  HYPERDRIVE_BG?: { connectionString: string };
}): ClassifyDb {
  const connectionString =
    env.HYPERDRIVE_BG?.connectionString ??
    env.HYPERDRIVE?.connectionString ??
    env.DATABASE_URL;
  if (!connectionString) {
    throw new Error("classify-worker: DATABASE_URL or HYPERDRIVE binding required");
  }
  const pool = new pg.Pool({
    connectionString,
    max: 1,
    // Background lane: tight lock_timeout (5s) fast-fails thread_priority /
    // user_sync contention; idle_in_transaction reap matches the api worker so a
    // worker reloaded mid-transaction can't pin a backend for the full
    // statement_timeout.
    options:
      "-c statement_timeout=30000 -c idle_in_transaction_session_timeout=120000 -c lock_timeout=5000",
  });
  pool.on("error", () => {});
  return new Kysely<DB>({ dialect: new PostgresDialect({ pool }) });
}
```

Update the `env` parameter type on `withDb` (line 60–62) to include `HYPERDRIVE_BG?: { connectionString: string }` to match.

- [ ] **Step 2: Lint + run the classify worker tests**

Run: `pnpm --filter @plotday/classify run lint && pnpm --filter @plotday/classify exec vitest run`
Expected: PASS (tests use `DATABASE_URL` → unchanged local behavior).

- [ ] **Step 3: Commit**

```bash
git add workers/classify/src/db.ts
git commit -m "feat(classify): connect via the background Hyperdrive lane"
```

---

### Task 5: `background-guard` pressure logic in `@plotday/worker-util`

**Files:**
- Create: `libs/worker-util/src/background-guard.ts`
- Modify: `libs/worker-util/src/index.ts` (re-export the new module)
- Test: `libs/worker-util/src/background-guard.test.ts`

**Interfaces:**
- Produces (all consumed in Tasks 6–7):
  - `type BackgroundPressure = { ewmaMs: number; samples: number; lastTimeoutAtMs: number }`
  - `backgroundPressure: BackgroundPressure` — shared module-global.
  - `recordLatency(p: BackgroundPressure, ms: number): void`
  - `recordTimeout(p: BackgroundPressure, nowMs: number): void`
  - `shouldDefer(p: BackgroundPressure, nowMs: number): { defer: boolean; reason: "none" | "ewma_high" | "recent_timeout" }`
  - `backoffDelaySeconds(attempts: number, rng?: () => number): number`

- [ ] **Step 1: Write the failing tests**

Create `libs/worker-util/src/background-guard.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import {
  createPressure,
  recordLatency,
  recordTimeout,
  shouldDefer,
  backoffDelaySeconds,
  DEFER_EWMA_MS,
  TIMEOUT_COOLDOWN_MS,
} from "./background-guard";

describe("recordLatency / shouldDefer (EWMA)", () => {
  it("does not defer when no samples", () => {
    expect(shouldDefer(createPressure(), 1000).defer).toBe(false);
  });

  it("does not defer on fast background queries", () => {
    const p = createPressure();
    for (let i = 0; i < 10; i++) recordLatency(p, 80);
    expect(shouldDefer(p, 1000)).toEqual({ defer: false, reason: "none" });
  });

  it("defers once EWMA climbs above the saturation threshold", () => {
    const p = createPressure();
    for (let i = 0; i < 20; i++) recordLatency(p, DEFER_EWMA_MS + 1500);
    const d = shouldDefer(p, 1000);
    expect(d).toEqual({ defer: true, reason: "ewma_high" });
  });
});

describe("recordTimeout / shouldDefer (cooldown)", () => {
  it("defers within the cooldown window after a timeout", () => {
    const p = createPressure();
    recordTimeout(p, 1000);
    expect(shouldDefer(p, 1000 + TIMEOUT_COOLDOWN_MS - 1)).toEqual({
      defer: true,
      reason: "recent_timeout",
    });
  });

  it("stops deferring after the cooldown elapses", () => {
    const p = createPressure();
    recordTimeout(p, 1000);
    expect(shouldDefer(p, 1000 + TIMEOUT_COOLDOWN_MS + 1).defer).toBe(false);
  });
});

describe("backoffDelaySeconds", () => {
  it("grows with attempts and is bounded ≥ 1s", () => {
    const rng = () => 0; // floor of the jitter band
    expect(backoffDelaySeconds(1, rng)).toBeGreaterThanOrEqual(1);
    expect(backoffDelaySeconds(5, rng)).toBeGreaterThan(backoffDelaySeconds(1, rng));
  });

  it("caps the delay", () => {
    const rng = () => 1; // top of the jitter band
    expect(backoffDelaySeconds(50, rng)).toBeLessThanOrEqual(30);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/worker-util exec vitest run src/background-guard.test.ts`
Expected: FAIL (module does not exist).

- [ ] **Step 3: Implement `background-guard.ts`**

Create `libs/worker-util/src/background-guard.ts`:

```ts
/**
 * Self-throttling signal for BACKGROUND database work. Background queries
 * running slow IS the CPU-pressure proxy for the shared (single-vCPU) Postgres
 * origin: "my queries are slow → the DB is hot → yield". Queue dispatchers call
 * shouldDefer() at batch start and defer the batch (retry-with-delay) instead of
 * piling onto a saturated backend. State is a module-global so signal carries
 * across batches on a warm isolate; it is best-effort (cold isolates start clean,
 * and correctness never depends on it persisting).
 *
 * NOT used by the frontend lane — the frontend never backs off; it is the thing
 * being protected.
 */
export type BackgroundPressure = {
  ewmaMs: number;
  samples: number;
  lastTimeoutAtMs: number;
};

// Conservative first cut — favor NOT deferring. Normal background query is
// <120ms warm in prod; a sustained EWMA over 2s means real saturation. Tune from
// the bg.deferred counters after deploy.
export const EWMA_ALPHA = 0.3;
export const DEFER_EWMA_MS = 2000;
export const TIMEOUT_COOLDOWN_MS = 30_000;
export const BACKOFF_BASE_MS = 1000;
export const BACKOFF_CAP_MS = 30_000;

export function createPressure(): BackgroundPressure {
  return { ewmaMs: 0, samples: 0, lastTimeoutAtMs: 0 };
}

/** Shared across all background batches on this isolate. */
export const backgroundPressure: BackgroundPressure = createPressure();

export function recordLatency(p: BackgroundPressure, ms: number): void {
  p.ewmaMs =
    p.samples === 0 ? ms : EWMA_ALPHA * ms + (1 - EWMA_ALPHA) * p.ewmaMs;
  p.samples += 1;
}

export function recordTimeout(p: BackgroundPressure, nowMs: number): void {
  p.lastTimeoutAtMs = nowMs;
}

export type DeferReason = "none" | "ewma_high" | "recent_timeout";

export function shouldDefer(
  p: BackgroundPressure,
  nowMs: number
): { defer: boolean; reason: DeferReason } {
  if (p.lastTimeoutAtMs > 0 && nowMs - p.lastTimeoutAtMs < TIMEOUT_COOLDOWN_MS) {
    return { defer: true, reason: "recent_timeout" };
  }
  if (p.samples > 0 && p.ewmaMs > DEFER_EWMA_MS) {
    return { defer: true, reason: "ewma_high" };
  }
  return { defer: false, reason: "none" };
}

/** Exponential backoff with equal jitter, capped, expressed in whole seconds
 *  (Cloudflare Queues `retry({ delaySeconds })` granularity). `attempts` is the
 *  message delivery count. rng injected for deterministic tests. */
export function backoffDelaySeconds(
  attempts: number,
  rng: () => number = Math.random
): number {
  const ceilingMs = Math.min(
    BACKOFF_CAP_MS,
    BACKOFF_BASE_MS * 2 ** Math.max(0, attempts - 1)
  );
  const halfMs = ceilingMs / 2;
  const ms = halfMs + rng() * halfMs;
  return Math.max(1, Math.round(ms / 1000));
}
```

- [ ] **Step 4: Re-export from the package index**

In `libs/worker-util/src/index.ts`, add:

```ts
export * from "./background-guard";
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm --filter @plotday/worker-util exec vitest run src/background-guard.test.ts`
Expected: PASS (all cases).

- [ ] **Step 6: Lint + commit**

```bash
pnpm --filter @plotday/worker-util run lint
git add libs/worker-util/src/background-guard.ts libs/worker-util/src/background-guard.test.ts libs/worker-util/src/index.ts
git commit -m "feat(worker-util): background-guard DB pressure signal"
```

---

### Task 6: Record background DB pressure from the background `withDb`

**Files:**
- Modify: `workers/api/src/db.ts` (`withDbForLane` from Task 2)
- Modify: `workers/classify/src/db.ts` (`withDb` ~line 60)
- Test: `workers/api/src/db.test.ts`

**Interfaces:**
- Consumes: `backgroundPressure`, `recordLatency`, `recordTimeout` from Task 5; `isPoolExhaustedError` (api db.ts) / `isStatementTimeoutError` (classify db.ts).
- Produces: side effects on the shared `backgroundPressure` — no new exported symbols.

Rationale: the startup `SET statement_timeout` round-trip already present in both `withDb` paths is a free probe of connection-acquire + backend responsiveness. Time it and fold into the EWMA. Only the **background** lane records; `withFrontendDb` must not.

- [ ] **Step 1: Write the failing test (api background withDb records latency)**

Add to `workers/api/src/db.test.ts` (uses the local `DATABASE_URL`, so it runs a real fast query):

```ts
import { backgroundPressure } from "@plotday/worker-util";
import { withDb, withFrontendDb } from "./db";

describe("withDb records background pressure", () => {
  it("background withDb folds a latency sample into backgroundPressure", async () => {
    const before = backgroundPressure.samples;
    await withDb({ DATABASE_URL } as any, async (db) => {
      await db.selectFrom("priority").select("id").limit(1).execute();
    });
    expect(backgroundPressure.samples).toBeGreaterThan(before);
  });

  it("frontend withFrontendDb does NOT record background pressure", async () => {
    const before = backgroundPressure.samples;
    await withFrontendDb({ DATABASE_URL } as any, async (db) => {
      await db.selectFrom("priority").select("id").limit(1).execute();
    });
    expect(backgroundPressure.samples).toBe(before);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/api exec vitest run src/db.test.ts -t "records background pressure"`
Expected: FAIL (background sample count does not increase — no recording yet).

- [ ] **Step 3: Add recording to the background branch of `withDbForLane`**

In `workers/api/src/db.ts`, import the guard and time the startup SET only for the background lane:

```ts
import {
  createLogger,
  retryOnTxnConflict,
  backgroundPressure,
  recordLatency,
  recordTimeout,
} from "@plotday/worker-util";
```

Inside `withDbForLane`, wrap the startup probe and error path:

```ts
    const db = createDbForLane(env, lane);
    try {
      const startedAt = Date.now();
      await sql`SET statement_timeout = 30000`.execute(db);
      if (lane === "background") {
        recordLatency(backgroundPressure, Date.now() - startedAt);
      }
      return await fn(db);
    } catch (error) {
      lastError = error;
      if (lane === "background" && isPoolExhaustedError(error)) {
        recordTimeout(backgroundPressure, Date.now());
      }
      if (attempt < maxRetriesFor(error)) continue;
      throw error;
    } finally {
      await db.destroy();
    }
```

- [ ] **Step 4: Record latency in the classify worker's `withDb`**

In `workers/classify/src/db.ts`, import the guard and time the startup SETs (`sql` is already imported at the top of this file). Record **latency only** here — do NOT add a catch to record timeouts: in the classify worker a `57014` thrown by `handleClassifyJob` is caught *inside* the `withDb` callback's per-message loop and never propagates to this level, so timeout recording belongs in the handler's statement-timeout branch instead (Task 8). Keep the existing `try { ... } finally { ... }` shape:

```ts
import {
  backgroundPressure,
  recordLatency,
} from "@plotday/worker-util";
// ...
export async function withDb<T>(env, fn): Promise<T> {
  const db = createDb(env);
  try {
    const startedAt = Date.now();
    await sql`SET statement_timeout = 30000`.execute(db);
    await sql`SET lock_timeout = 5000`.execute(db);
    recordLatency(backgroundPressure, Date.now() - startedAt);
    return await fn(db);
  } finally {
    await db.destroy();
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm --filter @plotday/api exec vitest run src/db.test.ts -t "records background pressure" && pnpm --filter @plotday/classify exec vitest run`
Expected: PASS.

- [ ] **Step 6: Lint + commit**

```bash
pnpm --filter @plotday/api run lint && pnpm --filter @plotday/classify run lint
git add workers/api/src/db.ts workers/api/src/db.test.ts workers/classify/src/db.ts
git commit -m "feat(db): record background-lane query latency/timeouts for backoff"
```

---

### Task 7: Shed hot batches in the queue dispatchers

**Files:**
- Modify: `workers/api/src/queue/index.ts` (the `queue` function, top of the body ~line 26)
- Modify: `workers/classify/src/index.ts` (the `queue` handler, top of the body ~line 34)
- Test: `workers/api/src/queue/shed.test.ts` (new — tests an extracted pure helper)

**Interfaces:**
- Consumes: `backgroundPressure`, `shouldDefer`, `backoffDelaySeconds` from Task 5.
- Produces: `shedBatchIfHot(batch, posthog, queueName, nowMs, rng?): boolean` — extracted so the defer decision is unit-testable; returns `true` if it deferred (caller returns early).

- [ ] **Step 1: Write the failing test for `shedBatchIfHot`**

Create `workers/api/src/queue/shed.test.ts`:

```ts
import { describe, it, expect, vi } from "vitest";
import { backgroundPressure, recordTimeout } from "@plotday/worker-util";
import { shedBatchIfHot } from "./shed";

function fakeBatch(n: number) {
  const messages = Array.from({ length: n }, (_, i) => ({
    attempts: 1,
    retry: vi.fn(),
    ack: vi.fn(),
    body: { i },
  }));
  return { queue: "updates-production", messages } as any;
}

const posthog = { capture: vi.fn() } as any;

describe("shedBatchIfHot", () => {
  it("does nothing when the DB is healthy", () => {
    // fresh pressure: no samples, no timeout
    backgroundPressure.samples = 0;
    backgroundPressure.ewmaMs = 0;
    backgroundPressure.lastTimeoutAtMs = 0;
    const batch = fakeBatch(3);
    const deferred = shedBatchIfHot(batch, posthog, "updates", 5000);
    expect(deferred).toBe(false);
    expect(batch.messages[0].retry).not.toHaveBeenCalled();
  });

  it("retries every message with a delay when pressure is hot", () => {
    recordTimeout(backgroundPressure, 5000); // within cooldown of now=5000
    const batch = fakeBatch(3);
    const deferred = shedBatchIfHot(batch, posthog, "updates", 5000, () => 0);
    expect(deferred).toBe(true);
    for (const m of batch.messages) {
      expect(m.retry).toHaveBeenCalledWith({
        delaySeconds: expect.any(Number),
      });
    }
    expect(posthog.capture).toHaveBeenCalledWith(
      expect.objectContaining({ event: "bg.deferred" })
    );
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/api exec vitest run src/queue/shed.test.ts`
Expected: FAIL (`./shed` does not exist).

- [ ] **Step 3: Implement `shedBatchIfHot`**

Create `workers/api/src/queue/shed.ts`:

```ts
import type { PostHog } from "posthog-node";
import {
  backgroundPressure,
  shouldDefer,
  backoffDelaySeconds,
} from "@plotday/worker-util";

type ShedMessage = { attempts: number; retry: (opts?: { delaySeconds: number }) => void };
type ShedBatch = { queue: string; messages: ShedMessage[] };

/**
 * If background DB pressure is high, defer the WHOLE batch (retry every message
 * with a jittered delay) instead of opening connections onto a saturated origin.
 * Returns true when it deferred — the caller must then return without
 * processing. Emits a bg.deferred counter (NOT captureException — expected,
 * self-healing load-shed).
 */
export function shedBatchIfHot(
  batch: ShedBatch,
  posthog: PostHog,
  queueLabel: string,
  nowMs: number = Date.now(),
  rng: () => number = Math.random
): boolean {
  const decision = shouldDefer(backgroundPressure, nowMs);
  if (!decision.defer) return false;
  for (const message of batch.messages) {
    message.retry({ delaySeconds: backoffDelaySeconds(message.attempts, rng) });
  }
  posthog.capture({
    distinctId: "system",
    event: "bg.deferred",
    properties: {
      queue: queueLabel,
      reason: decision.reason,
      batch_size: batch.messages.length,
      ewma_ms: Math.round(backgroundPressure.ewmaMs),
    },
  });
  return true;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pnpm --filter @plotday/api exec vitest run src/queue/shed.test.ts`
Expected: PASS.

- [ ] **Step 5: Wire the shed into the api queue dispatcher**

In `workers/api/src/queue/index.ts`, right after the logger is created and before the `try { switch ... }`:

```ts
import { shedBatchIfHot } from "./shed";
// ...
  if (shedBatchIfHot(batch, postHog, batch.queue)) {
    logger.warn("deferred queue batch under DB pressure", { queue: batch.queue });
    ctx.waitUntil(postHog.shutdown());
    return;
  }
```

- [ ] **Step 6: Wire the shed into the classify worker**

In `workers/classify/src/index.ts`, at the top of the `queue` handler after `batchCache` is created and before the `withDb` call, reuse the same guard (import directly from worker-util to avoid a cross-worker import of the api `shed.ts`):

```ts
import {
  backgroundPressure,
  shouldDefer,
  backoffDelaySeconds,
} from "@plotday/worker-util";
// ...
    const decision = shouldDefer(backgroundPressure, Date.now());
    if (decision.defer) {
      for (const message of batch.messages) {
        message.retry({ delaySeconds: backoffDelaySeconds(message.attempts) });
      }
      posthog.capture({
        distinctId: "system",
        event: "bg.deferred",
        properties: { queue: "classify-thread", reason: decision.reason },
      });
      logger.warn("deferred classify batch under DB pressure", {
        reason: decision.reason,
      });
      ctx.waitUntil(posthog.shutdown());
      return;
    }
```

- [ ] **Step 7: Lint + run both workers' suites**

Run: `pnpm --filter @plotday/api run lint && pnpm --filter @plotday/classify run lint && pnpm --filter @plotday/api exec vitest run src/queue && pnpm --filter @plotday/classify exec vitest run`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add workers/api/src/queue/shed.ts workers/api/src/queue/shed.test.ts workers/api/src/queue/index.ts workers/classify/src/index.ts
git commit -m "feat(queue): shed background batches when DB pressure is high"
```

---

### Task 8: Add the `bg.timeout_abort` counter to classify mid-batch timeout handling

**Files:**
- Modify: `workers/classify/src/index.ts` (the `isStatementTimeoutError` branch, ~line 139–187)

**Interfaces:**
- Consumes: `recordTimeout`, `backgroundPressure` from Task 5; `backoffDelaySeconds` (already imported in Task 7). This adds the second observability counter named in the spec, records the timeout into the pressure signal (its correct home — see Task 6 Step 4), and makes the classify worker stop processing the rest of a batch once it has timed out (so it does not keep hammering a hot DB mid-batch).

- [ ] **Step 1: Record the timeout into the pressure signal**

In `workers/classify/src/index.ts`, ensure `recordTimeout` and `backgroundPressure` are imported from `@plotday/worker-util` (Task 7 already added `backgroundPressure`, `shouldDefer`, `backoffDelaySeconds` — extend that import with `recordTimeout`). At the **top** of the existing `isStatementTimeoutError(err)` branch (before the `classify.deferred_timeout` capture), add:

```ts
            } else if (isStatementTimeoutError(err)) {
              recordTimeout(backgroundPressure, Date.now());
              // ...existing classify.deferred_timeout capture + warn...
```

- [ ] **Step 2: On a statement-timeout, defer the REMAINING messages too**

Today the `isStatementTimeoutError` branch acks the single message and continues the loop to the next one — which immediately opens another query onto the same saturated backend. Change it to defer the rest of the batch. Replace the body of that branch's tail (after the existing `posthog.capture({ event: "classify.deferred_timeout", ... })` and `logger.warn(...)`) so that instead of just `message.ack()` it acks the current message and re-queues every *remaining* message with a backoff, then breaks the loop:

```ts
              // (existing) record the deferral counter + warn ...
              message.ack();
              // Mid-batch saturation: stop hammering. Re-queue the rest of this
              // batch with a backoff and break — the hourly sweep + these delayed
              // retries pick them up once contention clears.
              const idx = batch.messages.indexOf(message);
              const remaining = batch.messages.slice(idx + 1);
              for (const m of remaining) {
                m.retry({ delaySeconds: backoffDelaySeconds(m.attempts) });
              }
              posthog.capture({
                distinctId: job.userId,
                event: "bg.timeout_abort",
                properties: {
                  threadId: job.threadId,
                  remaining: remaining.length,
                },
              });
              return; // exit the withDb callback; finally shuts posthog down
```

(`backoffDelaySeconds` is already imported in Task 7. The `return` exits the `withDb` callback; the outer `finally` still runs `ctx.waitUntil(posthog.shutdown())`.)

- [ ] **Step 3: Lint + run the classify suite**

Run: `pnpm --filter @plotday/classify run lint && pnpm --filter @plotday/classify exec vitest run`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add workers/classify/src/index.ts
git commit -m "feat(classify): abort the rest of a batch on mid-flight DB timeout"
```

---

### Task 9: Provision the second Hyperdrive config (infra + runbook)

**Files:**
- Modify: `infra/hyperdrive/hyperdrive.tf` (drop existing limit to 50; add the `plot_prod_bg` resource at 30)
- Modify: `scripts/deploy-hyperdrive` (manage both configs' limits)
- Create: `infra/hyperdrive/README-bg-lane.md` (the one-time create + apply runbook)

**Interfaces:**
- Produces: the real `HYPERDRIVE_BG` config id that replaces the `REPLACE_WITH_HYPERDRIVE_BG_ID` placeholder from Task 1.

This task's production mutations (creating the Cloudflare config, resizing pools) are run by the user per the runbook — not by the agent. The agent authors the Terraform/script/runbook and verifies they parse.

- [ ] **Step 1: Lower the existing config to 50 and add the background config**

In `infra/hyperdrive/hyperdrive.tf`, change `origin_connection_limit = 80` to `50` on `plot_prod`, and append a second resource (same origin, limit 30):

```hcl
resource "cloudflare_hyperdrive_config" "plot_prod_bg" {
  account_id = "34ceb662899230b63c7e8114eaf9277c"
  name       = "plot-prod-bg"

  origin = {
    scheme               = "postgres"
    host                 = "34.130.85.92"
    port                 = 5432
    database             = "plot"
    user                 = "api"
    password             = "MANAGED_OUTSIDE_TERRAFORM" # ignored (see header)
    access_client_id     = null
    access_client_secret = null
    service_id           = null
  }

  caching = {
    disabled               = true
    max_age                = null
    stale_while_revalidate = null
  }

  mtls = {
    ca_certificate_id   = null
    mtls_certificate_id = null
    sslmode             = null
  }

  origin_connection_limit = 30

  lifecycle {
    ignore_changes = [origin.password]
  }
}
```

Update the file header comment so the "80" sizing note reads "50 (frontend) + 30 (background) = 80".

- [ ] **Step 2: Teach `deploy-hyperdrive` about both configs**

In `scripts/deploy-hyperdrive`, replace the single `HYPERDRIVE_ID` / `ORIGIN_CONNECTION_LIMIT` constants with a frontend pair and a background pair (frontend 50, background 30), and run the partial-update for each. Keep the before/after `wrangler hyperdrive get` print for both. Concretely, change the versioned-source-of-truth block to:

```bash
FRONTEND_HYPERDRIVE_ID="831ea7d10ef54346b084baaa1a46dfa6"
FRONTEND_CONNECTION_LIMIT="${FRONTEND_CONNECTION_LIMIT:-50}"
BG_HYPERDRIVE_ID="${BG_HYPERDRIVE_ID:-REPLACE_WITH_HYPERDRIVE_BG_ID}"
BG_CONNECTION_LIMIT="${BG_CONNECTION_LIMIT:-30}"
```

and apply the existing partial-update command once per (id, limit) pair.

- [ ] **Step 3: Write the create runbook**

Create `infra/hyperdrive/README-bg-lane.md` with the one-time steps the user runs (these are production mutations — agent does not run them):

```markdown
# Creating the HYPERDRIVE_BG background-lane config

One-time, run by a human with Cloudflare + Cloud SQL access.

1. Create the config (same origin as plot-prod, limit 30). From `workers/api`:

       pnpm wrangler hyperdrive create plot-prod-bg \
         --connection-string="postgres://api:<PASSWORD>@34.130.85.92:5432/plot" \
         --origin-connection-limit=30

   Copy the printed config **id**.

2. Replace `REPLACE_WITH_HYPERDRIVE_BG_ID` with that id in:
   - `workers/api/wrangler.jsonc`
   - `workers/classify/wrangler.jsonc`
   - `scripts/deploy-hyperdrive` (BG_HYPERDRIVE_ID)

3. Lower the frontend pool to 50 and confirm the background pool at 30:

       pnpm --filter @plotday/api run deploy:hyperdrive   # or: bash scripts/deploy-hyperdrive

4. Import the new config into Terraform state (keeps `plan` at zero-diff):

       cd infra/hyperdrive
       terraform import cloudflare_hyperdrive_config.plot_prod_bg <account_id>/<config_id>
       terraform plan   # expect: No changes

5. Deploy api + classify (CI on merge, or manual) so both bind HYPERDRIVE_BG.

Verify: `wrangler hyperdrive get <FRONTEND_ID>` shows 50 and
`wrangler hyperdrive get <BG_ID>` shows 30; sum (80) ≤ ~97 usable origin conns.
```

- [ ] **Step 4: Validate Terraform + script parse**

Run:
```bash
cd infra/hyperdrive && terraform fmt -check && terraform validate
bash -n ../../scripts/deploy-hyperdrive
```
Expected: `terraform validate` → "Success"; `bash -n` → no output (valid syntax). (`terraform plan` is **not** run here — it would require credentials and would show the new resource as needing creation until the user imports it per the runbook.)

- [ ] **Step 5: Commit**

```bash
git add infra/hyperdrive/hyperdrive.tf infra/hyperdrive/README-bg-lane.md scripts/deploy-hyperdrive
git commit -m "feat(infra): background-lane Hyperdrive config (50/30 split) + runbook"
```

---

### Task 10: Finalize

**Files:**
- Modify: `docs/updates.md` (skip — this is infra, not user-facing)
- Verify only: repo-wide lint + the audit greps.

- [ ] **Step 1: Confirm no background site was left on the frontend lane and vice-versa**

Run from repo root:
```bash
# Frontend (c.env) sites must all use the frontend factory:
grep -rn --include='*.ts' -E 'createDb\(c\.env\)|withDb\(c\.env' workers/api/src | grep -v '.test.ts' || echo "OK: no c.env on default factory"
# Background entry points must NOT use the frontend factory:
grep -rn --include='*.ts' -E 'createFrontendDb\(env\)|withFrontendDb\(env' workers/api/src && echo "WARN: frontend factory on a background (env) site" || echo "OK: no frontend factory on env sites"
```
Expected: both print their `OK:` line.

- [ ] **Step 2: Run the finalize checklist (lint across changed packages)**

Run:
```bash
pnpm --filter @plotday/worker-util run lint
pnpm --filter @plotday/api run lint
pnpm --filter @plotday/classify run lint
```
Expected: all PASS. (No schema change → no `gen-migration` / `db:lint`. No user-facing behavior → no `docs/updates.md` entry.)

- [ ] **Step 3: Run the full test suites for the three changed packages**

Run:
```bash
pnpm --filter @plotday/worker-util exec vitest run
pnpm --filter @plotday/api exec vitest run
pnpm --filter @plotday/classify exec vitest run
```
Expected: PASS.

- [ ] **Step 4: Commit any lint fixes**

```bash
git add -A
git commit -m "chore: finalize background DB isolation (lint + audit)" || echo "nothing to commit"
```

---

## Notes for the implementer

- **Why background is the default lane.** Flipping `createDb`/`withDb` to the capped pool means any call site we miss (or any *future* queue/DO code) lands on the background lane and therefore **cannot** starve the frontend's reserved 50. The only sites that must be explicitly moved are the request-context (`c.env`) ones — a small, greppable set.
- **The guard is best-effort and read-side coarse.** Latency recording is hooked into the background `withDb` startup probe, which covers the queue processors (the bulk of background DB volume). Durable Objects that call `createDb(env)` directly (e.g. `state/twist-sync.ts`) are not individually instrumented; the dispatcher-level shed plus timeout recording still protect the frontend, and the spec scopes the guard as best-effort. If a DO path later proves to be a heavy contributor, instrument its `createDb` site the same way.
- **Deferral is never a drop.** Every shed path re-queues with a delay (or, for classify statement-timeouts, leaves `classify_at` set for the hourly sweep). Work is delayed under saturation, not lost.
- **Read replica + dedicated DB role remain deferred** (see the design doc's §6/§7). This plan delivers Channel A fully and Channel B partially; the replica is the eventual full Channel-B fix, gated on re-measuring primary CPU after this ships.
```

