import { describe, expect, it, vi } from "vitest";

import { createNote, resolveLinkIdForConnectorNote } from "./note";

vi.mock("../../../rpc", () => ({
  rpc: vi.fn(async () => null),
  rpcUser: vi.fn(async () => {
    throw new Error("rpcUser not expected");
  }),
}));

function createDb(rows: Array<{ id: string }>) {
  return {
    selectFrom: vi.fn(() => ({
      select: vi.fn().mockReturnThis(),
      where: vi.fn().mockReturnThis(),
      orderBy: vi.fn().mockReturnThis(),
      execute: vi.fn(async () => rows),
    })),
  } as any;
}

describe("resolveLinkIdForConnectorNote", () => {
  it("returns the only matching link's id", async () => {
    const db = createDb([{ id: "link-1" }]);
    const id = await resolveLinkIdForConnectorNote(
      db,
      "thread-1",
      "twist-instance-1"
    );
    expect(id).toBe("link-1");
  });

  it("returns null when no link matches", async () => {
    const db = createDb([]);
    const id = await resolveLinkIdForConnectorNote(
      db,
      "thread-1",
      "twist-instance-1"
    );
    expect(id).toBeNull();
  });

  it("throws when multiple links match", async () => {
    const db = createDb([{ id: "link-1" }, { id: "link-2" }]);
    await expect(
      resolveLinkIdForConnectorNote(db, "thread-1", "twist-instance-1")
    ).rejects.toThrow(/2 links from this connector/);
  });
});

// -- createNote integration: link_id propagation -----------------------------

type SelectQueryResult = Record<string, any> | null;

function createSelectQuery(result: SelectQueryResult, executeRows?: any[]) {
  const query: any = {};
  query.select = vi.fn(() => query);
  query.selectAll = vi.fn(() => query);
  query.innerJoin = vi.fn(() => query);
  query.leftJoin = vi.fn(() => query);
  query.where = vi.fn(() => query);
  query.orderBy = vi.fn(() => query);
  query.limit = vi.fn(() => query);
  query.execute = vi.fn(async () =>
    executeRows ?? (Array.isArray(result) ? result : result ? [result] : [])
  );
  query.executeTakeFirst = vi.fn(async () => result);
  query.executeTakeFirstOrThrow = vi.fn(async () => {
    if (!result) throw new Error("Not found");
    return result;
  });
  return query;
}

/**
 * Insert mock that captures `.values(...)` and supports the ON CONFLICT
 * chain `.columns([...]).where(...).doUpdateSet(...).where(...)` used by
 * createNote's keyed upsert. `returningAll().executeTakeFirst()` resolves
 * to the supplied result row.
 */
function createInsertQuery(result: any) {
  const query: any = {};
  query._values = undefined as any;
  query.values = vi.fn((values: any) => {
    query._values = values;
    return query;
  });
  query.onConflict = vi.fn((cb: (oc: any) => void) => {
    if (cb) {
      const action: any = {};
      action.doUpdateSet = vi.fn(() => action);
      action.doNothing = vi.fn(() => action);
      action.where = vi.fn(() => action);
      const ocBuilder: any = {
        columns: vi.fn(() => ({
          where: vi.fn(() => action),
          doUpdateSet: vi.fn(() => action),
        })),
      };
      cb(ocBuilder);
    }
    return query;
  });
  query.returningAll = vi.fn(() => query);
  query.returning = vi.fn(() => query);
  query.execute = vi.fn(async () =>
    Array.isArray(result) ? result : result ? [result] : []
  );
  query.executeTakeFirst = vi.fn(async () => result);
  query.executeTakeFirstOrThrow = vi.fn(async () => {
    if (!result) throw new Error("Not found");
    return result;
  });
  return query;
}

/**
 * Builds a minimal stand-in for a Plot instance with just the surface
 * createNote() touches. We deliberately avoid constructing a real Plot
 * (which pulls in AI, RPC, env bindings) — createNote only reads fields
 * and calls a handful of methods on `plot`.
 */
