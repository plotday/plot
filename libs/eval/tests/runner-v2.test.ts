import { describe, expect, it } from "vitest";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import type { Candidate, ClassificationResult } from "@plotday/classifier";
import { registerVariant } from "../src/classifiers/registry";
import { runEval } from "../src/runner/run";
import { rankOfGold } from "../src/scoring/rank";

const USER_ID = "f0000000-0000-4000-8000-000000000001";
const P_ROOT = "f0000000-0000-4000-8000-000000000010";
const P_TARGET = "f0000000-0000-4000-8000-000000000011";
const P_OTHER = "f0000000-0000-4000-8000-000000000012";
const ANNA = "f0000000-0000-4000-8000-000000000020";
const CONN = "f0000000-0000-4000-8000-000000000030";
// Distinct 8-hex prefixes: the case-id fallback matches via startsWith.
const T_A = "aaaa1111-0000-4000-8000-000000000100";
const T_B = "bbbb2222-0000-4000-8000-000000000101";

// 384-dim embedding shared by training thread T_A and the self-match cases —
// identical vectors make T_A a sem=1.0 neighbor unless the guard archives it.
const EMB = `[1${", 0".repeat(383)}]`;

const WORLD = `
name: runner-v2-fixture
schema_version: 2
source: { kind: handcrafted }
user:
  id: "${USER_ID}"
  email: "runner-v2-user@example.test"
connections:
  - { slug: gmail-org, id: "${CONN}", provider: google, account_contact: anna, team: null }
priorities:
  - { slug: root, id: "${P_ROOT}", path: evalrunner, title: Everything }
  - { slug: target, id: "${P_TARGET}", path: evalrunner.target, title: Vendors }
  - { slug: other, id: "${P_OTHER}", path: evalrunner.other, title: Hobby }
contacts:
  - { slug: anna, id: "${ANNA}", email: "anna@lumenforge.com", name: Anna, linked_to_user: true }
embeddings:
  - { ref: emb-same, vector: ${EMB} }
`;

// "solo": exactly one training thread, the self-match target — after the
// guard archives it the scoring stage has zero neighbors.
const TRAININGS_SOLO = `
name: solo
threads:
  - id: "${T_A}"
    title: Invoice from vendor
    contacts: [anna]
    filed_to_priority: target
    embedding_ref: emb-same
`;

// "pair": two training threads with distinct id prefixes for the
// trainingSizeAtCase N vs N-1 assertion.
const TRAININGS_PAIR = `
name: pair
threads:
  - id: "${T_A}"
    title: Invoice from vendor
    contacts: [anna]
    filed_to_priority: target
    embedding_ref: emb-same
  - id: "${T_B}"
    title: Weekly metrics digest
    contacts: [anna]
    filed_to_priority: other
`;

const CASES = `
cases:
  - id: "501-ffffffff"
    source_thread_id: "${T_A}"
    candidate:
      title: Quarterly invoice arrived
      contacts: [anna]
      embedding_ref: emb-same
    labels: { gold: target }
  - id: "502-eeeeeeee"
    candidate:
      title: Quarterly invoice arrived
      contacts: [anna]
      embedding_ref: emb-same
    labels: { gold: target }
  - id: "001-aaaa1111"
    candidate: { title: Prefix matched case }
    labels: {}
  - id: "002-dddd4444"
    candidate: { title: Prefix unmatched case }
    labels: {}
  - id: "601-cccccccc"
    candidate:
      title: Wiring probe
      author: anna
      connection: gmail-org
      facets: { format: message }
    labels: {}
  - id: "602-cccccccc"
    candidate: { title: Wiring probe without connection }
    labels: {}
  - id: "701-eeeeeeee"
    tags: [holdout-move]
    candidate: { title: Holdout case }
    labels: {}
  - id: "702-eeeeeeee"
    tags: [noisy]
    candidate: { title: Noisy-tagged case }
    labels: {}
  - id: "801-eeeeeeee"
    candidate: { title: Rank probe }
    labels: { gold: target }
`;

