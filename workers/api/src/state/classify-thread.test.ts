import { describe, expect, it, vi } from "vitest";
import {
  Kysely,
  PostgresAdapter,
  PostgresIntrospector,
  PostgresQueryCompiler,
  sql as sql2,
  type CompiledQuery,
  type DatabaseConnection,
} from "kysely";

import {
  classifyThreadForUser,
  logClassificationDecision,
} from "./classify-thread";
import type { DB } from "../db-types";

const captureException = vi.fn();
vi.mock("posthog-node", () => ({
  PostHog: class {
    captureException = captureException;
    async shutdown() {}
  },
}));

const classify = vi.fn();
vi.mock("@plotday/classifier-runtime", () => ({
  getProductionClassifier: () => ({
    name: "ts:hybrid-llm:production@deadbeef",
    classify: (...args: unknown[]) => classify(...args),
  }),
  classifierContextFromDb: () => ({}),
}));

type Executed = { sql: string; parameters: readonly unknown[] };

function testDb(
  executed: Executed[],
  respond: (sql: string) => Promise<{ rows: unknown[] }>
): Kysely<DB> {
  const connection: DatabaseConnection = {
    executeQuery: async (compiled: CompiledQuery) => {
      executed.push({ sql: compiled.sql, parameters: compiled.parameters });
      return (await respond(compiled.sql)) as never;
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

const ENV = { POSTHOG_API_KEY: "x", POSTHOG_HOST: "x" } as never;

function defaultRespond(overrides?: (sql: string) => { rows: unknown[] } | null) {
  return async (sql: string) => {
    const hit = overrides?.(sql);
    if (hit) return hit;
    if (sql.includes("FROM public.thread t")) {
      return {
        rows: [
          {
            title: "T",
            topic: null,
            contacts: [],
            groups: [],
            embedding: null,
            created_by: null,
            facets: null,
            author_id: null,
            twist_id: null,
          },
        ],
      };
    }
    if (sql.includes("classification_decision")) return { rows: [] };
    // isAiEnabled() reads ai_preference.builtin_ai_disabled (canonical) and
    // user_settings.ai_enabled (legacy fallback) — no rows ⇒ enabled.
    if (sql.includes("ai_preference")) return { rows: [] };
    if (sql.includes("user_settings")) return { rows: [] };
    // rootPriorityId now resolves the oldest-role Inbox: SELECT … FROM "role"
    // INNER JOIN "priority" …  (was a single-root FROM "priority" lookup).
    if (sql.includes('from "role"')) return { rows: [{ id: "root-1" }] };
    throw new Error(`unexpected SQL in test: ${sql}`);
  };
}

const RESULT = {
  priorityId: "p-1",
  stage: "scoring",
  scores: { perPrioritySorted: [] },
  durationMs: 12.5,
  llmCalls: 1,
  cacheHits: 2,
  budgetExhausted: false,
};

describe("classifyThreadForUser decision logging", () => {
  it("logs the applied decision when a threadId is present", async () => {
    classify.mockResolvedValueOnce(RESULT);
    const executed: Executed[] = [];
    const db = testDb(executed, defaultRespond());
    const out = await classifyThreadForUser(db, ENV, {
      userId: "u-1",
      threadId: "t-1",
    });
    expect(out).toEqual({ priorityId: "p-1", pending: false });
    const log = executed.find((e) => e.sql.includes("classification_decision"));
    expect(log).toBeDefined();
    expect(log!.parameters).toEqual(
      expect.arrayContaining([
        "t-1",
        "u-1",
        "p-1",
        "scoring",
        "ts:hybrid-llm:production@deadbeef",
      ])
    );
  });

  it("logs stage 'none' with NULL priority and returns root on no-match", async () => {
    classify.mockResolvedValueOnce({ ...RESULT, priorityId: null, stage: "none" });
    const executed: Executed[] = [];
    const db = testDb(executed, defaultRespond());
    const out = await classifyThreadForUser(db, ENV, {
      userId: "u-1",
      threadId: "t-1",
    });
    expect(out).toEqual({ priorityId: "root-1", pending: false });
    const log = executed.find((e) => e.sql.includes("classification_decision"));
    expect(log).toBeDefined();
    expect(log!.parameters).toEqual(expect.arrayContaining(["none"]));
    expect(log!.parameters).not.toEqual(expect.arrayContaining(["root-1"]));
  });

  it("pre-insert (no threadId): nothing logged, pendingLog returned", async () => {
    classify.mockResolvedValueOnce(RESULT);
    const executed: Executed[] = [];
    const db = testDb(executed, defaultRespond());
    const out = await classifyThreadForUser(db, ENV, { userId: "u-1" });
    expect(out.priorityId).toBe("p-1");
    expect(out.pendingLog).toMatchObject({
      userId: "u-1",
      priorityId: "p-1",
      stage: "scoring",
      classifier: "ts:hybrid-llm:production@deadbeef",
    });
    expect(executed.some((e) => e.sql.includes("classification_decision"))).toBe(
      false
    );
  });

  it("a failed log insert is captured and does not fail the filing", async () => {
    classify.mockResolvedValueOnce(RESULT);
    captureException.mockClear();
    const executed: Executed[] = [];
    const db = testDb(
      executed,
      defaultRespond((sql) =>
        sql.includes("classification_decision")
          ? (() => {
              throw new Error("insert failed");
            })()
          : null
      )
    );
    const out = await classifyThreadForUser(db, ENV, {
      userId: "u-1",
      threadId: "t-1",
    });
    expect(out).toEqual({ priorityId: "p-1", pending: false });
    expect(captureException).toHaveBeenCalled();
  });
});

describe("classifyThreadForUser built-in AI opt-out", () => {
  it("passes aiDisabled=true to the classifier when builtin_ai_disabled is set", async () => {
    classify.mockClear();
    classify.mockResolvedValueOnce(RESULT);
    const executed: Executed[] = [];
    const db = testDb(
      executed,
      defaultRespond((sql) =>
        sql.includes("ai_preference")
          ? { rows: [{ builtin_ai_disabled: true }] }
          : null
      )
    );
    await classifyThreadForUser(db, ENV, { userId: "u-1", threadId: "t-1" });
    expect(classify).toHaveBeenCalledWith(
      expect.objectContaining({ aiDisabled: true }),
      expect.anything()
    );
  });

  it("passes aiDisabled=false when there is no ai_preference row (default enabled)", async () => {
    classify.mockClear();
    classify.mockResolvedValueOnce(RESULT);
    const executed: Executed[] = [];
    const db = testDb(executed, defaultRespond());
    await classifyThreadForUser(db, ENV, { userId: "u-1", threadId: "t-1" });
    expect(classify).toHaveBeenCalledWith(
      expect.objectContaining({ aiDisabled: false }),
      expect.anything()
    );
  });
});

describe("logClassificationDecision", () => {
  it("writes all columns with defaults applied", async () => {
    const executed: Executed[] = [];
    const db = testDb(executed, async () => ({ rows: [] }));
    await logClassificationDecision(db, ENV, {
      threadId: "t-9",
      userId: "u-9",
      priorityId: "p-9",
      stage: "user_move",
      scores: {},
      classifier: "user",
    });
    expect(executed).toHaveLength(1);
    expect(executed[0]!.sql).toContain("classification_decision");
    expect(executed[0]!.parameters).toEqual(
      expect.arrayContaining(["t-9", "u-9", "p-9", "user_move", "user", 0, false])
    );
  });
});

describe("logClassificationDecision inside a transaction", () => {
  it("guards the insert with a savepoint and survives failure without poisoning", async () => {
    captureException.mockClear();
    const executed: Executed[] = [];
    const db = testDb(executed, async (sql) => {
      if (sql.includes("INSERT INTO public.classification_decision")) {
        throw new Error("insert failed");
      }
      return { rows: [] };
    });
    await db.transaction().execute(async (trx) => {
      await logClassificationDecision(trx, ENV, {
        threadId: "t-1",
        userId: "u-1",
        priorityId: "p-1",
        stage: "scoring",
        scores: {},
        classifier: "c",
      });
      // The outer transaction must still be usable after the swallowed failure.
      await sql2`SELECT 1`.execute(trx);
    });
    const stmts = executed.map((e) => e.sql);
    expect(
      stmts.some((s) => s.startsWith("SAVEPOINT classification_decision_log"))
    ).toBe(true);
    expect(
      stmts.some((s) =>
        s.startsWith("ROLLBACK TO SAVEPOINT classification_decision_log")
      )
    ).toBe(true);
    expect(captureException).toHaveBeenCalled();
  });

  it("releases the savepoint on success", async () => {
    const executed: Executed[] = [];
    const db = testDb(executed, async () => ({ rows: [] }));
    await db.transaction().execute(async (trx) => {
      await logClassificationDecision(trx, ENV, {
        threadId: "t-1",
        userId: "u-1",
        priorityId: "p-1",
        stage: "scoring",
        scores: {},
        classifier: "c",
      });
    });
    const stmts = executed.map((e) => e.sql);
    expect(
      stmts.some((s) => s.startsWith("SAVEPOINT classification_decision_log"))
    ).toBe(true);
    expect(
      stmts.some((s) =>
        s.startsWith("RELEASE SAVEPOINT classification_decision_log")
      )
    ).toBe(true);
  });

  it("uses no savepoint on a non-transaction handle", async () => {
    const executed: Executed[] = [];
    const db = testDb(executed, async () => ({ rows: [] }));
    await logClassificationDecision(db, ENV, {
      threadId: "t-1",
      userId: "u-1",
      priorityId: "p-1",
      stage: "scoring",
      scores: {},
      classifier: "c",
    });
    expect(executed.some((e) => e.sql.includes("SAVEPOINT"))).toBe(false);
  });
});