// Minimal Kysely executor so raw `sql`...`.execute(plot.db)` calls in
// createNote (e.g. the per-note advisory lock) resolve in tests whose mock db
// only stubs selectFrom/insertInto. Returns no rows — the advisory lock awaits
// the result and ignores it.
const noopRawExecutor: any = {
  transformQuery: (node: unknown) => node,
  compileQuery: () => ({ sql: "", parameters: [] }),
  executeQuery: async () => ({ rows: [] }),
};

function makePlotStub({
  db,
  twistInstanceId = "twist-instance-1",
}: {
  db: any;
  twistInstanceId?: string;
}) {
  // Raw `sql`...`.execute(plot.db)` needs a Kysely executor; provide a noop one
  // for mock dbs that only stub selectFrom/insertInto.
  if (!db.getExecutor) db.getExecutor = () => noopRawExecutor;
  return {
    db,
    twistInstanceId,
    syncDepth: 1,
    plotOptions: {},
    env: { AI: { run: vi.fn() } },
    ai: { embed: vi.fn() },
    isAiEnabled: vi.fn(async () => false),
    notifySyncDOs: vi.fn(async () => undefined),
    getUpdatedBy: vi.fn(() => 0),
    getUserId: vi.fn(async () => "user-1"),
    getPriorityRoot: vi.fn(async () => "priority-root"),
  } as any;
}

describe("createNote → link_id propagation", () => {
  it("uses activityContext.link_id when provided", async () => {
    const noteInsert = createInsertQuery({
      id: "note-123",
      thread_id: "thread-1",
      source_created_at: new Date().toISOString(),
    });

    // activityContext provides priority_id and link_id, but createNote still
    // looks up thread.created_by for auto-mention logic when activityContext
    // doesn't carry it. Match plot.twistInstanceId to short-circuit the
    // twist_instance lookup that would otherwise follow.
    const db = {
      selectFrom: vi.fn((table: string) => {
        if (table === "thread") {
          return createSelectQuery({ created_by: "twist-instance-1" });
        }
        return createSelectQuery(null);
      }),
      insertInto: vi.fn((table: string) => {
        if (table === "note") return noteInsert;
        return createInsertQuery(null);
      }),
    } as any;

    const plot = makePlotStub({ db });

    const result = await createNote(
      plot,
      {
        thread: { id: "thread-1" as any },
        content: "hello world",
        unread: true, // skip read-marking branches
      },
      true,
      { priority_id: "priority-1", link_id: "link-1" },
      true
    );

    expect(result).toBe("note-123");
    expect(noteInsert._values).toBeDefined();
    expect(noteInsert._values.link_id).toBe("link-1");
    expect(noteInsert._values.thread_id).toBe("thread-1");
  });

  it("resolves link_id from connector links when activityContext is omitted", async () => {
    const noteInsert = createInsertQuery({
      id: "note-456",
      thread_id: "thread-1",
      source_created_at: new Date().toISOString(),
    });

    // No activityContext → createNote looks up thread + thread_priority,
    // calls getUserId(), then (because the note is keyed and we have a
    // twistInstanceId) calls resolveLinkIdForConnectorNote which queries
    // selectFrom("link"). Mock that link query to return a single link.
    const db = {
      selectFrom: vi.fn((table: string) => {
        if (table === "thread") {
          return createSelectQuery({ created_by: "twist-instance-1" });
        }
        if (table === "thread_priority") {
          return createSelectQuery({ priority_id: "priority-1" });
        }
        if (table === "link") {
          // resolveLinkIdForConnectorNote uses .execute() which returns the
          // executeRows array.
          return createSelectQuery(null, [{ id: "resolved-link" }]);
        }
        return createSelectQuery(null);
      }),
      insertInto: vi.fn((table: string) => {
        if (table === "note") return noteInsert;
        return createInsertQuery(null);
      }),
    } as any;

    const plot = makePlotStub({ db });

    const result = await createNote(
      plot,
      {
        thread: { id: "thread-1" as any },
        content: "hello world",
        key: "external-id",
        unread: true,
      },
      true,
      undefined,
      true
    );

    expect(result).toBe("note-456");
    expect(noteInsert._values).toBeDefined();
    expect(noteInsert._values.link_id).toBe("resolved-link");
    expect(noteInsert._values.key).toBe("external-id");
  });
});
