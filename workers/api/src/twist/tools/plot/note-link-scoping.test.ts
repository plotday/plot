import { describe, expect, it, vi } from "vitest";

import { resolveLinkIdForConnectorNote } from "./note";

vi.mock("../../rpc", () => ({
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
