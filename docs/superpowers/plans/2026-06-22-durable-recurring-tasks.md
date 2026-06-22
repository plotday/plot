# Durable Recurring Tasks + Backstop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a recurring task's continuation durable and platform-owned in the `CallbacksState` Durable Object, so a dropped queue message, a suspension, a deploy/eviction, or a throwing callback costs at most one beat — never the whole chain — and add a thin backstop that resurrects chains that died before the fix.

**Architecture:** A new `recurring_interval_ms` column on the DO's `callbacks` table makes a scheduled row self-advancing: `alarm()` re-arms `call_at = now + interval` *at fire time, in the `finally`*, instead of deleting the row, so the next occurrence is persisted independent of whether the queue hand-off succeeds. `intervalMs` is a safety ceiling clamped in `create()`; connectors may pull the next fire earlier (precise renewal timing) but never later. A new `scheduleRecurring()` SDK method wraps this. A `RUN_QUEUE` dead-letter queue makes storm-dropped beats visible. A low-frequency cron sweep + deploy-time `upgrade()` re-assert resurrect chains with no live row.

**Tech Stack:** TypeScript, Cloudflare Workers + Durable Objects (SQLite storage, alarms), Cloudflare Queues, `@cloudflare/vitest-pool-workers` (DO tests), node-env vitest + Postgres (`recover-stuck-syncs`-style sweep tests), `@plotday/twister` SDK (changeset required), Kysely.

## Global Constraints