const WORLD_V1 = `
name: runner-v1-fixture
schema_version: 1
user:
  id: "${USER_ID}"
  email: "runner-v1-user@example.test"
priorities:
  - { slug: root, id: "${P_ROOT}", path: evalrunner, title: Everything }
`;

const CASES_V1 = `
cases:
  - id: "901-eeeeeeee"
    candidate: { title: Null author case }
    labels: {}
  - id: "902-eeeeeeee"
    candidate: { title: Override author case, author: "${ANNA}" }
    labels: {}
`;

async function writeCorpus(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "eval-runner-v2-"));
  for (const [rel, content] of Object.entries(files)) {
    const path = join(dir, rel);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, content);
  }
  return dir;
}

function v2Files(): Record<string, string> {
  return {
    "world.yaml": WORLD,
    "trainings/solo.yaml": TRAININGS_SOLO,
    "trainings/pair.yaml": TRAININGS_PAIR,
    "cases.yaml": CASES,
  };
}

function fakeResult(
  partial: Partial<ClassificationResult>
): ClassificationResult {
  return {
    priorityId: null,
    stage: "none",
    scores: {},
    durationMs: 0,
    llmCalls: 0,
    cacheHits: 0,
    budgetExhausted: false,
    ...partial,
  };
}

/** Registers a one-off capturing classifier and returns its capture list. */
function registerCapture(
  name: string,
  result: Partial<ClassificationResult> = {}
): Candidate[] {
  const captured: Candidate[] = [];
  registerVariant(name, {
    name,
    async classify(_ctx, candidate) {
      captured.push(candidate);
      return fakeResult(result);
    },
  });
  return captured;
}

