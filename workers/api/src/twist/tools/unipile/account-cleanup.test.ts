import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { Bindings } from "../../../env";
import { deleteUnipileAccount, selectOrphanAccountIds } from "./account-cleanup";

const env = {
  UNIPILE_API_KEY: "test-key",
  UNIPILE_WEBHOOK_SECRET: "test-secret",
} as unknown as Bindings;

describe("deleteUnipileAccount", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    fetchSpy = vi.spyOn(globalThis, "fetch");
  });
  afterEach(() => {
    fetchSpy.mockRestore();
  });

  it("DELETEs the account on the Unipile API", async () => {
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 204 }));
    await deleteUnipileAccount(env, "acct-1");
    expect(fetchSpy).toHaveBeenCalledOnce();
    const [url, init] = fetchSpy.mock.calls[0]!;
    expect(String(url)).toBe(
      "https://api.unipile.com/v2/accounts/acct-1"
    );
    expect(init?.method).toBe("DELETE");
  });

  it("swallows a 404 (account already gone)", async () => {
    fetchSpy.mockResolvedValueOnce(new Response('{"status":404}', { status: 404 }));
    await expect(deleteUnipileAccount(env, "gone")).resolves.toBeUndefined();
  });

  it("never throws on an unexpected error and reports it to the tracker", async () => {
    fetchSpy.mockResolvedValueOnce(new Response('{"status":500}', { status: 500 }));
    const tracker = { captureException: vi.fn() };
    await expect(
      deleteUnipileAccount(env, "boom", { tracker })
    ).resolves.toBeUndefined();
    expect(tracker.captureException).toHaveBeenCalledOnce();
  });
});

describe("selectOrphanAccountIds", () => {
  const accounts = [
    { id: "new", identity: "member-A" },
    { id: "old-1", identity: "member-A" },
    { id: "old-2", identity: "member-A" },
    { id: "other-user", identity: "member-B" },
    { id: "unknown", identity: null },
  ];

  it("selects same-identity accounts, excluding the new one", () => {
    const result = selectOrphanAccountIds(accounts, "new", "member-A", new Set());
    expect(result.sort()).toEqual(["old-1", "old-2"]);
  });

  it("never selects accounts for a different identity", () => {
    const result = selectOrphanAccountIds(accounts, "new", "member-A", new Set());
    expect(result).not.toContain("other-user");
    expect(result).not.toContain("unknown");
  });

  it("skips accounts still referenced by a live connection", () => {
    const result = selectOrphanAccountIds(
      accounts,
      "new",
      "member-A",
      new Set(["old-1"])
    );
    expect(result).toEqual(["old-2"]);
  });

  it("returns nothing when the identity is unknown", () => {
    expect(selectOrphanAccountIds(accounts, "new", "", new Set())).toEqual([]);
  });
});
