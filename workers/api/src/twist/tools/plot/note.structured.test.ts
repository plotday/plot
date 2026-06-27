import { describe, expect, it, vi } from "vitest";
import { createNote } from "./note";

// Mirror the mock harness from note-link-scoping.test.ts (unit seam, no real DB).
vi.mock("../../../rpc", () => ({
  rpc: vi.fn(async () => null),
  rpcUser: vi.fn(async () => {
    throw new Error("rpcUser not expected");
  }),
}));

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
 * Insert mock that captures `.values(...)` so tests can assert on the
 * exact columns passed to the DB. Supports the ON CONFLICT chain used by
 * createNote's keyed upsert.
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

describe("createNote — structured-item fields", () => {
  it("persists sectionKey/sectionLabel/sectionPosition/itemPosition to the note row", async () => {
    const noteInsert = createInsertQuery({
      id: "note-123",
      thread_id: "thread-1",
      source_created_at: new Date().toISOString(),
    });

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

    await createNote(
      plot,
      {
        thread: { id: "thread-1" as any },
        key: "checkitem-1",
        content: "Do the thing",
        sectionKey: "checklist-9",
        sectionLabel: "QA",
        sectionPosition: "a0",
        itemPosition: "a1",
      },
      true,
      { priority_id: "priority-1", link_id: "link-1" },
      true
    );

    expect(noteInsert._values).toBeDefined();
    expect(noteInsert._values.section_key).toBe("checklist-9");
    expect(noteInsert._values.section_label).toBe("QA");
    expect(noteInsert._values.section_position).toBe("a0");
    expect(noteInsert._values.item_position).toBe("a1");
  });

  it("persists null for omitted section fields", async () => {
    const noteInsert = createInsertQuery({
      id: "note-456",
      thread_id: "thread-1",
      source_created_at: new Date().toISOString(),
    });

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

    await createNote(
      plot,
      {
        thread: { id: "thread-1" as any },
        content: "Plain note",
        unread: true,
      },
      true,
      { priority_id: "priority-1", link_id: "link-1" },
      true
    );

    expect(noteInsert._values).toBeDefined();
    expect(noteInsert._values.section_key).toBeNull();
    expect(noteInsert._values.section_label).toBeNull();
    expect(noteInsert._values.section_position).toBeNull();
    expect(noteInsert._values.item_position).toBeNull();
  });
});
