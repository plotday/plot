import { describe, expect, it } from "vitest";

import {
  DEFAULTS_LLM,
  makeHybridLlmClassifier,
  type LLMClient,
} from "../src";
import { fyiFallback, isFyiFormat } from "../src/ts-hybrid-stages";
import type { Candidate, ClassifierContext } from "../src/types";

/**
 * A ClassifierContext whose rawQuery answers the two queries fyiFallback makes:
 * the `author_has_real_focus_home` gate and the role-affinity FYI lookup.
 */
function makeCtx(opts: {
  trained?: boolean;
  fyiRow?: { priority_id: string; role_id: string; n: number } | null;
}): ClassifierContext {
  return {
    db: {} as ClassifierContext["db"],
    userId: "00000000-0000-0000-0000-000000000001",
    schemaName: "sandbox",
    corpusName: "test",
    rawQuery: async (text: string) => {
      if (text.includes("author_has_real_focus_home")) {
        return { rows: [{ trained: opts.trained ?? false }] };
      }
      // The role-affinity FYI lookup (the only other query).
      return { rows: opts.fyiRow ? [opts.fyiRow] : [] };
    },
  };
}

function candidate(overrides: Partial<Candidate> = {}): Candidate {
  return {
    threadId: "t1",
    title: "Weekly newsletter",
    topic: null,
    contacts: ["00000000-0000-0000-0000-0000000000c1"],
    groups: [],
    embedding: null,
    author: "00000000-0000-0000-0000-0000000000a1",
    facets: { format: "promotion" },
    authorContactId: "00000000-0000-0000-0000-0000000000ac",
    connectionId: null,
    ...overrides,
  };
}

describe("fyiFallback (per-role)", () => {
  it("routes low-signal mail to the best-matching role's FYI", async () => {
    const ctx = makeCtx({
      trained: false,
      fyiRow: { priority_id: "fyi-work", role_id: "role-work", n: 3 },
    });
    const result = await fyiFallback(ctx, candidate());
    expect(result?.priorityId).toBe("fyi-work");
    expect(result?.stage).toBe("fyi_fallback");
    expect(result?.scores.role_id).toBe("role-work");
    expect(result?.scores.format).toBe("promotion");
  });

  it("yields when the author already has a learned real-focus home", async () => {
    const ctx = makeCtx({
      trained: true,
      fyiRow: { priority_id: "fyi-work", role_id: "role-work", n: 3 },
    });
    expect(await fyiFallback(ctx, candidate())).toBeNull();
  });

  it("still routes when the candidate has no author contact (skips the gate)", async () => {
    const ctx = makeCtx({
      fyiRow: { priority_id: "fyi-personal", role_id: "role-personal", n: 0 },
    });
    const result = await fyiFallback(
      ctx,
      candidate({ authorContactId: null })
    );
    expect(result?.priorityId).toBe("fyi-personal");
  });

  it("fails open when no role has a live FYI", async () => {
    const ctx = makeCtx({ trained: false, fyiRow: null });
    expect(await fyiFallback(ctx, candidate())).toBeNull();
  });

  it("ignores non-FYI formats without querying", async () => {
    const ctx = makeCtx({
      fyiRow: { priority_id: "fyi-work", role_id: "role-work", n: 3 },
    });
    expect(
      await fyiFallback(ctx, candidate({ facets: { format: "message" } }))
    ).toBeNull();
  });
});

/**
 * Integration guard for the cascade production actually runs
 * (`ts:hybrid-llm:production`, built from ts-hybrid-llm.ts). The fyiFallback
 * stage must be wired into THIS cascade, not just the non-LLM ts-hybrid.ts —
 * otherwise low-signal mail never reaches FYI in production (it falls through
 * to scoring and lands in a topical focus).
 */
