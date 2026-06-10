import type { Database } from "@plotday/db";
import { type Kysely, sql } from "kysely";

import { retryOnTxnConflict } from "./db";
import type { DB } from "./db-types";

type PublicFns = Database["public"]["Functions"];
type UserFns = Database["user"]["Functions"];

/**
 * Extract Args from a function type, handling overloaded functions (union types).
 * For overloaded functions, the caller picks which overload by passing matching args.
 */
type FnArgs<Fns, K extends keyof Fns> = Fns[K] extends { Args: infer A }
  ? A
  : never;

/**
 * Extract Returns from a function type, handling overloaded functions.
 */
type FnReturns<Fns, K extends keyof Fns> = Fns[K] extends { Returns: infer R }
  ? R
  : never;

async function rpcWithSchema(
  db: Kysely<DB>,
  fn: string,
  args: Record<string, unknown>,
  schema?: string
) {
  const entries = Object.entries(args);
  const params = entries.map(([key, value]) => {
    const param =
      typeof value === "object" &&
      value !== null &&
      !Array.isArray(value) &&
      !(value instanceof Date)
        ? sql`${JSON.stringify(value)}::jsonb`
        : Array.isArray(value)
          ? sql`${JSON.stringify(value)}::jsonb`
          : sql`${value}`;
    return sql`${sql.raw(key)} => ${param}`;
  });

  const qualified = schema ? `"${schema}".${fn}` : fn;
  const query =
    params.length > 0
      ? sql`SELECT * FROM ${sql.raw(qualified)}(${sql.join(params, sql`, `)})`
      : sql`SELECT * FROM ${sql.raw(qualified)}()`;

  // Autocommit calls (e.g. the twist runtime's `plot.db`) get the same
  // deadlock/serialization retry as withUserDb transactions: Postgres fully
  // rolls back the victim statement's implicit transaction, so re-executing
  // it is safe. Inside an explicit transaction the statement must NOT be
  // retried — the whole transaction is aborted, and the enclosing
  // withUserDb retry re-runs it as a unit.
  const result = db.isTransaction
    ? await query.execute(db)
    : await retryOnTxnConflict(() => query.execute(db));

  // Unwrap scalar function results: SELECT * FROM scalar_fn() returns { fn_name: value }
  // We unwrap single-column rows so callers get the value directly.
  // This applies to both scalar functions (RETURNS type) and table functions
  // with a single column (RETURNS TABLE (col type)).
  const firstRow = result.rows[0];
  if (
    firstRow &&
    typeof firstRow === "object" &&
    Object.keys(firstRow as object).length === 1
  ) {
    return {
      ...result,
      rows: result.rows.map((row) => Object.values(row as object)[0]),
    };
  }
  return result;
}

/**
 * Call a database function with typed args and return.
 * Uses PostgreSQL named parameter syntax: fn(p_name => value).
 * Auto-serializes object values as jsonb.
 *
 * Single-column results are automatically unwrapped:
 * - RETURNS uuid -> returns the uuid string directly
 * - RETURNS TABLE (user_id uuid) -> returns uuid strings (not {user_id} objects)
 * - Multi-column TABLE results are returned as-is
 *
 * **IMPORTANT**: RPC calls use `SELECT * FROM fn(...)` syntax. Hyperdrive treats
 * SELECT queries as cacheable reads. If the database function performs mutations
 * (INSERT/UPDATE/DELETE), callers MUST wrap the call in a transaction so that
 * Hyperdrive recognizes the operation as a write and invalidates its query cache.
 */
export async function rpc<K extends keyof PublicFns>(
  db: Kysely<DB>,
  fn: K,
  args: FnArgs<PublicFns, K>
): Promise<FnReturns<PublicFns, K>> {
  const result = await rpcWithSchema(db, fn as string, args as Record<string, unknown>);
  if (result.rows.length <= 1) return result.rows[0] as FnReturns<PublicFns, K>;
  return result.rows as unknown as FnReturns<PublicFns, K>;
}

/**
 * Call a database function in the user schema with typed args and return.
 * See {@link rpc} for Hyperdrive caching note on mutating functions.
 */
export async function rpcUser<K extends keyof UserFns>(
  db: Kysely<DB>,
  fn: K,
  args: FnArgs<UserFns, K>
): Promise<FnReturns<UserFns, K>> {
  const result = await rpcWithSchema(
    db,
    fn as string,
    args as Record<string, unknown>,
    "user"
  );
  if (result.rows.length <= 1) return result.rows[0] as FnReturns<UserFns, K>;
  return result.rows as unknown as FnReturns<UserFns, K>;
}
