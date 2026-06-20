import { Kysely, PostgresDialect, sql } from "kysely";
import pg from "pg";

import { createLogger, retryOnTxnConflict } from "@plotday/worker-util";

import type { DB } from "./db-types";
import type { Bindings } from "./env";

export type { DB };
export { sql };
export type { Kysely };

// PostgreSQL bigint (OID 20) → JS number.
// Our bigint columns are auto-increment IDs that will never exceed
// Number.MAX_SAFE_INTEGER (9 quadrillion). Without this, the pg driver
// returns them as strings, which breaks Dart's Drift ORM deserialization.
pg.types.setTypeParser(20, (val: string) => parseInt(val, 10));

/** Create a Kysely instance from Hyperdrive or direct connection. Call once per request. */
export function createDb(env: Bindings) {
  const connectionString = env.HYPERDRIVE?.connectionString ?? env.DATABASE_URL;
  if (!connectionString) {
    throw new Error("No database connection: set HYPERDRIVE or DATABASE_URL");
  }

  const pool = new pg.Pool({
    connectionString,
    max: 1,
    // Connection-level GUCs set via the libpq `-c` flag at connection time.
    // `-c` survives Hyperdrive's connection pooling (unlike a `SET` query,
    // which can be routed to a different backend connection), so every pooled
    // backend carries these bounds:
    //   statement_timeout                   — no single statement runs > 30s.
    //   idle_in_transaction_session_timeout — reap a transaction abandoned
    //     mid-flight (worker reloaded by `wrangler dev`, or awaiting a slow
    //     external call) after 2 min, instead of letting it hold row locks
    //     forever. A 27-min orphaned `idle in transaction` backend stuck in
    //     upsert_thread once blocked every push retry of a thread, so it never
    //     synced and its connector link never sent. 120s is comfortably above
    //     any legitimate in-transaction await (e.g. inline classify).
    //   lock_timeout                        — a statement waiting on a row lock
    //     fails fast (10s) and the caller retries, rather than blocking the
    //     whole request behind a wedged holder.
    options:
      "-c statement_timeout=30000 -c idle_in_transaction_session_timeout=120000 -c lock_timeout=10000",
  });

  // Prevent pool-level errors from crashing the worker.
  // Query errors are still propagated via promise rejections.
  pool.on("error", (err) => {
    const logger = createLogger({ source: "pg_pool" });
    logger.error("DB pool error", err, {
      pg_code: (err as any)?.code,
    });
  });

  return new Kysely<DB>({
    dialect: new PostgresDialect({ pool }),
  });
}


/** Run `fn` with a short-lived Kysely instance that is always destroyed.
 *  Retries on transient connection errors (e.g. Hyperdrive recycling or
 *  pool exhaustion); see maxRetriesFor for the per-error retry budget. */
export async function withDb<T>(
  env: Bindings,
  fn: (db: Kysely<DB>) => Promise<T>
): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; ; attempt++) {
    // Before a retry, wait out a transient Hyperdrive pool-exhaustion burst so
    // peer connections can drain. The previous attempt's pool was already torn
    // down in its `finally`, freeing our slot, so this pause doesn't hold one.
    // The backoff grows with `attempt` so the cumulative wait spans the burst
    // window. No-op (0ms) for connection-recycling errors, which just need a
    // fresh connection and would only be slowed by waiting.
    if (attempt > 0) {
      const delayMs = transientRetryDelayMs(lastError, attempt);
      if (delayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      }
    }
    const db = createDb(env);
    try {
      // Also set statement_timeout via explicit SET as a fallback.
      // The connection-level `options` parameter in createDb should handle this,
      // but if Hyperdrive reuses a pooled connection that already completed
      // its startup phase, this SET ensures the timeout is applied.
      await sql`SET statement_timeout = 30000`.execute(db);
      return await fn(db);
    } catch (error) {
      lastError = error;
      if (attempt < maxRetriesFor(error)) {
        continue;
      }
      throw error;
    } finally {
      await db.destroy();
    }
  }
}

