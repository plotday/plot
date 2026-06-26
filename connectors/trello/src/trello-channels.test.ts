import { describe, expect, it } from "vitest";
import { buildCardLinkType, DONE_LIST_RE } from "./trello-channels";
import type { TrelloList } from "./trello-api";

const lists: TrelloList[] = [
  { id: "l1", name: "To Do", pos: 1 },
  { id: "l2", name: "Doing", pos: 2 },
  { id: "l3", name: "Done", pos: 3 },
];

describe("buildCardLinkType", () => {
  it("maps lists to statuses: first=todo, middle=inProgress, done-name=done+done:true", () => {
    const lt = buildCardLinkType(lists);
    expect(lt.type).toBe("card");
    expect(lt.statuses).toEqual([
      { status: "l1", label: "To Do", icon: "todo" },
      { status: "l2", label: "Doing", icon: "inProgress" },
      { status: "l3", label: "Done", icon: "done", done: true },
    ]);
    // compose defaults to the first non-done list
    expect(lt.compose).toEqual({ status: "l1" });
  });

  it("DONE_LIST_RE matches common done-column names", () => {
    expect(DONE_LIST_RE.test("Done")).toBe(true);
    expect(DONE_LIST_RE.test("Shipped")).toBe(true);
    expect(DONE_LIST_RE.test("Complete")).toBe(true);
    expect(DONE_LIST_RE.test("Backlog")).toBe(false);
  });

  it("falls back to the first list for compose when no non-done list exists", () => {
    const lt = buildCardLinkType([{ id: "d", name: "Done", pos: 1 }]);
    expect(lt.compose).toEqual({ status: "d" });
  });
});
