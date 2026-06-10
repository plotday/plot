import { describe, it, expect } from "vitest";
import {
  Kysely,
  PostgresAdapter,
  PostgresIntrospector,
  PostgresQueryCompiler,
  type CompiledQuery,
  type DatabaseConnection,
} from "kysely";

import { rpcUser } from "./rpc";

function pgError(message: string, code: string): Error & { code: string } {
  const e = new Error(message) as Error & { code: string };
  e.code = code;
  return e;
}

/** Real Kysely instance backed by a stub driver so raw `sql` execution (and
 *  `isTransaction`) behave exactly as in production, with per-test control
 *  over query results. BEGIN/COMMIT go through the no-op transaction hooks,
 *  so `executeQuery` only ever sees the RPC SELECT statements. */
function testDb(
  executeQuery: (sql: string) => Promise<{ rows: unknown[] }>
): Kysely<any> {
  const connection: DatabaseConnection = {
    executeQuery: async (compiled: CompiledQuery) =>
      executeQuery(compiled.sql) as any,
    streamQuery: () => {
      throw new Error("not implemented");
    },
  };
  return new Kysely<any>({
    dialect: {
      createAdapter: () => new PostgresAdapter(),
      createDriver: () => ({
        init: async () => {},
        acquireConnection: async () => connection,
        beginTransaction: async () => {},
        commitTransaction: async () => {},
        rollbackTransaction: async () => {},
        releaseConnection: async () => {},
        destroy: async () => {},
      }),
      createIntrospector: (db) => new PostgresIntrospector(db),
      createQueryCompiler: () => new PostgresQueryCompiler(),
    },
  });
}

describe("rpc deadlock retry (autocommit twist-runtime path)", () => {
  it("retries on a deadlock (40P01) and eventually succeeds", async () => {
    let attempts = 0;
    const db = testDb(async () => {
      attempts++;
      if (attempts === 1) throw pgError("deadlock detected", "40P01");
      return { rows: [{ id: "thread-1" }] };
    });

    const result = await rpcUser(db, "upsert_thread" as any, {
      user_id: "u",
    } as any);

    expect(result).toBe("thread-1");
    expect(attempts).toBe(2);
  });

  it("retries on a serialization failure (40001)", async () => {
    let attempts = 0;
    const db = testDb(async () => {
      attempts++;
      if (attempts === 1) throw pgError("could not serialize access", "40001");
      return { rows: [{ id: "x" }] };
    });

    await expect(
      rpcUser(db, "upsert_thread" as any, {} as any)
    ).resolves.toBe("x");
    expect(attempts).toBe(2);
  });

  it("does not retry on a non-transient error (e.g. unique_violation)", async () => {
    let attempts = 0;
    const db = testDb(async () => {
      attempts++;
      throw pgError("duplicate key value", "23505");
    });

    await expect(rpcUser(db, "upsert_thread" as any, {} as any)).rejects.toThrow(
      "duplicate key value"
    );
    expect(attempts).toBe(1);
  });

  it("propagates the deadlock after exhausting retries", async () => {
    let attempts = 0;
    const db = testDb(async () => {
      attempts++;
      throw pgError("deadlock detected", "40P01");
    });

    await expect(rpcUser(db, "upsert_thread" as any, {} as any)).rejects.toThrow(
      "deadlock detected"
    );
    expect(attempts).toBe(3);
  });

  it("does NOT retry inside an explicit transaction (outer retry owns it)", async () => {
    // After a deadlock the whole transaction is aborted; re-running just the
    // statement would fail with "current transaction is aborted". The
    // enclosing withUserDb retry re-runs the full transaction instead.
    let selectAttempts = 0;
    const db = testDb(async () => {
      selectAttempts++;
      throw pgError("deadlock detected", "40P01");
    });

    await expect(
      db
        .transaction()
        .execute((trx) => rpcUser(trx as any, "upsert_thread" as any, {} as any))
    ).rejects.toThrow("deadlock detected");
    expect(selectAttempts).toBe(1);
  });
});