export function isTransientDbError(error: unknown): boolean {
  // Lowercase before matching: pg throws "Connection terminated unexpectedly"
  // (capital C) from client.js when a pooled Hyperdrive connection is recycled
  // mid-query. A case-sensitive check for "connection terminated" missed it, so
  // the retry below never fired and the drop surfaced as a captured exception.
  const msg = ((error as Error)?.message ?? "").toLowerCase();
  return (
    msg.includes("shutting down") ||
    msg.includes("connection terminated") ||
    isPoolExhaustedError(error)
  );
}

/**
 * Hyperdrive's connection-pool-exhaustion error. Cloudflare's Hyperdrive proxy
 * throws "Timed out while waiting for an open slot in the pool." when every slot
 * in its connection pool (60 by default, shared across the whole Worker and all
 * its Durable Objects) is busy. It spikes during bursts of concurrent DB use —
 * e.g. one change fanning out to many TwistSync DOs that each open a connection
 * inside the same jitter window. It is transient: a brief pause lets peer
 * connections drain. Kept distinct from connection-recycling errors so the retry
 * can back off before re-requesting a slot — a tight retry just re-loses the
 * race and adds churn to an already-saturated pool.
 */
export function isPoolExhaustedError(error: unknown): boolean {
  const msg = ((error as Error)?.message ?? "").toLowerCase();
  return msg.includes("open slot in the pool");
}

/**
 * Row-lock contention surfacing as a canceled statement. Two pg error codes:
 *
 *   - 55P03 (lock_not_available): the statement set a `lock_timeout` and gave
 *     up waiting for a row lock. This is the *intended* fast-fail for the
 *     TwistSync cursor advance (see twist-sync.ts), which shares its
 *     twist_instance_sync PK rows with the high-frequency sync_twist_for_*
 *     write-path triggers.
 *   - 57014 (query_canceled): the statement hit `statement_timeout`. For a
 *     write to the tiny (sub-MB, ~800-row) twist_instance_sync table there is
 *     no computational path to 30s, so this can only mean the UPSERT blocked
 *     on a row lock held by a concurrent writer. This is how the contention
 *     historically surfaced as a captured exception (PostHog 019ed540).
 *
 * Deadlocks (40P01) are deliberately excluded — Postgres rolls the victim back
 * and `retryOnTxnConflict` handles those; they are a different failure mode.
 *
 * Callers use this to treat contention on an idempotent, retried-next-cycle
 * write as expected rather than reporting it as a bug.
 */
export function isLockContentionError(error: unknown): boolean {
  const code = (error as { code?: unknown })?.code;
  if (code === "55P03" || code === "57014") return true;
  const msg = ((error as Error)?.message ?? "").toLowerCase();
  return (
    msg.includes("canceling statement due to lock timeout") ||
    msg.includes("canceling statement due to statement timeout")
  );
}

// Exponential-backoff bounds for retrying a Hyperdrive pool-exhaustion error.
// The backoff grows per attempt (base * 2^(attempt-1), capped) with equal
// jitter, so the *cumulative* wait across MAX_POOL_EXHAUSTION_RETRIES spans the
// ~2s fan-out burst that produces this error: notify() staggers TwistSync
// alarms across MAX_JITTER_MS (2000ms) in twist-sync.ts, so a single sub-second
// retry can't outlast the burst — peer connections are still busy when it
// re-requests a slot, and the alarm drops its sync cycle until SyncRecovery
// re-notifies ~30s later. Jitter de-synchronizes the many DOs retrying at once.
const POOL_RETRY_BASE_MS = 100;
const POOL_RETRY_CAP_MS = 1000;

// Retry budgets per transient error class. Both pool exhaustion and
// connection-termination fire from the SAME Hyperdrive-saturation bursts during
// TwistSync alarm fan-out (PostHog issues 019ed540 and 019c4dff track each other
// minute-for-minute): one can't acquire a slot, the other has its connection
// recycled mid-read. Both therefore need a burst-spanning budget rather than a
// single retry. Each attempt fully tears down its pool in withDb's `finally`
// before the next backoff, so waiting holds no connection — extra retries add no
// connection pressure to the saturated pool, only delay. Re-running the whole
// callback is safe: SyncRecovery already re-runs the alarm every ~30s, so it is
// idempotent by design, and these errors surface during the read phase (the
// twist-sync.ts:294 SELECTs) before any write/dispatch.
const MAX_POOL_EXHAUSTION_RETRIES = 5;
const MAX_TRANSIENT_RETRIES = 4;

