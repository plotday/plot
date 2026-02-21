import { Kysely, PostgresDialect, sql } from "kysely";
import pg from "pg";

import { createLogger } from "@plotday/worker-util";

import type { DB } from "./db-types";
import type { Bindings } from "./env";

export type { DB };
export { sql };

/** Create a Kysely instance from Hyperdrive or direct connection. Call once per request. */
export function createDb(env: Bindings) {
  const connectionString = env.HYPERDRIVE?.connectionString ?? env.DATABASE_URL;
  if (!connectionString) {
    throw new Error("No database connection: set HYPERDRIVE or DATABASE_URL");
  }
  const pool = new pg.Pool({ connectionString, max: 1 });

  // Prevent pool-level errors from crashing the worker.
  // Query errors are still propagated via promise rejections.
  pool.on("error", (err) => {
    const logger = createLogger();
    logger.error("DB error", err);
  });

  return new Kysely<DB>({
    dialect: new PostgresDialect({ pool }),
  });
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
