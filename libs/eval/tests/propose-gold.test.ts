import { describe, expect, it } from "vitest";

import { hashInputs } from "../src/classifiers/llm-cache";
import type { LLMClient, LLMInputs } from "../src/classifiers/llm-client";
import type {
  Corpus,
  CorpusCase,
  CorpusTrainingSet,
  CorpusTrainingThread,
  CorpusWorld,
} from "../src/corpus/schema";
import {
  applyProposals,
  buildProposePrompt,
  MAX_EXEMPLARS,
  PROPOSE_GOLD_PROMPT_ID,
  proposeForCases,
  type Proposal,
} from "../src/seeder/propose-gold";

// ===========================================================================
// Fixtures (in-memory; no DB, no live LLM)
// ===========================================================================

const P_WORK = "00000000-0000-4000-8000-000000000010";
const P_FIN = "00000000-0000-4000-8000-000000000011";
const P_HOME = "00000000-0000-4000-8000-000000000012";

function makeWorld(): CorpusWorld {
  return {
    name: "propose-gold-fixture",
    description: "",
    schemaVersion: 2,
    source: { kind: "handcrafted", extracted_at: null, anonymized: false },
    user: {
      id: "00000000-0000-4000-8000-000000000001",
      email: "u@example.test",
      primary_contact_id: null,
      subscription: null,
    },
    teams: [],
    connections: [],
    priorities: [
      {
        slug: "work",
        id: P_WORK,
        path: "root.work",
        title: "Work",
        key: null,
        description: "Day job projects and meetings",
        facetFilters: null,
      },
      {
        slug: "finance-admin",
        id: P_FIN,
        path: "root.work.finance",
        title: "Finance Admin",
        key: "FIN",
        description: null,
        facetFilters: null,
      },
      {
        slug: "home",
        id: P_HOME,
        path: "root.home",
        title: "Home",
        key: null,
        description: "Family and household",
        facetFilters: null,
      },
    ],
    contacts: [],
    groups: [],
    channels: [],
    embeddings: [],
  };
}

function makeTrainingThread(
  i: number,
  filedToPriority: string
): CorpusTrainingThread {
  return {
    id: `00000000-0000-4000-8000-${String(100000 + i).padStart(12, "0")}`,
    title: `Exemplar ${String(i).padStart(2, "0")}`,
    topic: null,
    contacts: [],
    groups: [],
    embedding_ref: null,
    authorContactId: null,
    connectionId: null,
    createdByOverride: null,
    facets: null,
    createdAt: null,
    filedToPriority,
    movedAt: null,
  };
}

function makeTrainingSet(threadCount: number): CorpusTrainingSet {
  return {
    name: "full",
    description: "",
    threads: Array.from({ length: threadCount }, (_, i) =>
      makeTrainingThread(i, i % 2 === 0 ? P_WORK : P_FIN)
    ),
    negativeThreads: [],
    negatives: [],
  };
}

function makeCandidate(
  overrides: Partial<CorpusCase["candidate"]> = {}
): CorpusCase["candidate"] {
  return {
    title: "Quarterly invoice from Acme",
    topic: "channel:42",
    contacts: ["c-1", "c-2"],
    groups: [],
    embedding_ref: null,
    authorContactId: "00000000-0000-4000-8000-000000000099",
    connectionId: null,
    createdByOverride: null,
    facets: { origin: "email" },
    ...overrides,
  };
}

function makeCase(
  id: string,
  gold: string | null,
  candidate = makeCandidate()
): CorpusCase {
  return {
    id,
    sourceThreadId: null,
    tags: [],
    asOf: null,
    description: "",
    candidate,
    labels: {
      gold,
      goldRationale: gold === null ? "" : "human says so",
      goldSource: gold === null ? null : "human",
      expected: null,
      expectedStage: null,
      expectedRecordedAt: null,
    },
    notes: "",
  };
}

function makeCorpus(cases: CorpusCase[]): Corpus {
  const world = makeWorld();
  return {
    name: world.name,
    rootDir: "/nonexistent",
    world,
    trainingSets: [makeTrainingSet(4)],
    cases,
    embeddings: new Map(),
  };
}

// ===========================================================================
// buildProposePrompt
// ===========================================================================