describe.runIf(!!process.env.DATABASE_URL)("runner v2", () => {
  it("self-excludes via source_thread_id: the training copy never serves as a neighbor", async () => {
    const dir = await writeCorpus(v2Files());
    const { results } = await runEval({
      corpusDir: dir,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["solo"],
      caseFilter: (id) => id === "501-ffffffff" || id === "502-eeeeeeee",
    });
    const byCase = new Map(results.map((r) => [r.caseId, r]));

    // Control: WITHOUT the self-match the identical-embedding neighbor wins
    // at the scoring stage — proving the leak the guard must prevent.
    const control = byCase.get("502-eeeeeeee")!;
    expect(control.selfExcluded).toBe(false);
    expect(control.stage).toBe("scoring");
    expect(control.predicted).toBe(P_TARGET);
    expect(control.trainingSizeAtCase).toBe(1);

    // Guarded: the only training thread is the case's own source thread, so
    // it is archived; scoring has zero neighbors and falls through.
    const guarded = byCase.get("501-ffffffff")!;
    expect(guarded.selfExcluded).toBe(true);
    expect(guarded.trainingSizeAtCase).toBe(0);
    expect(guarded.stage).not.toBe("scoring");
    expect(guarded.predicted).not.toBe(P_TARGET);
  }, 60_000);

  it("self-excludes via the case-id 8-hex prefix; trainingSizeAtCase reflects it", async () => {
    const dir = await writeCorpus(v2Files());
    const { results } = await runEval({
      corpusDir: dir,
      classifiers: ["ts:hybrid:default"],
      trainingSets: ["pair"],
      caseFilter: (id) => id === "001-aaaa1111" || id === "002-dddd4444",
    });
    const byCase = new Map(results.map((r) => [r.caseId, r]));

    const matched = byCase.get("001-aaaa1111")!;
    expect(matched.selfExcluded).toBe(true);
    expect(matched.trainingSizeAtCase).toBe(1); // N-1

    const unmatched = byCase.get("002-dddd4444")!;
    expect(unmatched.selfExcluded).toBe(false);
    expect(unmatched.trainingSizeAtCase).toBe(2); // N
  }, 60_000);

  it("wires facets/authorContactId/connectionId into classify(); v2 author falls back to the connection", async () => {
    const name = "test:capture-candidate";
    const captured = registerCapture(name, {
      budgetExhausted: true,
      llmUsage: {
        liveInputTokens: 7,
        liveOutputTokens: 3,
        replayedInputTokens: 0,
        replayedOutputTokens: 0,
        unknownCalls: 0,
      },
    });
    const dir = await writeCorpus(v2Files());
    const { results } = await runEval({
      corpusDir: dir,
      classifiers: [name],
      trainingSets: ["solo"],
      caseFilter: (id) => id === "601-cccccccc" || id === "602-cccccccc",
    });

    expect(captured).toHaveLength(2);
    const withConn = captured.find((c) => c.title === "Wiring probe")!;
    expect(withConn.facets).toEqual({ format: "message" });
    expect(withConn.authorContactId).toBe(ANNA);
    expect(withConn.connectionId).toBe(CONN);
    // No created_by_override: v2 author falls back to the connection id.
    expect(withConn.author).toBe(CONN);

    // No connection either: falls all the way back to the world user.
    const withoutConn = captured.find(
      (c) => c.title === "Wiring probe without connection"
    )!;
    expect(withoutConn.author).toBe(USER_ID);
    expect(withoutConn.connectionId).toBeNull();
    expect(withoutConn.authorContactId).toBeNull();
    expect(withoutConn.facets).toBeNull();

    // budgetExhausted / llmUsage flow from ClassificationResult to RunResult.
    for (const r of results) {
      expect(r.budgetExhausted).toBe(true);
      expect(r.llmUsage).toEqual({
        liveInputTokens: 7,
        liveOutputTokens: 3,
        replayedInputTokens: 0,
        replayedOutputTokens: 0,
        unknownCalls: 0,
      });
    }
  }, 60_000);

  it("keeps v1 author semantics: null stays null, override passes through", async () => {
    const name = "test:capture-v1-author";
    const captured = registerCapture(name);
    const dir = await writeCorpus({
      "world.yaml": WORLD_V1,
      "trainings/full.yaml": "threads: []\n",
      "cases.yaml": CASES_V1,
    });
    await runEval({
      corpusDir: dir,
      classifiers: [name],
      trainingSets: ["full"],
    });

    expect(captured).toHaveLength(2);
    const nullAuthor = captured.find((c) => c.title === "Null author case")!;
    // v1 EXACTNESS: the author signal historically saw null here even though
    // the staged DB row defaults created_by to the user id. Never "fix" this.
    expect(nullAuthor.author).toBeNull();
    const overrideAuthor = captured.find(
      (c) => c.title === "Override author case"
    )!;
    expect(overrideAuthor.author).toBe(ANNA);
  }, 60_000);

  it("excludes holdout-move by default; excludeTags appends; [] includes all", async () => {
    const name = "test:capture-tags";
    registerCapture(name);
    const dir = await writeCorpus(v2Files());
    const tagCases = (id: string) =>
      id === "701-eeeeeeee" || id === "702-eeeeeeee";

    const defaults = await runEval({
      corpusDir: dir,
      classifiers: [name],
      trainingSets: ["solo"],
      caseFilter: tagCases,
    });
    expect(defaults.results.map((r) => r.caseId)).toEqual(["702-eeeeeeee"]);

    const appended = await runEval({
      corpusDir: dir,
      classifiers: [name],
      trainingSets: ["solo"],
      caseFilter: tagCases,
      excludeTags: ["holdout-move", "noisy"],
    });
    expect(appended.results).toHaveLength(0);

    const includeAll = await runEval({
      corpusDir: dir,
      classifiers: [name],
      trainingSets: ["solo"],
      caseFilter: tagCases,
      excludeTags: [],
    });
    expect(includeAll.results.map((r) => r.caseId).sort()).toEqual([
      "701-eeeeeeee",
      "702-eeeeeeee",
    ]);
  }, 60_000);

  it("fills rankOfGold/goldMargin from the scoring explain; sql-current-like scores give null", async () => {
    // Real explain shape from ts-hybrid-scoring.ts (ScoringExplain), spread
    // directly into scores by the "scoring" stage in ts-hybrid(-llm).ts.
    const explainName = "test:rank-explain";
    registerVariant(explainName, {
      name: explainName,
      async classify() {
        return fakeResult({
          priorityId: P_OTHER,
          stage: "scoring",
          scores: {
            perPrioritySorted: [
              {
                priorityId: P_OTHER,
                score: 0.5,
                neighborCount: 2,
                neighborScore: 0.5,
                titleMatch: 0,
                accountHierarchyAffinity: 0,
              },
              {
                priorityId: P_TARGET,
                score: 0.25,
                neighborCount: 1,
                neighborScore: 0.25,
                titleMatch: 0,
                accountHierarchyAffinity: 0,
              },
            ],
            topNeighbors: [],
          },
        });
      },
    });
    const sqlName = "test:rank-sql-shape";
    registerVariant(sqlName, {
      name: sqlName,
      async classify() {
        return fakeResult({
          priorityId: P_TARGET,
          stage: "scoring",
          scores: { top: [{ priority_id: P_TARGET, score: 0.9 }] },
        });
      },
    });

    const dir = await writeCorpus(v2Files());
    const { results } = await runEval({
      corpusDir: dir,
      classifiers: [explainName, sqlName],
      trainingSets: ["solo"],
      caseFilter: (id) => id === "801-eeeeeeee", // gold: target
    });

    const explained = results.find((r) => r.classifier === explainName)!;
    expect(explained.rankOfGold).toBe(2);
    expect(explained.goldMargin).toBeCloseTo(0.25, 10);

    const sqlShaped = results.find((r) => r.classifier === sqlName)!;
    expect(sqlShaped.rankOfGold).toBeNull();
    expect(sqlShaped.goldMargin).toBeNull();
  }, 60_000);
});

