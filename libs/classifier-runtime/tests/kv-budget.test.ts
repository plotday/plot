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

function ym(now: Date): string {
  return `${now.getUTCFullYear()}${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
}

describe("kvBudget", () => {
  it("monthly pool absorbs imports with no daily throttle", async () => {
    const kv = fakeKv();
    const consume = kvBudget(kv);
    const limits = { monthlyMax: 5, dailyMax: 2 };
    // Five calls all clear despite dailyMax=2: while the monthly pool has
    // room the daily cap is bypassed (the import burst is not throttled).
    for (let i = 0; i < 5; i++) {
      expect(await consume("u", limits)).toBe(true);
    }
    // Sixth: monthly pool spent (5>=5) and the day counter is also 5>=2.
    expect(await consume("u", limits)).toBe(false);
  });

  it("falls back to the daily cap once the monthly pool is exhausted", async () => {
    const kv = fakeKv();
    const limits = { monthlyMax: 10, dailyMax: 2 };
    // Simulate a fresh day after the monthly pool was already drained.
    kv._store.set(`llm-budget-month:u:${ym(new Date())}`, "10");
    const consume = kvBudget(kv);
    expect(await consume("u", limits)).toBe(true); // day 0<2 → allowed
    expect(await consume("u", limits)).toBe(true); // day 1<2 → allowed
    expect(await consume("u", limits)).toBe(false); // day 2>=2 → throttled
  });

  it("counts per user independently", async () => {
    const kv = fakeKv();
    const consume = kvBudget(kv);
    const limits = { monthlyMax: 1, dailyMax: 1 };
    expect(await consume("u1", limits)).toBe(true);
    expect(await consume("u1", limits)).toBe(false);
    expect(await consume("u2", limits)).toBe(true);
  });
});