describe("buildProposePrompt", () => {
  it("renders the priority tree with ids, titles, descriptions, and path breadcrumbs", () => {
    const prompt = buildProposePrompt(
      makeWorld(),
      makeTrainingSet(4),
      makeCandidate()
    );
    expect(prompt.user).toContain(`id: ${P_WORK}`);
    expect(prompt.user).toContain("title: Work");
    expect(prompt.user).toContain("description: Day job projects and meetings");
    expect(prompt.user).toContain("path: root > work > finance");
    expect(prompt.user).toContain("title: Finance Admin");
    expect(prompt.user).toContain("title: Home");
    expect(prompt.user).toContain("description: Family and household");
  });

  it("includes all candidate fields", () => {
    const prompt = buildProposePrompt(
      makeWorld(),
      makeTrainingSet(4),
      makeCandidate()
    );
    expect(prompt.user).toContain("title: Quarterly invoice from Acme");
    expect(prompt.user).toContain("topic: channel:42");
    expect(prompt.user).toContain("contacts: 2");
    expect(prompt.user).toContain("author: present");
    expect(prompt.user).toContain("facets: origin=email");
  });

  it("renders absent topic/author and omits empty facets", () => {
    const prompt = buildProposePrompt(
      makeWorld(),
      makeTrainingSet(4),
      makeCandidate({
        topic: null,
        authorContactId: null,
        createdByOverride: null,
        facets: null,
        contacts: [],
      })
    );
    expect(prompt.user).toContain("topic: (none)");
    expect(prompt.user).toContain("contacts: 0");
    expect(prompt.user).toContain("author: absent");
    expect(prompt.user).not.toContain("facets:");
  });

  it("returns every world priority id as allowedPriorityIds", () => {
    const prompt = buildProposePrompt(
      makeWorld(),
      makeTrainingSet(4),
      makeCandidate()
    );
    expect(prompt.allowedPriorityIds).toEqual([P_WORK, P_FIN, P_HOME]);
  });

  it("includes training exemplars as title → priority-title lines", () => {
    const prompt = buildProposePrompt(
      makeWorld(),
      makeTrainingSet(4),
      makeCandidate()
    );
    expect(prompt.user).toContain('- "Exemplar 00" → Work');
    expect(prompt.user).toContain('- "Exemplar 01" → Finance Admin');
  });

  it("caps exemplars at 30, sampled evenly with first and last included", () => {
    const prompt = buildProposePrompt(
      makeWorld(),
      makeTrainingSet(40),
      makeCandidate()
    );
    const indices = [...prompt.user.matchAll(/- "Exemplar (\d+)" →/g)].map(
      (m) => Number(m[1])
    );
    expect(MAX_EXEMPLARS).toBe(30);
    expect(indices).toHaveLength(30);
    expect(indices[0]).toBe(0); // first included
    expect(indices[indices.length - 1]).toBe(39); // last included
    // Even spread: no two consecutive picks more than 2 apart (40 → 30).
    for (let i = 1; i < indices.length; i++) {
      const gap = indices[i]! - indices[i - 1]!;
      expect(gap).toBeGreaterThanOrEqual(1);
      expect(gap).toBeLessThanOrEqual(2);
    }
  });
});

// ===========================================================================
// Prompt id (cache-key separation from classifier prompts)
// ===========================================================================

describe("PROPOSE_GOLD_PROMPT_ID", () => {
  it("is propose-gold-v1 and distinct from every classifier prompt id", () => {
    expect(PROPOSE_GOLD_PROMPT_ID).toBe("propose-gold-v1");
    expect(PROPOSE_GOLD_PROMPT_ID).not.toBe("tiebreaker-v3");
    expect(PROPOSE_GOLD_PROMPT_ID).not.toBe("coldstart-v3");
    expect(PROPOSE_GOLD_PROMPT_ID).not.toBe("topic-ambiguity-v3");
  });

  it("produces cache hashes that cannot collide with classifier prompts", () => {
    const inputs: LLMInputs = {
      system: "s",
      user: "u",
      allowedPriorityIds: [P_WORK],
    };
    const model = "google:gemini-3-flash-preview";
    expect(hashInputs(model, PROPOSE_GOLD_PROMPT_ID, inputs)).not.toBe(
      hashInputs(model, "tiebreaker-v3", inputs)
    );
  });
});

// ===========================================================================
// applyProposals (raw YAML doc mutation)
// ===========================================================================

/** Raw cases.yaml document shape, as parseYaml would produce it. */
function rawDoc() {
  return {
    cases: [
      {
        id: "001-labeled",
        description: "already human-labeled",
        candidate: { title: "T1", embedding_ref: null },
        labels: {
          gold: "work",
          gold_rationale: "human rationale",
          expected: null,
        },
        notes: "",
      },
      {
        id: "002-unlabeled",
        description: "needs a label",
        candidate: { title: "T2", embedding_ref: null },
        labels: {
          gold: null,
          gold_rationale: "",
          expected: "work",
        },
        notes: "",
      },
      {
        id: "003-declined",
        candidate: { title: "T3", embedding_ref: null },
        labels: { gold: null, gold_rationale: "" },
        notes: "existing note",
      },
      {
        id: "004-unresolved",
        candidate: { title: "T4", embedding_ref: null },
        labels: { gold: null, gold_rationale: "" },
        notes: "",
      },
    ],
  };
}

