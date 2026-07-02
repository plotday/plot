import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PlanOperation } from "@plotday/twister/plot";

import { executePlan, executeApprovedPlan, storedPlanExists } from "./plan";
import type { Plot } from "./index";

// Shared mocks for executeApprovedPlan's collaborators. `Plot` is replaced so
// executePlan runs against inspectable spies, and `createDb` is replaced so we
// can drive the twist_instance / stored-plan lookups without a real database.
const { plotInstance, PlotCtor, createDbMock } = vi.hoisted(() => {
  const plotInstance = {
    twistInstanceId: "twist-1",
    createNote: vi.fn().mockResolvedValue("n"),
    createFocus: vi.fn().mockResolvedValue({ id: "f" }),
    updateThread: vi.fn().mockResolvedValue(undefined),
    updateLink: vi.fn().mockResolvedValue(undefined),
    createThread: vi.fn().mockResolvedValue({ id: "t" }),
    updateFocus: vi.fn().mockResolvedValue(undefined),
  };
  return {
    plotInstance,
    PlotCtor: vi.fn(() => plotInstance),
    createDbMock: vi.fn(),
  };
});

vi.mock("./index", () => ({ Plot: PlotCtor }));
vi.mock("../../../db", () => ({ createDb: createDbMock }));

function mockPlot() {
  return {
    twistInstanceId: "twist-1",
    updateThread: vi.fn().mockResolvedValue(undefined),
    updateLink: vi.fn().mockResolvedValue(undefined),
    createThread: vi.fn().mockResolvedValue({ id: "t-new" }),
    createNote: vi.fn().mockResolvedValue("n-new"),
    updateFocus: vi.fn().mockResolvedValue(undefined),
    createFocus: vi.fn().mockResolvedValue({ id: "f-new", created: true }),
  } as unknown as Plot;
}

describe("executePlan", () => {
  it("maps each current-shape operation to the right Plot call", async () => {
    const plot = mockPlot();
    const ops: PlanOperation[] = [
      { type: "createFocus", focusId: "f-1" as any, title: "Archive" },
      {
        type: "updateThread",
        threadId: "t-1" as any,
        threadTitle: "Old",
        changes: { archived: true, focus: { id: "f-1" as any, title: "Archive" } },
      },
      { type: "createThread", title: "New", focusId: "f-1" as any, focusTitle: "Archive" },
      { type: "createNote", threadId: "t-1" as any, threadTitle: "Old", content: "hi" },
      { type: "updateFocus", focusId: "f-2" as any, focusTitle: "Inbox", changes: { title: "In" } },
      { type: "updateLink", linkId: "l-1" as any, linkTitle: "Doc", changes: { threadId: "t-1" as any } },
    ];

    const results = await executePlan(plot, ops);

    expect(results).toEqual(Array(6).fill({ success: true }));
    expect(plot.createFocus).toHaveBeenCalledWith({ id: "f-1", title: "Archive" });
    expect(plot.updateThread).toHaveBeenCalledWith({
      id: "t-1",
      archived: true,
      focus: { id: "f-1" },
    });
    expect(plot.createThread).toHaveBeenCalledWith({ title: "New", focus: { id: "f-1" } });
    expect(plot.createNote).toHaveBeenCalledWith({ thread: { id: "t-1" }, content: "hi" });
    expect(plot.updateFocus).toHaveBeenCalledWith({ id: "f-2", title: "In" });
    expect(plot.updateLink).toHaveBeenCalledWith({ id: "l-1", threadId: "t-1" });
  });

  it("captures per-operation failures without aborting the batch", async () => {
    const plot = mockPlot();
    (plot.updateThread as any).mockRejectedValueOnce(new Error("boom"));
    const ops: PlanOperation[] = [
      { type: "updateThread", threadId: "t-1" as any, threadTitle: "A", changes: { archived: true } },
      { type: "createNote", threadId: "t-2" as any, threadTitle: "B", content: "ok" },
    ];

    const results = await executePlan(plot, ops);

    expect(results[0]).toEqual({ success: false, error: "boom" });
    expect(results[1]).toEqual({ success: true });
  });

  it("reports unknown operation types as failures", async () => {
    const results = await executePlan(mockPlot(), [{ type: "dropTables" } as any]);
    expect(results[0].success).toBe(false);
    expect(results[0].error).toContain("Unknown operation type");
  });
});

