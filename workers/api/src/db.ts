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
    // Set statement_timeout as a connection-level GUC parameter.
    // The -c flag sets GUC parameters at connection time, which survives
    // Hyperdrive's connection pooling (unlike SET commands sent as separate queries
    // that may be routed to a different backend connection).
    options: "-c statement_timeout=30000",
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
 *  Retries once on transient connection errors (e.g. Hyperdrive recycling). */
export async function withDb<T>(
  env: Bindings,
  fn: (db: Kysely<DB>) => Promise<T>
): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 2; attempt++) {
    // Before a retry, wait out a transient Hyperdrive pool-exhaustion burst so
    // peer connections can drain. The previous attempt's pool was already torn
    // down in its `finally`, freeing our slot, so this pause doesn't hold one.
    // No-op (0ms) for connection-recycling errors, which just need a fresh
    // connection and would only be slowed by waiting.
    if (attempt > 0) {
      const delayMs = transientRetryDelayMs(lastError);
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
      if (attempt === 0 && isTransientDbError(error)) {
        continue;
      }
      throw error;
    } finally {
      await db.destroy();
    }
  }
  throw lastError;
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

// Bounds for the jittered backoff before retrying a Hyperdrive pool-exhaustion
// error. A few hundred ms covers the sub-second bursts the retry can salvage;
// genuinely sustained over-capacity needs more Hyperdrive connections, not a
// longer wait. Jitter de-synchronizes the many DOs retrying at once.
const POOL_RETRY_MIN_MS = 100;
const POOL_RETRY_MAX_MS = 400;

/**
 * Backoff (ms) to wait before retrying a transient DB error. Pool-exhaustion
 * bursts get a short jittered pause so peer connections can drain; other
 * transient errors (connection recycled / server shutting down) just need a
 * fresh connection, so they retry immediately (0ms).
 */
export function transientRetryDelayMs(error: unknown): number {
  if (!isPoolExhaustedError(error)) return 0;
  return (
    POOL_RETRY_MIN_MS +
    Math.floor(Math.random() * (POOL_RETRY_MAX_MS - POOL_RETRY_MIN_MS))
  );
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
