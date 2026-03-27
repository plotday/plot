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

/**
 * Run queries within a transaction.
 * Auth context is enforced in the API and SQL functions.
 */
export async function withUserDb<T>(
  db: Kysely<DB>,
  userId: string,
  fn: (trx: Kysely<DB>) => Promise<T>
): Promise<T> {
  void userId;
  return db.transaction().execute(async (trx) => fn(trx));
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
