import { describe, expect, it } from "vitest";
import type { Uuid } from "@plotday/twister";

import { describeOperation, summarizeOperations, validateOperations } from "./planner";

const threads = [{ id: "t-1" }, { id: "t-2" }];
const focuses = [{ id: "f-1" }];
let n = 0;
const genId = () => `new-${++n}` as Uuid;

describe("validateOperations", () => {
  it("drops ops referencing unknown thread/focus ids", () => {
    const ops = validateOperations(
      [
        { type: "updateThread", threadId: "ghost", threadTitle: "?", changes: { archived: true } },
        { type: "updateThread", threadId: "t-1", threadTitle: "A", changes: { archived: true } },
        { type: "updateFocus", focusId: "ghost", focusTitle: "?", changes: { title: "X" } },
      ] as any,
      threads,
      focuses,
      genId
    );
    expect(ops).toHaveLength(1);
    expect(ops[0]).toMatchObject({ type: "updateThread", threadId: "t-1" });
  });

  it("assigns ids to createFocus ops, orders them first, and remaps moves by title", () => {
    const ops = validateOperations(
      [
        {
          type: "updateThread",
          threadId: "t-1",
          threadTitle: "A",
          changes: { focus: { id: "", title: "Archive 2025" } },
        },
        { type: "createFocus", title: "Archive 2025" },
        { type: "createThread", title: "Index", focusId: "", focusTitle: "Archive 2025" },
      ] as any,
      threads,
      focuses,
      genId
    );
    expect(ops[0].type).toBe("createFocus");
    const focusId = (ops[0] as any).focusId;
    expect(focusId).toMatch(/^new-/);
    expect((ops[1] as any).changes.focus.id).toBe(focusId);
    expect((ops[2] as any).focusId).toBe(focusId);
  });

  it("caps at 50 operations", () => {
    const many = Array.from({ length: 60 }, (_, i) => ({
      type: "createNote",
      threadId: "t-1",
      threadTitle: "A",
      content: `note ${i}`,
    }));
    expect(validateOperations(many as any, threads, focuses, genId)).toHaveLength(50);
  });
});

describe("describeOperation / summarizeOperations", () => {
  it("describes createFocus and focus moves", () => {
    expect(
      describeOperation({ type: "createFocus", focusId: "f" as Uuid, title: "Archive" })
    ).toContain("Create focus");
    const summary = summarizeOperations([
      {
        type: "updateThread",
        threadId: "t-1" as Uuid,
        threadTitle: "A",
        changes: { focus: { id: "f-1" as Uuid, title: "Archive" } },
      },
    ]);
    expect(summary).toContain("Move **A** to **Archive**");
  });
});
