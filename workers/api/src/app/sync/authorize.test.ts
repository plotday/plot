import { describe, expect, it, vi } from "vitest";

import { assertThreadAccess, assertActivityAccess } from "./authorize";

function createMockTrx(row: any) {
  const query: any = {};
  query.select = vi.fn(() => query);
  query.where = vi.fn(() => query);
  query.executeTakeFirst = vi.fn(async () => row);
  return {
    selectFrom: vi.fn(() => query),
    _query: query,
  };
}

describe("assertThreadAccess", () => {
  it("resolves when thread_priority row exists", async () => {
    const trx = createMockTrx({ thread_id: "thread-1" });

    await expect(
      assertThreadAccess(trx as any, "user-1", "thread-1")
    ).resolves.toBeUndefined();

    expect(trx.selectFrom).toHaveBeenCalledWith("thread_priority");
    expect(trx._query.where).toHaveBeenCalledWith("thread_id", "=", "thread-1");
    expect(trx._query.where).toHaveBeenCalledWith("user_id", "=", "user-1");
  });

  it("throws 403 when no thread_priority row exists", async () => {
    const trx = createMockTrx(undefined);

    try {
      await assertThreadAccess(trx as any, "user-1", "thread-1");
      expect.fail("should have thrown");
    } catch (e: any) {
      expect(e.message).toBe("Access denied");
      expect(e.status).toBe(403);
    }
  });

  it("assertActivityAccess is an alias for assertThreadAccess", () => {
    expect(assertActivityAccess).toBe(assertThreadAccess);
  });
});
