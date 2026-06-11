import { describe, it, expect, vi } from "vitest";
import {
  Kysely,
  PostgresAdapter,
  PostgresIntrospector,
  PostgresQueryCompiler,
  type CompiledQuery,
  type DatabaseConnection,
} from "kysely";

import { handleClassifyJob } from "./handler";
import type { DB } from "./db";

vi.mock("@plotday/classifier-runtime", () => ({
  getProductionClassifier: () => ({
    name: "ts:hybrid-llm:production@deadbeef",
    classify: async () => ({
      priorityId: "target-priority",
      stage: "test",
      scores: {},
      durationMs: 1,
      llmCalls: 0,
      cacheHits: 0,
      budgetExhausted: false,
    }),
  }),
  classifierContextFromDb: () => ({}),
}));

function pgError(message: string, code: string): Error & { code: string } {
  const e = new Error(message) as Error & { code: string };
  e.code = code;
  return e;
}

/** Real Kysely over a stub driver. `events` records BEGIN/COMMIT/ROLLBACK and
 *  every executed SQL string in order, so tests can assert lock ordering. */
function testDb(
  events: string[],
  respond: (sql: string) => Promise<{ rows: unknown[]; numAffectedRows?: bigint }>
): Kysely<DB> {
  const connection: DatabaseConnection = {
    executeQuery: async (compiled: CompiledQuery) => {
      events.push(compiled.sql);
      return respond(compiled.sql) as any;
    },
    streamQuery: () => {
      throw new Error("not implemented");
    },
  };
  return new Kysely<DB>({
    dialect: {
      createAdapter: () => new PostgresAdapter(),
      createDriver: () => ({
        init: async () => {},
        acquireConnection: async () => connection,
        beginTransaction: async () => {
          events.push("BEGIN");
        },
        commitTransaction: async () => {
          events.push("COMMIT");
        },
        rollbackTransaction: async () => {
          events.push("ROLLBACK");
        },
        releaseConnection: async () => {},
        destroy: async () => {},
      }),
      createIntrospector: (db) => new PostgresIntrospector(db),
      createQueryCompiler: () => new PostgresQueryCompiler(),
    },
  });
}

const JOB = { userId: "user-1", threadId: "thread-1" };
const ENV = {} as any;

/** Default responder: pending row with a non-null snapshot (case B), thread
 *  hydrate returns nothing, updates report one row updated. */
function defaultRespond(
  overrides?: (sql: string) => Promise<{ rows: unknown[]; numAffectedRows?: bigint }> | null
) {
  return async (sql: string) => {
    if (overrides) {
      const hit = overrides(sql);
      if (hit) return hit;
    }
    if (sql.includes('from "thread_priority"')) {
      return {
        rows: [
          {
            priority_id: "old-priority",
            user_moved: false,
            classify_at: new Date(),
          },
        ],
      };
    }
    if (sql.includes("FROM public.thread")) {
      return { rows: [] };
    }
    if (sql.includes("FOR NO KEY UPDATE")) {
      return { rows: [{ "?column?": 1 }] };
    }
    if (sql.startsWith('update "thread_priority"')) {
      return { rows: [], numAffectedRows: 1n };
    }
    if (sql.includes("classification_decision")) {
      return { rows: [] };
    }
    throw new Error(`unexpected SQL in test: ${sql}`);
  };
}

describe("handleClassifyJob lock ordering", () => {
  it("locks the parent thread row before updating thread_priority, inside a transaction", async () => {
    const events: string[] = [];
    const db = testDb(events, defaultRespond());

    const outcome = await handleClassifyJob(JOB, ENV, db);

    expect(outcome.status).toBe("moved");
    const begin = events.indexOf("BEGIN");
    const lock = events.findIndex((e) => e.includes("FOR NO KEY UPDATE"));
    const update = events.findIndex((e) => e.startsWith('update "thread_priority"'));
    const commit = events.indexOf("COMMIT");
    expect(begin).toBeGreaterThanOrEqual(0);
    expect(lock).toBeGreaterThan(begin);
    expect(update).toBeGreaterThan(lock);
    expect(commit).toBeGreaterThan(update);
    // The lock targets the thread table, not thread_priority.
    expect(events[lock]).toContain("public.thread");
  });

  it("retries the transaction on deadlock (40P01) and succeeds", async () => {
    const events: string[] = [];
    let updateAttempts = 0;
    const db = testDb(
      events,
      defaultRespond((sql) => {
        if (sql.startsWith('update "thread_priority"')) {
          updateAttempts++;
          if (updateAttempts === 1) {
            return Promise.reject(pgError("deadlock detected", "40P01"));
          }
          return Promise.resolve({ rows: [], numAffectedRows: 1n });
        }
        return null;
      })
    );

    const outcome = await handleClassifyJob(JOB, ENV, db);

    expect(outcome.status).toBe("moved");
    expect(updateAttempts).toBe(2);
    expect(events.filter((e) => e === "BEGIN").length).toBe(2);
    expect(events.filter((e) => e === "ROLLBACK").length).toBe(1);
    expect(events.filter((e) => e === "COMMIT").length).toBe(1);
  });

  it("does not retry non-transient errors", async () => {
    const events: string[] = [];
    let updateAttempts = 0;
    const db = testDb(
      events,
      defaultRespond((sql) => {
        if (sql.startsWith('update "thread_priority"')) {
          updateAttempts++;
          return Promise.reject(pgError("duplicate key value", "23505"));
        }
        return null;
      })
    );

    await expect(handleClassifyJob(JOB, ENV, db)).rejects.toThrow(
      "duplicate key value"
    );
    expect(updateAttempts).toBe(1);
  });
});

describe("decision logging", () => {
  it("logs the applied decision after a settled update", async () => {
    const events: string[] = [];
    const db = testDb(events, defaultRespond());
    const outcome = await handleClassifyJob(JOB, ENV, db);
    expect(outcome.status).toBe("moved");
    const update = events.findIndex((e) => e.startsWith('update "thread_priority"'));
    const log = events.findIndex((e) => e.includes("classification_decision"));
    expect(update).toBeGreaterThanOrEqual(0);
    expect(log).toBeGreaterThan(update);
  });

  it("does not log when the job is skipped (user_moved)", async () => {
    const events: string[] = [];
    const db = testDb(
      events,
      defaultRespond((sql) => {
        if (sql.includes('from "thread_priority"')) {
          return Promise.resolve({
            rows: [{ priority_id: "old-priority", user_moved: true, classify_at: new Date() }],
          });
        }
        return null;
      })
    );
    const outcome = await handleClassifyJob(JOB, ENV, db);
    expect(outcome.status).toBe("skipped");
    expect(events.some((e) => e.includes("classification_decision"))).toBe(false);
  });

  it("reports a failed log insert via onError and still settles", async () => {
    const events: string[] = [];
    const onError = vi.fn();
    const db = testDb(
      events,
      defaultRespond((sql) => {
        if (sql.includes("classification_decision")) {
          return Promise.reject(new Error("log insert failed"));
        }
        return null;
      })
    );
    const outcome = await handleClassifyJob(JOB, ENV, db, onError);
    expect(outcome.status).toBe("moved");
    expect(onError).toHaveBeenCalled();
  });
});