// -- executeApprovedPlan: server-stored plan, owner-only, capped ------------

const FULL_TOKEN = "a".repeat(64) + ":cb-token";
const OWNER = "owner-1";

/** Build a fake Kysely handle answering the two lookups executeApprovedPlan does. */
function makeDb(instanceRow: unknown, noteRow: unknown) {
  const destroy = vi.fn().mockResolvedValue(undefined);
  const chain = (result: unknown) => {
    const c: any = {
      select: () => c,
      where: () => c,
      executeTakeFirst: () => Promise.resolve(result),
    };
    return c;
  };
  const db = {
    selectFrom: (table: string) =>
      table === "twist_instance" ? chain(instanceRow) : chain(noteRow),
    destroy,
  };
  return { db, destroy };
}

function makeEnv(twistInstanceId = "twist-1") {
  const stub = {
    validateAndLoad: vi
      .fn()
      .mockResolvedValue({ ok: true, callback: { twistInstanceId } }),
  };
  return {
    CALLBACKS: {
      idFromString: vi.fn().mockReturnValue("do-id"),
      get: vi.fn().mockReturnValue(stub),
    },
  } as any;
}

/** A stored note row whose actions array contains the plan action for FULL_TOKEN. */
function planNoteRow(operations: unknown[], asString = false) {
  const actions = [
    { type: "plan", title: "P", callback: FULL_TOKEN, operations },
  ];
  return { actions: asString ? JSON.stringify(actions) : actions };
}