describe("rankOfGold", () => {
  const ranking = (entries: [string, number][]) =>
    entries.map(([priorityId, score]) => ({
      priorityId,
      score,
      neighborCount: 1,
      neighborScore: score,
      titleMatch: 0,
      accountHierarchyAffinity: 0,
    }));

  it("ranks gold at the top with margin 0", () => {
    const scores = { perPrioritySorted: ranking([["G", 0.4], ["B", 0.1]]) };
    expect(rankOfGold(scores, "G")).toEqual({ rank: 1, margin: 0 });
  });

  it("reads the llm_tiebreaker nested shape (scores.scoring.perPrioritySorted)", () => {
    const scores = {
      rationale: "because",
      scoring: { perPrioritySorted: ranking([["A", 0.5], ["G", 0.2]]) },
    };
    const out = rankOfGold(scores, "G");
    expect(out?.rank).toBe(2);
    expect(out?.margin).toBeCloseTo(0.3, 10);
  });

  it("returns null when gold is absent from the ranking", () => {
    const scores = { perPrioritySorted: ranking([["A", 0.5]]) };
    expect(rankOfGold(scores, "G")).toBeNull();
  });

  it("returns null without a gold label, for empty scores, and for foreign shapes", () => {
    const scores = { perPrioritySorted: ranking([["G", 0.5]]) };
    expect(rankOfGold(scores, null)).toBeNull();
    expect(rankOfGold({}, "G")).toBeNull();
    expect(rankOfGold({ top: [{ priority_id: "G", score: 1 }] }, "G")).toBeNull();
    expect(rankOfGold({ perPrioritySorted: "bogus" }, "G")).toBeNull();
    expect(rankOfGold({ perPrioritySorted: [{ nope: 1 }] }, "G")).toBeNull();
  });
});