const SLUG_BY_ID = new Map([
  [P_WORK, "work"],
  [P_FIN, "finance-admin"],
  [P_HOME, "home"],
]);

describe("applyProposals", () => {
  it("never touches a case whose gold is already set", () => {
    const doc = rawDoc();
    const before = structuredClone(doc.cases[0]);
    const result = applyProposals(
      doc,
      new Map<string, Proposal>([
        ["001-labeled", { priorityId: P_FIN, rationale: "overwrite attempt" }],
      ]),
      SLUG_BY_ID
    );
    expect(result.skippedLabeled).toBe(1);
    expect(result.updated).toBe(0);
    expect(doc.cases[0]).toEqual(before);
  });

  it("writes slug gold + [llm]-prefixed rationale + gold_source on unlabeled cases", () => {
    const doc = rawDoc();
    const result = applyProposals(
      doc,
      new Map<string, Proposal>([
        ["002-unlabeled", { priorityId: P_FIN, rationale: "matches invoices" }],
      ]),
      SLUG_BY_ID
    );
    expect(result.updated).toBe(1);
    const cs = doc.cases[1] as Record<string, unknown>;
    const labels = cs.labels as Record<string, unknown>;
    expect(labels.gold).toBe("finance-admin");
    expect(labels.gold_rationale).toBe("[llm] matches invoices");
    expect(labels.gold_source).toBe("llm-proposed");
    // Untouched sibling fields survive.
    expect(labels.expected).toBe("work");
  });

  it("leaves a null proposal unlabeled and appends a note", () => {
    const doc = rawDoc();
    const result = applyProposals(
      doc,
      new Map<string, Proposal>([
        ["003-declined", { priorityId: null, rationale: "no priority fits" }],
      ]),
      SLUG_BY_ID
    );
    expect(result.updated).toBe(0);
    const cs = doc.cases[2] as Record<string, unknown>;
    const labels = cs.labels as Record<string, unknown>;
    expect(labels.gold).toBeNull();
    expect(labels.gold_source).toBeUndefined();
    expect(cs.notes).toBe(
      "existing note\npropose-gold: LLM declined (no priority fits)"
    );
  });

  it("reports unresolved priority ids and leaves those cases untouched", () => {
    const doc = rawDoc();
    const before = structuredClone(doc.cases[3]);
    const unknown = "00000000-0000-4000-8000-00000000dead";
    const result = applyProposals(
      doc,
      new Map<string, Proposal>([
        ["004-unresolved", { priorityId: unknown, rationale: "ghost" }],
      ]),
      SLUG_BY_ID
    );
    expect(result.updated).toBe(0);
    expect(result.unresolved).toEqual(["004-unresolved"]);
    expect(doc.cases[3]).toEqual(before);
  });

  it("ignores cases without a proposal", () => {
    const doc = rawDoc();
    const before = structuredClone(doc);
    const result = applyProposals(doc, new Map(), SLUG_BY_ID);
    expect(result).toEqual({ updated: 0, skippedLabeled: 0, unresolved: [] });
    expect(doc).toEqual(before);
  });
});

// ===========================================================================
// proposeForCases (orchestration over a fake client)
// ===========================================================================

function fakeClient(
  respond: (inputs: LLMInputs) => { priorityId: string | null; rationale: string }
): LLMClient & { calls: LLMInputs[] } {
  const calls: LLMInputs[] = [];
  return {
    id: "fake:model",
    calls,
    async classify(inputs: LLMInputs) {
      calls.push(inputs);
      return respond(inputs);
    },
  };
}

describe("proposeForCases", () => {
  it("only consults the LLM for gold:null cases", async () => {
    const corpus = makeCorpus([
      makeCase("001-labeled", P_WORK),
      makeCase("002-unlabeled", null),
      makeCase("003-unlabeled", null),
    ]);
    const client = fakeClient(() => ({
      priorityId: P_FIN,
      rationale: "fits",
    }));
    const proposals = await proposeForCases(corpus, client);
    expect(client.calls).toHaveLength(2);
    expect([...proposals.keys()]).toEqual(["002-unlabeled", "003-unlabeled"]);
    expect(proposals.get("002-unlabeled")).toEqual({
      priorityId: P_FIN,
      rationale: "fits",
    });
  });

  it("treats out-of-set responses as declines with an out-of-set rationale", async () => {
    const corpus = makeCorpus([makeCase("001-unlabeled", null)]);
    const outOfSet = "00000000-0000-4000-8000-00000000beef";
    const client = fakeClient(() => ({
      priorityId: outOfSet,
      rationale: "hallucinated",
    }));
    const proposals = await proposeForCases(corpus, client);
    expect(proposals.get("001-unlabeled")).toEqual({
      priorityId: null,
      rationale: `out-of-set: ${outOfSet}`,
    });
  });
});
