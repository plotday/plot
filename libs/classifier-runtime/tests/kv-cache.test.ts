import { describe, expect, it, vi } from "vitest";

import type { LLMClient, LLMInputs, LLMOutput } from "@plotday/classifier";

import { kvLlmCache } from "../src/kv-cache";

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

function stubClient(out: LLMOutput): LLMClient & {
  calls: LLMInputs[];
} {
  const calls: LLMInputs[] = [];
  return {
    id: "stub:model",
    calls,
    async classify(inputs: LLMInputs): Promise<LLMOutput> {
      calls.push(inputs);
      return out;
    },
  };
}

const inputs: LLMInputs = {
  system: "system prompt",
  user: "user prompt",
  allowedPriorityIds: ["p1", "p2"],
};

describe("kvLlmCache", () => {
  it("caches by promptId + inputs", async () => {
    const kv = fakeKv();
    const inner = stubClient({ priorityId: "p1", rationale: "stub" });
    const cached = kvLlmCache({ client: inner, kv, promptId: "v1" });

    const r1 = await cached.classify(inputs);
    expect(r1.priorityId).toBe("p1");
    expect(inner.calls.length).toBe(1);
    expect(cached.stats.misses).toBe(1);
    expect(cached.stats.hits).toBe(0);

    const r2 = await cached.classify(inputs);
    expect(r2.priorityId).toBe("p1");
    expect(inner.calls.length).toBe(1);
    expect(cached.stats.hits).toBe(1);
  });

  it("invalidates on promptId change", async () => {
    const kv = fakeKv();
    const inner = stubClient({ priorityId: "p1", rationale: "stub" });
    const c1 = kvLlmCache({ client: inner, kv, promptId: "v1" });
    const c2 = kvLlmCache({ client: inner, kv, promptId: "v2" });
    await c1.classify(inputs);
    await c2.classify(inputs);
    expect(inner.calls.length).toBe(2);
  });

  it("uses sorted allowedPriorityIds in the key", async () => {
    const kv = fakeKv();
    const inner = stubClient({ priorityId: "p1", rationale: "stub" });
    const cached = kvLlmCache({ client: inner, kv, promptId: "v1" });
    await cached.classify({ ...inputs, allowedPriorityIds: ["p1", "p2"] });
    await cached.classify({ ...inputs, allowedPriorityIds: ["p2", "p1"] });
    expect(inner.calls.length).toBe(1);
  });

  it("swallows cache write failures", async () => {
    const kv = fakeKv();
    (kv as { put: (...args: unknown[]) => Promise<void> }).put = async () => {
      throw new Error("KV down");
    };
    const inner = stubClient({ priorityId: "p1", rationale: "stub" });
    const cached = kvLlmCache({ client: inner, kv, promptId: "v1" });
    const r = await cached.classify(inputs);
    expect(r.priorityId).toBe("p1");
  });
});