describe("makeHybridLlmClassifier — FYI routing in the production cascade", () => {
  function cascadeCtx(opts: {
    trained?: boolean;
    fyiRow?: { priority_id: string; role_id: string; n: number } | null;
  }): ClassifierContext {
    return {
      db: {} as never,
      userId: "00000000-0000-0000-0000-000000000001",
      schemaName: "public",
      corpusName: "test",
      async rawQuery(text: string) {
        if (text.includes("author_has_real_focus_home")) {
          return { rows: [{ trained: opts.trained ?? false }] };
        }
        // fyiFallback's role-affinity lookup is the only query that joins
        // `fyi.is_fyi`. Every other stage query (prefix, keyed, title,
        // scoring, role-Inbox, cold-start tree, ...) returns nothing so the
        // only stage that *can* fire is fyiFallback.
        if (text.includes("is_fyi")) {
          return { rows: opts.fyiRow ? [opts.fyiRow] : [] };
        }
        return { rows: [] };
      },
    };
  }

  function spyLlm(): { client: LLMClient; calls: unknown[] } {
    const calls: unknown[] = [];
    const client: LLMClient = {
      id: "stub:never-needed",
      async classify(inputs) {
        calls.push(inputs);
        return {
          priorityId: inputs.allowedPriorityIds[0] ?? null,
          rationale: "stub",
        };
      },
    };
    return { client, calls };
  }

  // A low-signal connector email (e.g. the "[GitHub] Annual Billing Alert"
  // that prompted this fix): facet format "reading", no topic.
  const fyiCandidate: Candidate = {
    threadId: "",
    title: "[GitHub] Annual Billing Alert",
    topic: null,
    contacts: ["00000000-0000-0000-0000-0000000000c1"],
    groups: [],
    embedding: null,
    author: "00000000-0000-0000-0000-0000000000a1",
    facets: { format: "reading", reach: "list", automation: "automated" },
    authorContactId: "00000000-0000-0000-0000-0000000000ac",
    connectionId: null,
  };

  it("routes an FYI-format thread to the role's FYI focus (deterministic, no LLM)", async () => {
    const { client, calls } = spyLlm();
    const classifier = makeHybridLlmClassifier("test:fyi-cascade", {
      params: DEFAULTS_LLM,
      llmClientFor: () => client,
    });

    const result = await classifier.classify(
      cascadeCtx({
        trained: false,
        fyiRow: { priority_id: "fyi-work", role_id: "role-work", n: 3 },
      }),
      fyiCandidate
    );

    expect(result.stage).toBe("fyi_fallback");
    expect(result.priorityId).toBe("fyi-work");
    expect(calls).toHaveLength(0);
  });

  it("yields FYI to the sender's learned real-focus home (gate honored in-cascade)", async () => {
    const { client } = spyLlm();
    const classifier = makeHybridLlmClassifier("test:fyi-cascade-trained", {
      params: DEFAULTS_LLM,
      llmClientFor: () => client,
    });

    const result = await classifier.classify(
      cascadeCtx({
        trained: true,
        fyiRow: { priority_id: "fyi-work", role_id: "role-work", n: 3 },
      }),
      fyiCandidate
    );

    expect(result.stage).not.toBe("fyi_fallback");
  });
});

describe("isFyiFormat", () => {
  it("routes low-signal formats to FYI", () => {
    for (const format of ["promotion", "reading", "receipt", "notification"]) {
      expect(isFyiFormat({ format })).toBe(true);
    }
  });

  it("keeps human collaboration out of FYI", () => {
    expect(isFyiFormat({ format: "message" })).toBe(false);
    expect(isFyiFormat({ format: "chat" })).toBe(false);
  });

  it("keeps actionable formats out of FYI", () => {
    expect(isFyiFormat({ format: "invoice" })).toBe(false);
    expect(isFyiFormat({ format: "otp" })).toBe(false);
    expect(isFyiFormat({ format: "confirm" })).toBe(false);
  });

  it("fails open on null/absent format", () => {
    expect(isFyiFormat(null)).toBe(false);
    expect(isFyiFormat({})).toBe(false);
    expect(isFyiFormat({ automation: "automated" })).toBe(false);
  });
});
