import { Kysely, PostgresDialect, sql } from "kysely";
import pg from "pg";

import { createLogger } from "@plotday/worker-util";

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

function isTransientDbError(error: unknown): boolean {
  const msg = (error as Error)?.message ?? "";
  return msg.includes("shutting down") || msg.includes("connection terminated");
}

// SQLSTATE codes for transient transaction failures that Postgres resolves by
// aborting (and fully rolling back) one transaction. Both are safe to retry.
const RETRYABLE_TXN_SQLSTATES = new Set([
  "40P01", // deadlock_detected
  "40001", // serialization_failure
]);

function isRetryableTxnError(error: unknown): boolean {
  if (error && typeof error === "object") {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && RETRYABLE_TXN_SQLSTATES.has(code)) {
      return true;
    }
    // Fallback for drivers/paths that don't surface the SQLSTATE code.
    const msg = (error as { message?: unknown }).message;
    if (typeof msg === "string" && msg.includes("deadlock detected")) {
      return true;
    }
  }
  return false;
}

/** Randomized backoff (ms) to desynchronize the next lock-acquisition attempt
 *  so the two transactions in a deadlock cycle don't immediately re-collide. */
function txnRetryBackoffMs(attempt: number): number {
  return attempt * 20 + Math.floor(Math.random() * 20);
}

/**
 * Run `fn`, retrying on deadlock (40P01) and serialization failure (40001).
 * Only safe when each attempt leaves no committed state behind: a whole
 * explicit transaction, or a single autocommit statement (whose implicit
 * transaction Postgres fully rolls back when it picks it as the victim).
 * Never wrap an individual statement that runs INSIDE an explicit
 * transaction — the surrounding transaction is aborted and must be retried
 * as a unit instead.
 */
export async function retryOnTxnConflict<T>(fn: () => Promise<T>): Promise<T> {
  const maxAttempts = 3;
  let lastError: unknown;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      if (attempt < maxAttempts && isRetryableTxnError(error)) {
        await new Promise((resolve) =>
          setTimeout(resolve, txnRetryBackoffMs(attempt))
        );
        continue;
      }
      throw error;
    }
  }
  throw lastError;
}

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