describe("executeApprovedPlan", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    plotInstance.createNote.mockResolvedValue("n");
    plotInstance.createFocus.mockResolvedValue({ id: "f" });
  });

  it("executes exactly the stored operations for the owner and returns them", async () => {
    const ops = [
      { type: "createNote", threadId: "t-a", content: "a" },
      { type: "createFocus", focusId: "f-1", title: "F" },
    ];
    const { db, destroy } = makeDb({ owner_id: OWNER }, planNoteRow(ops));
    createDbMock.mockReturnValue(db);

    const { results, operations } = await executeApprovedPlan(
      makeEnv(),
      FULL_TOKEN,
      OWNER
    );

    expect(operations).toEqual(ops);
    expect(results).toEqual([{ success: true }, { success: true }]);
    expect(plotInstance.createNote).toHaveBeenCalledTimes(1);
    expect(plotInstance.createFocus).toHaveBeenCalledTimes(1);
    expect(destroy).toHaveBeenCalledTimes(1);
  });

  it("ignores the request entirely — operations come from the stored note", async () => {
    // No operations are ever passed in; the only source is the stored note.
    const ops = [{ type: "createNote", threadId: "t-stored", content: "stored" }];
    const { db } = makeDb({ owner_id: OWNER }, planNoteRow(ops));
    createDbMock.mockReturnValue(db);

    const { operations } = await executeApprovedPlan(makeEnv(), FULL_TOKEN, OWNER);

    expect(operations).toEqual(ops);
  });

  it("caps execution at the first 50 stored operations", async () => {
    const ops = Array.from({ length: 60 }, (_, i) => ({
      type: "createNote",
      threadId: `t-${i}`,
      content: "x",
    }));
    const { db } = makeDb({ owner_id: OWNER }, planNoteRow(ops));
    createDbMock.mockReturnValue(db);

    const { results, operations } = await executeApprovedPlan(
      makeEnv(),
      FULL_TOKEN,
      OWNER
    );

    expect(operations).toHaveLength(50);
    expect(results).toHaveLength(50);
    expect(plotInstance.createNote).toHaveBeenCalledTimes(50);
  });

  it("rejects when the approver is not the twist owner (no execution)", async () => {
    const { db } = makeDb(
      { owner_id: OWNER },
      planNoteRow([{ type: "createNote", threadId: "t", content: "x" }])
    );
    createDbMock.mockReturnValue(db);

    await expect(
      executeApprovedPlan(makeEnv(), FULL_TOKEN, "someone-else")
    ).rejects.toMatchObject({ name: "CallbackError", type: "NOT_FOUND" });
    expect(plotInstance.createNote).not.toHaveBeenCalled();
  });

  it("rejects when there is no authenticated user (fails closed)", async () => {
    const { db } = makeDb(
      { owner_id: OWNER },
      planNoteRow([{ type: "createNote", threadId: "t", content: "x" }])
    );
    createDbMock.mockReturnValue(db);

    await expect(
      executeApprovedPlan(makeEnv(), FULL_TOKEN, null)
    ).rejects.toMatchObject({ name: "CallbackError", type: "NOT_FOUND" });
    expect(plotInstance.createNote).not.toHaveBeenCalled();
  });

  it("rejects when no stored plan matches the callback token (no execution)", async () => {
    const { db } = makeDb({ owner_id: OWNER }, undefined);
    createDbMock.mockReturnValue(db);

    await expect(
      executeApprovedPlan(makeEnv(), FULL_TOKEN, OWNER)
    ).rejects.toMatchObject({ name: "CallbackError", type: "NOT_FOUND" });
    expect(plotInstance.createNote).not.toHaveBeenCalled();
  });

  it("tolerates a JSON-string actions column (driver robustness)", async () => {
    const ops = [{ type: "createNote", threadId: "t", content: "x" }];
    const { db } = makeDb({ owner_id: OWNER }, planNoteRow(ops, /* asString */ true));
    createDbMock.mockReturnValue(db);

    const { operations } = await executeApprovedPlan(makeEnv(), FULL_TOKEN, OWNER);

    expect(operations).toEqual(ops);
    expect(plotInstance.createNote).toHaveBeenCalledTimes(1);
  });
});

// -- storedPlanExists: plan-ness check for the rejected arm -----------------

describe("storedPlanExists", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns true when a stored plan note backs the token", async () => {
    const { db, destroy } = makeDb(
      undefined,
      planNoteRow([{ type: "createNote", threadId: "t", content: "x" }])
    );
    createDbMock.mockReturnValue(db);

    await expect(storedPlanExists(makeEnv(), FULL_TOKEN)).resolves.toBe(true);
    expect(destroy).toHaveBeenCalledTimes(1);
  });

  it("returns false when no stored plan note matches the token", async () => {
    const { db, destroy } = makeDb(undefined, undefined);
    createDbMock.mockReturnValue(db);

    await expect(storedPlanExists(makeEnv(), FULL_TOKEN)).resolves.toBe(false);
    expect(destroy).toHaveBeenCalledTimes(1);
  });

  it("returns false when the note's actions contain no plan action for the token", async () => {
    const { db } = makeDb(undefined, {
      actions: [{ type: "callback", callback: FULL_TOKEN }],
    });
    createDbMock.mockReturnValue(db);

    await expect(storedPlanExists(makeEnv(), FULL_TOKEN)).resolves.toBe(false);
  });

  it("returns false when the token itself fails to resolve (invalid/expired)", async () => {
    const stub = {
      validateAndLoad: vi
        .fn()
        .mockResolvedValue({ __error: true, type: "NOT_FOUND" }),
    };
    const env = {
      CALLBACKS: {
        idFromString: vi.fn().mockReturnValue("do-id"),
        get: vi.fn().mockReturnValue(stub),
      },
    } as any;

    await expect(storedPlanExists(env, FULL_TOKEN)).resolves.toBe(false);
    // Short-circuits before opening a DB connection.
    expect(createDbMock).not.toHaveBeenCalled();
  });
});