- **DO SQLite schema** changes use migration-safe `ALTER TABLE ADD COLUMN` wrapped in try/catch, exactly like the existing `task_key`/`key`/`meta` adds in `initializeTable()`. NO Postgres migration is introduced by this plan.
- **`workers/api/src/twist/entrypoint.ts` is consumed as a template literal** — never touched here, but if a backtick is ever added to a file it bundles, escape it as `` \` ``.
- **Twister SDK change requires a changeset** at `public/.changeset/<name>.md`, `"@plotday/twister": minor`, summary starting `Added:`. Validate with `cd public && pnpm validate-changesets`.
- **Twister types are edited only in `public/twister/src/`**, then `cd public/twister && pnpm build`, then `pnpm install` at repo root.
- **`public/` is a git submodule.** Branch it before editing: `cd public && git checkout -b durable-recurring-tasks`. Submodule changes are a separate PR/commit.
- **Backward compatibility:** `recurring_interval_ms IS NULL` ⇒ today's one-shot behavior, unchanged. Deployed callbacks and existing rows are unaffected. `scheduleRecurring` is additive (no existing signature changes).
- **Error capture:** any new `catch` for an *unexpected* error calls `tracker.captureException(error)` / `postHog.captureException(error, distinctId)`. Do NOT capture expected conditions.
- **DO tests** live in `workers/api/src/state/__tests__/*.test.ts` and run via `pnpm --filter @plotday/api test:integration` (vitest-pool-workers, `wrangler.test.jsonc` binds `RUN_QUEUE`=`run-test` and `CALLBACKS`). **Node/Postgres sweep tests** live in `workers/api/src/scheduled/*.test.ts` and run via `pnpm --filter @plotday/api test` with `$DATABASE_URL` set.
- **Connectors:** migrate BOTH `public/connectors/*` (submodule) AND `connectors/*` (private). Private connectors have no recurring chains (verified) but stay in the sweep.

---

## Phase 1 — Durable recurring primitive in the DO

### Task 1: `recurring_interval_ms` column + `create()` clamp & marker

**Files:**
- Modify: `workers/api/src/state/callbacks.ts` (`initializeTable()`, `create()`)
- Test: `workers/api/src/state/__tests__/callbacks-recurring.test.ts` (create)

**Interfaces:**
- Produces: `create({ …, recurringIntervalMs?: number })` — when set, stores `recurring_interval_ms`, forces `call_once = 0`, requires `taskKey`, and clamps `call_at = min(callAt ?? now, now + recurringIntervalMs)`. Also records a durable "this instance expects a recurring task" marker.
- Produces: stored `recurring_interval_ms` readable via the row.

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/state/__tests__/callbacks-recurring.test.ts`:

```typescript
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import type { CallbacksState } from "../callbacks";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    CALLBACKS: DurableObjectNamespace<CallbacksState>;
    RUN_QUEUE: Queue<unknown>;
  }
}

const TWIST_INSTANCE = "22222222-2222-2222-2222-222222222222";

function getCallbacks(name: string): DurableObjectStub<CallbacksState> {
  return env.CALLBACKS.get(env.CALLBACKS.idFromName(name));
}

function createRecurring(
  stub: DurableObjectStub<CallbacksState>,
  opts: { taskKey: string; intervalMs: number; firstRunAt?: Date }
): Promise<string> {
  return stub.create({
    twistInstanceId: TWIST_INSTANCE,
    path: ["tasks"],
    version: "test",
    functionName: "scheduledSend",
    extraArgs: ["inner-callback-token"],
    callAt: opts.firstRunAt,
    taskKey: opts.taskKey,
    recurringIntervalMs: opts.intervalMs,
  });
}

describe("CallbacksState recurring create()", () => {
  let stub: DurableObjectStub<CallbacksState>;
  beforeEach(() => {
    stub = getCallbacks(`recurring-${crypto.randomUUID()}`);
  });

  it("clamps call_at to no later than now + intervalMs", async () => {
    const interval = 60 * 60 * 1000; // 1h
    // firstRunAt far in the future (10h) must be clamped down to ~now+1h.
    const token = await createRecurring(stub, {
      taskKey: "poll:1",
      intervalMs: interval,
      firstRunAt: new Date(Date.now() + 10 * 60 * 60 * 1000),
    });
    const loaded = await stub.validateAndLoad(token);
    if ("__error" in loaded) throw new Error("row missing");
    const callAt = loaded.callback.callAt!.getTime();
    expect(callAt).toBeLessThanOrEqual(Date.now() + interval + 1000);
    expect(callAt).toBeGreaterThan(Date.now() + interval - 5 * 60 * 1000);
  });

  it("keeps an earlier firstRunAt (ceiling pulls earlier, never later)", async () => {
    const interval = 60 * 60 * 1000;
    const soon = new Date(Date.now() + 5 * 60 * 1000); // 5 min
    const token = await createRecurring(stub, {
      taskKey: "renew:1",
      intervalMs: interval,
      firstRunAt: soon,
    });
    const loaded = await stub.validateAndLoad(token);
    if ("__error" in loaded) throw new Error("row missing");
    expect(loaded.callback.callAt!.getTime()).toBe(soon.getTime());
  });
});
```

(The `recurring_meta` "ever" marker set here is observed via `needsRecurringRecovery` in Task 3's tests, so it has no separate test in this task.)

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/api test:integration callbacks-recurring`
Expected: FAIL — `recurringIntervalMs` not accepted / `needsRecurringRecovery` is not a function.

- [ ] **Step 3: Add the column + marker table in `initializeTable()`**

In `workers/api/src/state/callbacks.ts`, after the `task_key` column/index block in `initializeTable()`, add:

```typescript
    // Recurring tasks: when non-null, the alarm advances call_at by this
    // interval instead of deleting the row, so the chain's continuation lives
    // in the durable DO, not a transient queue message. Always paired with a
    // task_key (recurring is keyed/singleton).
    try {
      this.sql.exec("ALTER TABLE callbacks ADD COLUMN recurring_interval_ms INTEGER");
    } catch (e) {
      // Column already exists
    }

    // Durable "this twist_instance has ever registered a recurring task"
    // marker. Set on the first recurring create(); never cleared. Drives the
    // backstop sweep's needsRecurringRecovery(): a marked instance with no live
    // recurring row had its chain die and should be re-asserted. Pre-migration
    // dead chains have no marker — those are resurrected by the connector's
    // upgrade() re-assert instead.
    this.sql.exec(`
        CREATE TABLE IF NOT EXISTS recurring_meta (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          ever INTEGER NOT NULL DEFAULT 0
        )
      `);
```

- [ ] **Step 4: Add `recurringIntervalMs` to `create()`**

In `create()`'s destructured params (the `{ … }: { … }` block), add `recurringIntervalMs?: number;` to both the value and the type. Then change the `callOnce` default and the INSERT:

```typescript
    // Default callOnce to true if callAt is specified, false otherwise.
    // Recurring tasks are never callOnce — the alarm advances them instead.
    callOnce ??= callAt !== undefined;
    if (recurringIntervalMs !== undefined) {
      callOnce = false;
      // Safety-ceiling clamp: the next fire may be pulled earlier than the
      // ceiling but never later, so liveness is guaranteed even when a
      // connector forgets (or fails) to re-register a precise next time.
      const ceiling = Date.now() + recurringIntervalMs;
      const requested = callAt ? callAt.getTime() : ceiling;
      callAt = new Date(Math.min(requested, ceiling));
    }
```

Add `recurring_interval_ms` to the INSERT column list and values (after `task_key`):

```typescript
    this.sql.exec(
      `
        INSERT INTO callbacks (
          token, twist_instance_id, path, version, function_name, extra_args, call_at, call_once, expires, key, meta, task_key, recurring_interval_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `,
      token,
      twistInstanceId,
      superjson.stringify(path),
      version,
      functionName,
      extraArgs ? superjson.stringify(extraArgs) : null,
      callAt ? callAt.getTime() : null,
      callOnce ? 1 : 0,
      expires ? expires.getTime() : null,
      key ?? null,
      meta ? superjson.stringify(meta) : null,
      taskKey ?? null,
      recurringIntervalMs ?? null
    );

    if (recurringIntervalMs !== undefined) {
      this.sql.exec(
        "INSERT OR REPLACE INTO recurring_meta (id, ever) VALUES (1, 1)"
      );
    }
```

(This task adds the column, clamp, and `recurring_meta` marker only. The DO methods that read the marker are Task 3.)

- [ ] **Step 5: Run test to verify it passes**

Run: `pnpm --filter @plotday/api test:integration callbacks-recurring`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/state/callbacks.ts workers/api/src/state/__tests__/callbacks-recurring.test.ts
git commit -m "feat(callbacks): recurring_interval_ms column + create() ceiling clamp"
```

---

### Task 2: `alarm()` advances recurring rows instead of deleting

**Files:**
- Modify: `workers/api/src/state/callbacks.ts` (`alarm()`)
- Test: `workers/api/src/state/__tests__/callbacks-recurring.test.ts` (add cases)

**Interfaces:**
- Consumes: `recurring_interval_ms` column (Task 1).
- Produces: after `alarm()` fires a recurring row, the row still exists with `call_at` advanced to `now + recurring_interval_ms`; one-shot rows still delete/null as before.

- [ ] **Step 1: Write the failing test**

First, add `runInDurableObject` to the existing top-of-file `cloudflare:test` import:

```typescript
import { env, runInDurableObject } from "cloudflare:test";
```

Then append to `callbacks-recurring.test.ts`:

```typescript
describe("CallbacksState recurring alarm()", () => {
  let stub: DurableObjectStub<CallbacksState>;
  beforeEach(() => {
    stub = getCallbacks(`recurring-alarm-${crypto.randomUUID()}`);
  });

  it("advances a due recurring row instead of deleting it", async () => {
    const interval = 60 * 60 * 1000; // 1h
    // Past firstRunAt → clamped to past → due immediately.
    const token = await createRecurring(stub, {
      taskKey: "poll:1",
      intervalMs: interval,
      firstRunAt: new Date(Date.now() - 1000),
    });

    await runInDurableObject(stub, (instance: CallbacksState) => instance.alarm());

    const loaded = await stub.validateAndLoad(token);
    if ("__error" in loaded) throw new Error("recurring row was deleted");
    const callAt = loaded.callback.callAt!.getTime();
    expect(callAt).toBeGreaterThan(Date.now() + interval - 5000);
    expect(callAt).toBeLessThan(Date.now() + interval + 5000);
  });

  it("advances even when the row was the only one (re-arms alarm)", async () => {
    const interval = 30 * 60 * 1000;
    await createRecurring(stub, {
      taskKey: "renew:1",
      intervalMs: interval,
      firstRunAt: new Date(Date.now() - 1000),
    });
    await runInDurableObject(stub, (instance: CallbacksState) => instance.alarm());
    // A live recurring row remains → reconcile sees the chain as alive.
    expect(await stub.hasLiveRecurringTask(TWIST_INSTANCE)).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/api test:integration callbacks-recurring`
Expected: FAIL — recurring row deleted by the `callOnce` path; `hasLiveRecurringTask` not a function (added in Task 3 — implement Task 3 first or together).

- [ ] **Step 3: Update `alarm()` to advance recurring rows**

In `alarm()`, add `recurring_interval_ms` to the SELECT:

```typescript
    const callbackResults = this.sql.exec(
      `
        SELECT token, twist_instance_id, path, function_name, extra_args, call_once, recurring_interval_ms
        FROM callbacks
        WHERE call_at IS NOT NULL
          AND call_at <= ?
        ORDER BY call_at ASC
      `,
      [now]
    );
```

In the `scheduledSend` branch's `finally`, replace the delete/null block with a recurring-aware one:

```typescript
        } finally {
          const recurringIntervalMs = row.recurring_interval_ms as number | null;
          if (recurringIntervalMs != null) {
            // Recurring: advance the SAME row so the next occurrence is durably
            // persisted regardless of whether the enqueue above succeeded. This
            // is the whole fix — the continuation lives here, not in the queue
            // message. Runs in finally so a failed enqueue still re-arms.
            this.sql.exec(
              "UPDATE callbacks SET call_at = ? WHERE token = ?",
              Date.now() + recurringIntervalMs,
              token
            );
          } else if (Number(row.call_once) === 1) {
            this.sql.exec("DELETE FROM callbacks WHERE token = ?", token);
          } else {
            this.sql.exec(
              "UPDATE callbacks SET call_at = NULL WHERE token = ?",
              token
            );
          }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/api test:integration callbacks-recurring`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/state/callbacks.ts workers/api/src/state/__tests__/callbacks-recurring.test.ts
git commit -m "feat(callbacks): alarm advances recurring rows instead of deleting"
```

---

### Task 3: `hasLiveRecurringTask` + `needsRecurringRecovery` DO methods

**Files:**
- Modify: `workers/api/src/state/callbacks.ts` (new public methods)
- Test: `workers/api/src/state/__tests__/callbacks-recurring.test.ts` (add cases)

**Interfaces:**
- Produces: `hasLiveRecurringTask(twistInstanceId: string): boolean` — true iff a row with `recurring_interval_ms IS NOT NULL` exists.
- Produces: `needsRecurringRecovery(twistInstanceId: string): boolean` — true iff `recurring_meta.ever = 1` AND no live recurring row. Drives the backstop sweep.

- [ ] **Step 1: Write the failing test**

Append:

```typescript
describe("CallbacksState recurring liveness", () => {
  let stub: DurableObjectStub<CallbacksState>;
  beforeEach(() => {
    stub = getCallbacks(`recurring-live-${crypto.randomUUID()}`);
  });

  it("hasLiveRecurringTask reflects presence of a recurring row", async () => {
    expect(await stub.hasLiveRecurringTask(TWIST_INSTANCE)).toBe(false);
    await createRecurring(stub, { taskKey: "poll:1", intervalMs: 60_000 });
    expect(await stub.hasLiveRecurringTask(TWIST_INSTANCE)).toBe(true);
  });

  it("needsRecurringRecovery is true only after a recurring task is cancelled", async () => {
    expect(await stub.needsRecurringRecovery(TWIST_INSTANCE)).toBe(false); // never registered
    const token = await createRecurring(stub, { taskKey: "poll:1", intervalMs: 60_000 });
    expect(await stub.needsRecurringRecovery(TWIST_INSTANCE)).toBe(false); // live
    await stub.deleteByTaskKey(TWIST_INSTANCE, "poll:1");
    expect(await stub.needsRecurringRecovery(TWIST_INSTANCE)).toBe(true); // marked + no live row
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/api test:integration callbacks-recurring`
Expected: FAIL — methods not defined.

- [ ] **Step 3: Implement the methods**

Add to `CallbacksState` (near `nextScheduledCallbackAt`):

```typescript
  /**
   * True iff this twist_instance has at least one live recurring task (a
   * self-advancing scheduled row). The backstop sweep uses this as the liveness
   * signal for periodic maintenance chains.
   */
  hasLiveRecurringTask(twistInstanceId: string): boolean {
    const result = this.sql
      .exec(
        `SELECT 1 FROM callbacks
         WHERE twist_instance_id = ? AND recurring_interval_ms IS NOT NULL
         LIMIT 1`,
        twistInstanceId
      )
      .next();
    return !result.done;
  }

  /**
   * True iff this instance has EVER registered a recurring task but has none
   * live now — i.e. a periodic maintenance chain that died and should be
   * re-asserted by the backstop sweep. Instances that never registered one
   * (webhook-only connectors) return false, so they are never falsely flagged.
   */
  needsRecurringRecovery(twistInstanceId: string): boolean {
    const meta = this.sql
      .exec("SELECT ever FROM recurring_meta WHERE id = 1")
      .next();
    const ever = !meta.done && Number((meta.value as any).ever) === 1;
    if (!ever) return false;
    return !this.hasLiveRecurringTask(twistInstanceId);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/api test:integration callbacks-recurring`
Expected: PASS (all recurring tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/state/callbacks.ts workers/api/src/state/__tests__/callbacks-recurring.test.ts
git commit -m "feat(callbacks): hasLiveRecurringTask + needsRecurringRecovery"
```

---

## Phase 2 — SDK primitive (`public/` submodule)

### Task 4: `scheduleRecurring` on the twister Tasks interface + changeset

**Files:**
- Branch submodule first: `cd public && git checkout -b durable-recurring-tasks`
- Modify: `public/twister/src/tools/tasks.ts` (add abstract `scheduleRecurring`)
- Create: `public/.changeset/durable-recurring-tasks.md`

**Interfaces:**
- Produces: `scheduleRecurring(key: string, callback: Callback, options: { intervalMs: number; firstRunAt?: Date }): Promise<void>`

- [ ] **Step 1: Add the abstract method**

In `public/twister/src/tools/tasks.ts`, after `cancelScheduledTask`, add:

```typescript
  /**
   * Schedules a **durable recurring** task identified by `key`. Unlike
   * {@link scheduleTask} (one-shot, deleted when it fires), a recurring task's
   * next occurrence is owned by the platform: the runtime re-arms it every
   * `intervalMs` automatically, so the chain survives a dropped queue message,
   * a suspension, a deploy/eviction, or a callback that throws before it could
   * reschedule. The callback just does the work, idempotently — it does NOT
   * need to reschedule itself.
   *
   * `intervalMs` is a **safety ceiling** (the maximum gap between fires). For
   * data-dependent cadence (e.g. renew 24h before a provider-returned expiry),
   * pass `firstRunAt` for the precise next fire and re-call `scheduleRecurring`
   * with the same key on each run to keep tightening it; the ceiling guarantees
   * the chain still fires if a run is lost. `firstRunAt` can pull the next fire
   * earlier than the ceiling but never later.
   *
   * Recurring tasks are keyed/singleton: re-scheduling under the same key
   * atomically replaces the pending occurrence (one live task per key). Tear
   * down with {@link cancelScheduledTask}.
   *
   * @param key - Stable identifier, scoped to what it maintains, e.g.
   *   `` `watch-renewal:${folderId}` `` or `"mailbox-self-heal"`.
   * @param callback - Callback created with `this.callback()`.
   * @param options.intervalMs - Safety-ceiling cadence in milliseconds.
   * @param options.firstRunAt - Optional precise time for the next fire
   *   (clamped to no later than now + intervalMs).
   *
   * @example
   * ```typescript
   * // Fixed cadence (self-heal, polling): register once, never reschedule.
   * const cb = await this.callback(this.selfHealCheck);
   * await this.scheduleRecurring("mailbox-self-heal", cb, { intervalMs: 60 * 60 * 1000 });
   *
   * // Variable cadence (watch renewal): precise firstRunAt + safety ceiling.
   * const renew = await this.callback(this.renewWatch, folderId);
   * await this.scheduleRecurring(`watch-renewal:${folderId}`, renew, {
   *   intervalMs: 3.5 * 24 * 60 * 60 * 1000,   // ceiling: half the 7-day watch
   *   firstRunAt: new Date(expiry.getTime() - 24 * 60 * 60 * 1000),
   * });
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract scheduleRecurring(
    key: string,
    callback: Callback,
    options: { intervalMs: number; firstRunAt?: Date }
  ): Promise<void>;
```

- [ ] **Step 2: Create the changeset**

`public/.changeset/durable-recurring-tasks.md`:

```markdown
---
"@plotday/twister": minor
---

Added: Tasks.scheduleRecurring(key, callback, { intervalMs, firstRunAt }) — a durable recurring task whose cadence is owned by the platform, so periodic chains (watch renewals, self-heal, polling) survive dropped runs, suspensions, and deploys instead of dying silently.
```

- [ ] **Step 3: Build twister + validate changeset**

Run:
```bash
cd public/twister && pnpm build
cd .. && pnpm validate-changesets
```
Expected: build succeeds; changeset validates.

- [ ] **Step 4: Refresh the workspace link**

Run: `cd /Users/kris.braun/code/plot/.claude/worktrees/durable-recurring-tasks && pnpm install`
Expected: no errors.

- [ ] **Step 5: Commit (submodule)**

```bash
cd public
git add twister/src/tools/tasks.ts .changeset/durable-recurring-tasks.md
git commit -m "feat(twister): add Tasks.scheduleRecurring durable recurring primitive"
cd ..
```

---

### Task 5: `scheduleRecurring` implementation in the api Tasks tool

**Files:**
- Modify: `workers/api/src/twist/tools/tasks.ts` (implement `scheduleRecurring`)
- Test: `workers/api/src/state/__tests__/callbacks-recurring.test.ts` (already covers the DO path; add an SDK-level smoke test only if the Tasks tool can be unit-constructed — otherwise rely on connector build + the DO tests).

**Interfaces:**
- Consumes: `CallbacksState.create({ recurringIntervalMs })` (Task 1).
- Produces: `Tasks.scheduleRecurring(key, callback, { intervalMs, firstRunAt })`.

- [ ] **Step 1: Implement the method**

In `workers/api/src/twist/tools/tasks.ts`, after `cancelScheduledTask`, add:

```typescript
  async scheduleRecurring(
    key: string,
    callback: Callback,
    options: { intervalMs: number; firstRunAt?: Date }
  ): Promise<void> {
    // Durable recurring wrapper: same scheduledSend shape as scheduleTask, but
    // tagged with recurringIntervalMs so the DO alarm advances the row at fire
    // time (owning the cadence) instead of deleting it. Keyed, so re-scheduling
    // atomically replaces the pending occurrence.
    await this.callbacks.create({
      twistInstanceId: this.twistInstanceId,
      path: this.selfPath,
      functionName: "scheduledSend",
      extraArgs: [callback],
      callAt: options.firstRunAt,
      taskKey: key,
      recurringIntervalMs: options.intervalMs,
    });
  }
```

- [ ] **Step 2: Verify type + lint**

Run: `pnpm --filter @plotday/api exec tsc --noEmit && pnpm --filter @plotday/api lint`
Expected: no errors (the `IRun` interface from twister now declares `scheduleRecurring`, so the class satisfies it).

- [ ] **Step 3: Run the DO recurring tests (regression)**

Run: `pnpm --filter @plotday/api test:integration callbacks-recurring`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/twist/tools/tasks.ts
git commit -m "feat(tasks): implement scheduleRecurring over the DO recurring primitive"
```

---

## Phase 3 — `RUN_QUEUE` dead-letter queue

### Task 6: Add a dead-letter queue + consumer for `RUN_QUEUE`

**Files:**
- Modify: `workers/api/wrangler.jsonc` (development + production `RUN_QUEUE` consumer; new producer + consumer for the DLQ)
- Modify: `workers/api/wrangler.test.jsonc` (mirror so tests bind the DLQ)
- Create: `workers/api/src/twist/run-dlq.ts` (DLQ consumer handler)
- Modify: `workers/api/src/index.ts` (route the `run-dlq-*` queue to the handler)
- Test: `workers/api/src/twist/run-dlq.test.ts`

**Interfaces:**
- Produces: `handleRunDlq(env, batch, postHog): Promise<void>` — logs + owner-attributed `captureException` for each dead-lettered `RunMessage`, then `ack()`s (terminal).

- [ ] **Step 1: Write the failing test**

`workers/api/src/twist/run-dlq.test.ts` (node env — pure handler over a fake batch):

```typescript
import { describe, expect, it, vi } from "vitest";
import { handleRunDlq } from "./run-dlq";

function fakeBatch(bodies: any[]) {
  const acks: number[] = [];
  return {
    queue: "run-dlq-test",
    messages: bodies.map((body, i) => ({
      body,
      attempts: 4,
      ack: () => acks.push(i),
      retry: () => {},
    })),
    _acks: acks,
  } as any;
}

describe("handleRunDlq", () => {
  it("captures each dead-lettered message and acks it", async () => {
    const capture = vi.fn();
    const postHog = { captureException: capture } as any;
    const batch = fakeBatch([
      { twistInstanceId: "ti-1", path: ["tasks"], token: "do:tok" },
    ]);
    await handleRunDlq({} as any, batch, postHog);
    expect(capture).toHaveBeenCalledTimes(1);
    expect(batch._acks).toEqual([0]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/api test run-dlq`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the DLQ handler**

`workers/api/src/twist/run-dlq.ts`:

```typescript
import type { PostHog } from "posthog-node";
import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { extractRunQueueContext } from "../utils/log-context";
import type { RunMessage } from "./tools/tasks";

/**
 * Dead-letter consumer for RUN_QUEUE. A scheduled task message lands here only
 * after exhausting its retries (e.g. a transient DB/Hyperdrive storm). Without
 * this, the message was silently dropped and — for recurring chains — the next
 * occurrence would be lost. Recurring tasks now self-heal (the DO alarm re-arms
 * the next beat), so this consumer's job is OBSERVABILITY: surface the drop so a
 * persistent failure isn't invisible. Terminal: always ack.
 */
export async function handleRunDlq(
  env: Bindings,
  batch: MessageBatch<RunMessage>,
  postHog: PostHog
): Promise<void> {
  for (const message of batch.messages) {
    const context = extractRunQueueContext(message.body, batch.queue);
    const logger = createLogger({ ...context, attempts: message.attempts });
    logger.error(
      "RunMessage dead-lettered",
      new Error("RUN_QUEUE message exhausted retries"),
      { outcome: "dead_letter" }
    );
    postHog.captureException(
      new Error(`RUN_QUEUE dead-letter: ${message.body.path?.join("/")}`),
      message.body.twistInstanceId,
      { twist_instance_id: message.body.twistInstanceId, queue: batch.queue }
    );
    message.ack();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/api test run-dlq`
Expected: PASS.

- [ ] **Step 5: Wire the queue config**

In `workers/api/wrangler.jsonc`, for BOTH `development` and `production`:
- Add a producer binding for the DLQ (optional; only needed if code sends to it — not required, Cloudflare routes dead letters automatically). Add the DLQ as a **consumer** and set it as the `RUN_QUEUE` consumer's `dead_letter_queue`. Development example:

```jsonc
// in queues.consumers, modify the run-development consumer:
{
  "queue": "run-development",
  "max_batch_size": 10,
  "max_batch_timeout": 5,
  "max_concurrency": 5,
  "max_retries": 3,
  "dead_letter_queue": "run-dlq-development"
},
// add a new consumer:
{
  "queue": "run-dlq-development",
  "max_batch_size": 10,
  "max_batch_timeout": 5,
  "max_concurrency": 1
}
```

Production: same shape with `run-production` → `dead_letter_queue: "run-dlq-production"` and a `run-dlq-production` consumer (keep `max_retries: 3` explicit to preserve today's effective behavior). Mirror the minimal binding into `workers/api/wrangler.test.jsonc` (`run-dlq-test`) so integration tests load.

- [ ] **Step 6: Route the DLQ in the queue handler**

In `workers/api/src/index.ts`, find the `queue(batch, env, ctx)` dispatch (where `batch.queue` is matched against `run-*`, `webhook-*`, etc.) and add a branch:

```typescript
    if (batch.queue.startsWith("run-dlq-")) {
      await handleRunDlq(env, batch as MessageBatch<RunMessage>, postHog);
      return;
    }
```

(Import `handleRunDlq` from `./twist/run-dlq` and `RunMessage` from `./twist/tools/tasks`. Place the branch BEFORE the generic `run-` branch so the DLQ isn't treated as a normal run message.)

- [ ] **Step 7: Verify dev config loads + tests pass**

Run: `pnpm --filter @plotday/api exec tsc --noEmit && pnpm --filter @plotday/api test run-dlq`
Expected: typecheck clean, test passes.

- [ ] **Step 8: Commit**

```bash
git add workers/api/wrangler.jsonc workers/api/wrangler.test.jsonc workers/api/src/twist/run-dlq.ts workers/api/src/twist/run-dlq.test.ts workers/api/src/index.ts
git commit -m "feat(run-queue): dead-letter queue makes dropped task beats observable"
```

---

## Phase 4 — Thin backstop sweep

### Task 7: Recurring-maintenance reconcile sweep

**Files:**
- Create: `workers/api/src/scheduled/recover-recurring-maintenance.ts`
- Test: `workers/api/src/scheduled/recover-recurring-maintenance.test.ts`
- Modify: `workers/api/src/index.ts` (call it in the existing 30-min recovery branch)

**Interfaces:**
- Consumes: `CallbacksState.needsRecurringRecovery(twistInstanceId)` (Task 3); the existing `twist_instance_connection` recovery columns (`recovery_pending`) and the existing recover-pending re-dispatch.
- Produces: `selectActiveMaintenanceConnections(db): Promise<MaintenanceCandidate[]>` and `recoverRecurringMaintenance(env, ctx): Promise<void>`.

- [ ] **Step 1: Write the failing test**

`recover-recurring-maintenance.test.ts` mirrors `recover-stuck-syncs.test.ts` (node env, real `$DATABASE_URL`, seed-and-rollback). Test `selectActiveMaintenanceConnections` returns only active, non-archived/suspended/draft, non-reauth connections:

```typescript
import { randomUUID } from "node:crypto";
import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";
import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { selectActiveMaintenanceConnections } from "./recover-recurring-maintenance";

const DATABASE_URL = process.env.DATABASE_URL;
class Rollback extends Error {}

// (Reuse the seedConnection helper shape from recover-stuck-syncs.test.ts:
//  insert twist + twist_instance + twist_instance_connection with the given
//  lifecycle flags, run the assertion, then throw Rollback to undo.)

describe.skipIf(!DATABASE_URL)("selectActiveMaintenanceConnections", () => {
  it("includes an active connection and excludes archived/suspended/reauth", async () => {
    const db = createDb({ HYPERDRIVE: { connectionString: DATABASE_URL } } as unknown as Bindings);
    try {
      await db.transaction().execute(async (trx) => {
        const active = await seedConnection(trx, {});
        await seedConnection(trx, { archived: true });
        await seedConnection(trx, { needsReauth: true });
        const rows = await selectActiveMaintenanceConnections(trx);
        const ids = rows.map((r) => r.twistInstanceId);
        expect(ids).toContain(active.twistInstanceId);
        // archived/reauth excluded
        expect(rows.every((r) => r.twistInstanceId !== undefined)).toBe(true);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
  });
});
```

(Copy `seedConnection` from `recover-stuck-syncs.test.ts` and adapt: it just needs lifecycle flags, no initial-sync timing.)

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/api test recover-recurring-maintenance`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement selection + sweep**

`workers/api/src/scheduled/recover-recurring-maintenance.ts`:

```typescript
import { createLogger } from "@plotday/worker-util";
import { sql } from "kysely";
import { withDb, type DB, type Kysely } from "../db";
import type { Bindings } from "../env";

/**
 * Backstop for periodic maintenance chains (watch renewals, self-heal, polling)
 * that died with no live recurring task — e.g. a chain that predates the
 * recurring primitive, or a row lost to a bug. The recurring DO alarm makes a
 * chain self-perpetuating once it exists, so this sweep only has to notice the
 * "no row at all" case and re-assert it via the connector's existing idempotent
 * recovery path (recovery_pending → recover-pending sweep re-dispatches
 * onChannelEnabled(recovering: true), which re-registers the recurring task).
 *
 * It is gated on the DO's needsRecurringRecovery() (instance has EVER had a
 * recurring task but has none now), so webhook-only connectors that never
 * register one are never flagged.
 */
export type MaintenanceCandidate = {
  twistInstanceId: string;
  userId: string;
  provider: string;
};

export async function selectActiveMaintenanceConnections(
  db: Kysely<DB>
): Promise<MaintenanceCandidate[]> {
  return db
    .selectFrom("twist_instance_connection as tic")
    .innerJoin("twist_instance as ti", "ti.id", "tic.twist_instance_id")
    .select([
      "tic.twist_instance_id as twistInstanceId",
      "tic.user_id as userId",
      "tic.provider as provider",
    ])
    .where("tic.initial_sync_completed_at", "is not", null) // past initial sync
    .where("tic.recovery_pending", "=", false)
    .where("tic.needs_reauth_at", "is", null)
    .where("ti.archived_at", "is", null)
    .where("ti.suspended_at", "is", null)
    .where("ti.draft", "=", false)
    .execute();
}

export async function flagMaintenanceForRecovery(
  db: Kysely<DB>,
  candidate: MaintenanceCandidate
): Promise<number> {
  const result = await db
    .updateTable("twist_instance_connection")
    .set({ recovery_pending: true })
    .where("twist_instance_id", "=", candidate.twistInstanceId)
    .where("user_id", "=", candidate.userId)
    .where("provider", "=", candidate.provider)
    .where("recovery_pending", "=", false)
    .where("needs_reauth_at", "is", null)
    .executeTakeFirst();
  return Number(result.numUpdatedRows ?? 0);
}

export async function recoverRecurringMaintenance(
  env: Bindings,
  _ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "recoverRecurringMaintenance" });
  await withDb(env, async (db) => {
    const candidates = await selectActiveMaintenanceConnections(db);
    if (candidates.length === 0) return;

    let flagged = 0;
    let alive = 0;
    let skipped = 0;
    for (const c of candidates) {
      let needs: boolean;
      try {
        const id = env.CALLBACKS.idFromName(c.twistInstanceId);
        const stub = env.CALLBACKS.get(id);
        needs = await stub.needsRecurringRecovery(c.twistInstanceId);
      } catch (error) {
        // Fail safe: never re-dispatch a chain we can't confirm is dead.
        logger.error("maintenance liveness check failed", error as Error, {
          twist_instance_id: c.twistInstanceId,
        });
        skipped++;
        continue;
      }
      if (!needs) {
        alive++;
        continue;
      }
      if ((await flagMaintenanceForRecovery(db, c)) > 0) flagged++;
    }
    logger.warn("Recurring-maintenance watchdog swept connections", {
      candidates: candidates.length,
      flagged,
      alive,
      skipped,
    });
  });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/api test recover-recurring-maintenance`
Expected: PASS.

- [ ] **Step 5: Wire into the cron**

In `workers/api/src/index.ts`, inside the existing `if (scheduledMinutes … 30 … 35)` recovery block, AFTER `recoverPendingConnections`, add:

```typescript
    try {
      await recoverRecurringMaintenance(env, _ctx);
    } catch (error) {
      logger.error("Error in recurring-maintenance watchdog", error as Error);
    }
```

Order matters: it flags `recovery_pending`, and the prior `recoverPendingConnections` call already ran this tick — so flags set now are picked up on the NEXT 30-min tick (acceptable for a backstop). Import `recoverRecurringMaintenance` at the top.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/scheduled/recover-recurring-maintenance.ts workers/api/src/scheduled/recover-recurring-maintenance.test.ts workers/api/src/index.ts
git commit -m "feat(scheduled): backstop sweep re-asserts dead recurring maintenance chains"
```

---

## Phase 5 — Connector migrations

> **Two canonical transforms.** Every connector migration is one of these, applied to its specific call sites. Both are shown in full in Tasks 8 (bare-`runTask` form) and 9 (keyed form). Later connector tasks reference the matching transform and give exact file/key/interval.

### Task 8: Gmail — migrate self-heal + watch-renewal (bare-`runTask` form, the incident)

**Files:**
- Modify: `public/connectors/gmail/src/gmail.ts`
- Build: `cd public/connectors/gmail && pnpm build`

**Interfaces:**
- Consumes: `this.scheduleRecurring(key, callback, { intervalMs, firstRunAt? })` and `this.cancelScheduledTask(key)` (Task 4).

- [ ] **Step 1: Migrate `scheduleSelfHealCheck` (fixed cadence)**

Replace the body of `scheduleSelfHealCheck` (`gmail.ts:1082-1100`) with:

```typescript
  private async scheduleSelfHealCheck(): Promise<void> {
    // Durable recurring: the platform re-arms every SELF_HEAL_INTERVAL_MS. The
    // selfHealCheck callback no longer reschedules itself. Idempotent — keyed,
    // so any concurrent call replaces rather than leaks.
    const callback = await this.callback(this.selfHealCheck);
    await this.scheduleRecurring("mailbox-self-heal", callback, {
      intervalMs: SELF_HEAL_INTERVAL_MS,
    });
  }
```

In `selfHealCheck` (`gmail.ts:1054-1068`), delete the "reschedule next run" block that calls `await this.scheduleSelfHealCheck();` at the end — the platform now owns the cadence. Keep the rest of the heal logic. (Leave the bootstrap call in `onGmailWebhook` and in `setupMailboxWebhook` — re-registering the same key is a harmless replace.)

- [ ] **Step 2: Migrate `scheduleMailboxRenewal` (variable cadence + ceiling)**

Replace `scheduleMailboxRenewal` (`gmail.ts:798-824`) with:

```typescript
  private async scheduleMailboxRenewal(expiration: Date): Promise<void> {
    const renewalTime = new Date(expiration.getTime() - 24 * 60 * 60 * 1000);
    const renewalCallback = await this.callback(this.renewMailboxWatch);
    // Ceiling = 3.5 days (half the 7-day Gmail watch): even if a precise
    // renewal beat is lost, the watch is renewed well before it expires.
    await this.scheduleRecurring("mailbox-watch-renewal", renewalCallback, {
      intervalMs: 3.5 * 24 * 60 * 60 * 1000,
      firstRunAt: renewalTime,
    });
  }
```

`renewMailboxWatch` already calls `scheduleMailboxRenewal(newExpiration)` after renewing — that now re-registers the recurring key with the new precise `firstRunAt` (the tighten path). No further change there.

- [ ] **Step 3: Update teardown to cancel by key**

In `teardownMailboxWebhook` (`gmail.ts:751-792`), replace the two `mailbox_renewal_task` / `mailbox_self_heal_task` token blocks (`gmail.ts:752-770`) with:

```typescript
    await this.cancelScheduledTask("mailbox-watch-renewal");
    await this.cancelScheduledTask("mailbox-self-heal");
```

Remove now-dead reads/writes of the `mailbox_renewal_task` and `mailbox_self_heal_task` store keys throughout the file (the `get`/`set`/`clear` for those two keys at lines ~281, ~649, ~762-769, ~799-807, ~925, ~1083-1098, ~1933). For the `onGmailWebhook` bootstrap (`gmail.ts:1933-1943`), replace the "skip if stored token present" guard with an unconditional idempotent call: `await this.scheduleSelfHealCheck();` (keyed replace makes it safe).

- [ ] **Step 4: Re-assert on upgrade**

In Gmail's `upgrade()` method (it exists — search `async upgrade`), after existing migration steps, re-assert both chains so deploying this migration resurrects already-dead chains:

```typescript
    // Re-assert durable recurring maintenance for any instance that had an
    // active mailbox watch but whose pre-recurring self-heal/renewal chain died.
    const webhook = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (webhook?.expiration) {
      await this.scheduleSelfHealCheck();
      await this.scheduleMailboxRenewal(new Date(webhook.expiration));
    }
```

(Match the real stored-state shape — confirm the `mailbox_webhook` key holds `expiration`; adjust to the actual field used by `setupMailboxWebhook`.)

- [ ] **Step 5: Build**

Run: `cd public/connectors/gmail && pnpm build && pnpm exec tsc --noEmit`
Expected: no errors.

- [ ] **Step 6: Commit (submodule)**

```bash
cd public && git add connectors/gmail/src/gmail.ts
git commit -m "feat(gmail): durable self-heal + watch-renewal via scheduleRecurring"
cd ..
```

---

### Task 9: google-calendar — migrate watch-renewal (keyed form, canonical)

**Files:**
- Modify: `public/connectors/google-calendar/src/google-calendar.ts`

- [ ] **Step 1: Migrate `scheduleWatchRenewal`**

Replace the `scheduleTask` call in `scheduleWatchRenewal` (`google-calendar.ts:695-697`) with `scheduleRecurring`, keeping the precise `renewalTime` as `firstRunAt` and adding the ceiling:

```typescript
    // Durable recurring: ceiling 3.5 days (half the ~7-day watch) guarantees a
    // renewal fires even if a precise beat is lost; firstRunAt keeps the
    // precise expiry-24h timing. renewCalendarWatch re-registers on success.
    await this.scheduleRecurring(`watch-renewal:${calendarId}`, renewalCallback, {
      intervalMs: 3.5 * 24 * 60 * 60 * 1000,
      firstRunAt: renewalTime,
    });
```

`renewCalendarWatch` (`google-calendar.ts:707`) already calls `scheduleWatchRenewal(calendarId)` after renewing (`:776`) — that becomes the tighten re-register. No change. Teardown (`cancelScheduledTask` at `:588`) already works for the recurring key.

- [ ] **Step 2: Re-assert on upgrade (optional but recommended)**

If google-calendar has an `upgrade()` (search `async upgrade`), re-call `scheduleWatchRenewal(calendarId)` for each watched calendar in stored state so dead chains resurrect on deploy. If there is no `upgrade()`, rely on the backstop sweep + the next `onChannelEnabled`/webhook re-dispatch.

- [ ] **Step 3: Build + commit (submodule)**

```bash
cd public/connectors/google-calendar && pnpm build && pnpm exec tsc --noEmit
cd /Users/kris.braun/code/plot/.claude/worktrees/durable-recurring-tasks/public
git add connectors/google-calendar/src/google-calendar.ts
git commit -m "feat(google-calendar): durable watch-renewal via scheduleRecurring"
cd ..
```

---

### Task 10: Outlook-mail — migrate self-heal + subscription renewal (bare-`runTask` form)

Apply the **Task 8 (Gmail) transform** to `public/connectors/outlook-mail/src/outlook-mail.ts`:

- `scheduleSelfHealCheck` (`outlook-mail.ts:727-742`) → `scheduleRecurring("mailbox-self-heal", cb, { intervalMs: SELF_HEAL_INTERVAL_MS })`; delete the self-reschedule at the end of `selfHealCheck` (`:869`).
- `scheduleMailboxSubscriptionRenewal` / the `runTask` in `renewMailboxSubscription` setup (`outlook-mail.ts:639-655`) → `scheduleRecurring("mailbox-subscription-renewal", cb, { intervalMs: 1.5 * 24 * 60 * 60 * 1000, firstRunAt: expiry - 24h })` (MS subscriptions ~3 days → ceiling 1.5 days).
- Teardown (`:585-600`) → `cancelScheduledTask("mailbox-self-heal")` + `cancelScheduledTask("mailbox-subscription-renewal")`; remove `mailbox_self_heal_task` / renewal token store bookkeeping.
- `onWebhook` bootstrap (`:1083-1085`) → unconditional `await this.scheduleSelfHealCheck()`.
- `upgrade()` → re-assert both if a subscription exists.

- [ ] **Step 1:** Apply the transform above. **Step 2:** `cd public/connectors/outlook-mail && pnpm build && pnpm exec tsc --noEmit`. **Step 3:** commit in `public/` with `feat(outlook-mail): durable self-heal + subscription renewal via scheduleRecurring`.

---

### Task 11: Remaining keyed connectors — apply the Task 9 transform

For each connector below, replace its `scheduleTask(key, cb, { runAt })` call(s) with `scheduleRecurring(key, cb, { intervalMs, firstRunAt })` using the per-connector values, and **delete the self-reschedule at the end of the callback for FIXED-cadence chains** (the platform now re-arms); for VARIABLE renewals keep the callback's re-register (it becomes the tighten path). Teardown via `cancelScheduledTask(key)` is already present and unchanged. After each: `pnpm build && pnpm exec tsc --noEmit` in that connector dir, then commit in `public/`.

| Connector / file | Key | Form | `intervalMs` (ceiling) | `firstRunAt` | Callback change |
|---|---|---|---|---|---|
| google-drive `google-drive.ts` | `` `watch-renewal:${folderId}` `` | VARIABLE | `3.5*86400e3` | existing `renewalTime` (80% TTL) | keep re-register (tighten) |
| google-chat `google-chat.ts` | `` `ws-renewal:${channelId}` `` | VARIABLE | `3.5*86400e3` | `subExpiry − 24h` | keep re-register |
| google-chat `google-chat.ts` | `` `daily-members-sync:${channelId}` `` | FIXED | `24*3600e3` | omit (or `now+24h`) | drop self-reschedule; keep rate-limit `firstRunAt` re-register only on 429 |
| outlook-calendar `outlook-calendar.ts` | `` `watch-renewal:${calendarId}` `` | VARIABLE | `1.5*86400e3` | `expiry − 24h` | keep re-register |
| airtable `airtable.ts` | `` `poll:${baseId}` `` | FIXED | `60e3` | omit | drop self-reschedule |
| airtable `airtable.ts` | `` `webhook-renewal:${baseId}` `` | VARIABLE | `3.5*86400e3` | `expiresAt − 24h` | keep re-register |
| jira `jira.ts` | `` `webhook-renewal:${projectId}` `` | VARIABLE | `2.5*86400e3` | `expiry − 24h` | keep re-register |
| apple-calendar `apple-calendar.ts` | `` `poll:${calendarHref}` `` | FIXED | `15*60e3` | omit | drop self-reschedule (keep the `enabled` guard) |
| asana `asana.ts` | `` `change-poll:${projectId}` `` | FIXED | `60e3` | omit | drop self-reschedule (keep `enabled` guard) |
| google-tasks `google-tasks.ts` | `` `poll:${listId}` `` | FIXED | `3600e3` | omit | drop self-reschedule |
| slack `slack.ts` | `` `members-sync:${channelId}` `` | FIXED | `24*3600e3` | omit | drop self-reschedule; keep rate-limit `firstRunAt` re-register on 429 |
| slack `slack.ts` | `` `custom-emoji-sync:${channelId}` `` | FIXED | `24*3600e3` | omit | drop self-reschedule; keep rate-limit re-register |
| ms-teams `ms-teams.ts` | `"daily-org-sync"` | FIXED | `24*3600e3` | omit | drop self-reschedule; keep rate-limit re-register |

- [ ] **Step 1:** Migrate google-drive; build; commit.
- [ ] **Step 2:** Migrate google-chat (both keys); build; commit.
- [ ] **Step 3:** Migrate outlook-calendar; build; commit.
- [ ] **Step 4:** Migrate airtable (both keys); build; commit.
- [ ] **Step 5:** Migrate jira; build; commit.
- [ ] **Step 6:** Migrate apple-calendar; build; commit.
- [ ] **Step 7:** Migrate asana; build; commit.
- [ ] **Step 8:** Migrate google-tasks; build; commit.
- [ ] **Step 9:** Migrate slack (both keys); build; commit.
- [ ] **Step 10:** Migrate ms-teams; build; commit.

Each commit message: `feat(<connector>): durable recurring maintenance via scheduleRecurring`.

---

## Phase 6 — Finalize

### Task 12: Repo-wide verification + docs

- [ ] **Step 1: Full api worker checks**

Run:
```bash
pnpm --filter @plotday/api lint
pnpm --filter @plotday/api exec tsc --noEmit
pnpm --filter @plotday/api test
pnpm --filter @plotday/api test:integration
```
Expected: all green.

- [ ] **Step 2: Confirm no stragglers**

Run: `rg -n "mailbox_self_heal_task|mailbox_renewal_task" public/connectors connectors` — expect no remaining references (Gmail/Outlook bookkeeping removed). Run `rg -n "scheduleTask\(" public/connectors connectors` — every remaining hit should be a genuinely one-shot keyed task (no self-rescheduling recurring chain left on `scheduleTask`).

- [ ] **Step 3: docs/updates.md**

Add under `## Next release` → `### Fixes`:
```markdown
- Background sync maintenance (mail, calendars, drive, chat) now recovers
  automatically if it ever stalls, instead of silently stopping until you
  reconnect.
```

- [ ] **Step 4: Commit**

```bash
git add docs/updates.md
git commit -m "docs(updates): note durable recurring maintenance recovery"
```

- [ ] **Step 5: Run `/finalize`** for the full finalization checklist (lint, backwards-compat, error capture, public submodule PR + changeset).

---

## Self-Review notes (for the implementer)

- **Spec coverage:** Phase 1 = recurring DO primitive (spec §1); Phase 2 = SDK + changeset (§Backward compat); Phase 3 = DLQ (§2, folded in); Phase 4 = backstop layer (b) (§3); Phase 5 = migrate all 17 keyed + 4 bare chains (§Migration); deploy-time re-assert = layer (a) via each connector's `upgrade()` step. Finite backfills untouched (Phase 5 note).
- **Ceiling clamp** lives in `create()` (Task 1) so every caller — SDK and tests — gets it for free.
- **`alarm()` advance in `finally`** (Task 2) is the load-bearing line: it persists the next beat even when the enqueue throws, and must never throw out (it's a single SQLite UPDATE).
- **Backstop gating** on `needsRecurringRecovery` (Task 3 + 7) prevents false-flagging webhook-only connectors; pre-migration dead chains are handled by the `upgrade()` re-assert (Tasks 8–11), not the sweep.
- **Two `__tests__` vs node test homes:** DO tests → `test:integration`; sweep test → `test`. Don't mix.
