import { describe, expect, it } from "vitest";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { cachedLlmClient, hashInputs } from "../src/classifiers/llm-cache";
import type { LLMClient, LLMInputs } from "@plotday/classifier";

const baseInputs: LLMInputs = {
  system: "sys",
  user: "user",
  allowedPriorityIds: ["P2", "P1"],
};

describe("hashInputs", () => {
  it("is stable across allowed-priority order", () => {
    const a = hashInputs("model", "tmpl", baseInputs);
    const b = hashInputs("model", "tmpl", {
      ...baseInputs,
      allowedPriorityIds: ["P1", "P2"],
    });
    expect(a).toBe(b);
  });
  it("differs when prompt id changes", () => {
    expect(hashInputs("model", "t1", baseInputs)).not.toBe(
      hashInputs("model", "t2", baseInputs)
    );
  });
  it("differs when model changes", () => {
    expect(hashInputs("m1", "t", baseInputs)).not.toBe(
      hashInputs("m2", "t", baseInputs)
    );
  });
});

describe("cachedLlmClient", () => {
  it("returns cached response on second call and persists to disk", async () => {
    const dir = await mkdtemp(join(tmpdir(), "llm-cache-"));
    let calls = 0;
    const stub: LLMClient = {
      id: "stub",
      async classify() {
        calls++;
        return { priorityId: "P1", rationale: "r" };
      },
    };
    const wrapped = cachedLlmClient({
      client: stub,
      cacheDir: dir,
      namespace: "test",
      promptTemplateId: "tiebreaker-v1",
    });

    const a = await wrapped.classify(baseInputs);
    const b = await wrapped.classify(baseInputs);
    // Replays are identical except for the fromCache marker.
    expect(b).toEqual({ ...a, fromCache: true });
    expect(calls).toBe(1);
    expect(wrapped.stats.misses).toBe(1);
    expect(wrapped.stats.hits).toBe(1);

    const hash = hashInputs(stub.id, "tiebreaker-v1", baseInputs);
    const file = join(dir, "test", `${hash}.json`);
    const text = await readFile(file, "utf-8");
    expect(JSON.parse(text)).toMatchObject({
      response: { priorityId: "P1", rationale: "r" },
      promptTemplateId: "tiebreaker-v1",
    });
  });
});
