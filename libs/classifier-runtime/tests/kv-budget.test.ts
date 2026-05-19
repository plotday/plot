import { describe, expect, it, vi } from "vitest";

import { kvBudget } from "../src/kv-budget";

function fakeKv(): KVNamespace & { _store: Map<string, string> } {
  const store = new Map<string, string>();
  return {
    _store: store,
    async get(key: string) {
      return store.get(key) ?? null;
    },
    async put(key: string, value: string) {
      store.set(key, value);
    },
    async delete(key: string) {
      store.delete(key);
    },
    list: vi.fn() as never,
    getWithMetadata: vi.fn() as never,
  } as unknown as KVNamespace & { _store: Map<string, string> };
}

describe("kvBudget", () => {
  it("allows calls up to dailyMax and rejects beyond", async () => {
    const kv = fakeKv();
    const consume = kvBudget(kv);
    expect(await consume("user-a", 3)).toBe(true);
    expect(await consume("user-a", 3)).toBe(true);
    expect(await consume("user-a", 3)).toBe(true);
    expect(await consume("user-a", 3)).toBe(false);
  });

  it("counts per user independently", async () => {
    const kv = fakeKv();
    const consume = kvBudget(kv);
    expect(await consume("u1", 1)).toBe(true);
    expect(await consume("u1", 1)).toBe(false);
    expect(await consume("u2", 1)).toBe(true);
  });
});