/**
 * How many times withDb should retry a given transient error. Pool exhaustion
 * is checked first because it is also a "transient" error but warrants the
 * largest burst-spanning budget; other transient errors (connection recycled /
 * server shutting down) get a slightly smaller multi-retry budget. Non-transient
 * errors return 0 (no retry).
 */
export function maxRetriesFor(error: unknown): number {
  if (isPoolExhaustedError(error)) return MAX_POOL_EXHAUSTION_RETRIES;
  if (isTransientDbError(error)) return MAX_TRANSIENT_RETRIES;
  return 0;
}

// Exponential backoff with equal jitter, capped. `step` is 1-based. Equal jitter
// (ceiling/2 plus up to another ceiling/2) keeps the pause from collapsing to
// ~0ms, which would just re-lose the race for a slot.
function backoffMs(step: number): number {
  const ceiling = Math.min(
    POOL_RETRY_CAP_MS,
    POOL_RETRY_BASE_MS * 2 ** (step - 1)
  );
  const half = ceiling / 2;
  return Math.floor(half + Math.random() * half);
}

/**
 * Backoff (ms) to wait before the given retry `attempt` (1-based) of a transient
 * DB error.
 *
 * - Pool exhaustion: back off from the first retry — there is no free slot, so
 *   an immediate retry just re-loses the race. The backoff grows per attempt so
 *   the cumulative wait spans the ~2s fan-out burst window.
 * - Other transient errors (connection recycled / server shutting down): the
 *   first retry is immediate, because a benign Hyperdrive idle-recycle just
 *   needs a fresh connection. If that also fails, the termination is likely
 *   saturation-driven (the same bursts that exhaust the pool), so subsequent
 *   retries back off to ride out the burst instead of hammering a busy origin.
 */
export function transientRetryDelayMs(error: unknown, attempt = 1): number {
  if (isPoolExhaustedError(error)) {
    return backoffMs(attempt);
  }
  if (isTransientDbError(error)) {
    return attempt <= 1 ? 0 : backoffMs(attempt - 1);
  }
  return 0;
}

// Deadlock/serialization retry lives in @plotday/worker-util so the classify
// worker (its own db.ts) shares the same policy. Re-exported here for the
// rpc.ts call site.
export { retryOnTxnConflict };

/**
 * Run queries within a transaction.
 * Auth context is enforced in the API and SQL functions.
 *
 * Retries on deadlock (40P01) and serialization failure (40001). Postgres
 * aborts and fully rolls back the victim transaction in these cases, leaving
 * no committed state, so re-running the callback in a fresh transaction is
 * safe. The callback must therefore be idempotent across attempts (it runs
 * entirely inside the transaction, so any DB writes are discarded on rollback;
 * avoid relying on non-transactional side effects firing exactly once).
 */
export async function withUserDb<T>(
  db: Kysely<DB>,
  userId: string,
  fn: (trx: Kysely<DB>) => Promise<T>
): Promise<T> {
  void userId;
  return retryOnTxnConflict(() =>
    db.transaction().execute(async (trx) => fn(trx))
  );
}

/**
 * Map PostgreSQL error codes to HTTP status codes.
 * Returns [statusCode, errorMessage] for known error codes.
 */
export function mapPgError(
  error: unknown
): { status: number; pgCode: string; message: string } | null {
  if (error && typeof error === "object" && "code" in error) {
    const pgCode = (error as { code: string }).code;
    const message =
      "message" in error
        ? String((error as { message: string }).message)
        : "Database error";

    switch (pgCode) {
      case "42501": // insufficient_privilege
        return { status: 403, pgCode, message };
      case "23503": // foreign_key_violation
        return { status: 409, pgCode, message };
      case "23505": // unique_violation
        return { status: 409, pgCode, message };
      case "23514": // check_violation
        return { status: 422, pgCode, message };
      case "P0001": // raise_exception
        return { status: 422, pgCode, message };
      default:
        return null;
    }
  }
  return null;
}
