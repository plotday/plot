import { describe, expect, it } from "vitest";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { loadCorpus } from "../src/corpus/load";
import {
  cosine,
  localRef,
  planFill,
  readTrainingDocs,
  runParityGate,
  PARITY_THRESHOLD,
} from "../src/seeder/gen-embeddings";

// ===========================================================================
// Pure-logic tests only — no model download, no @huggingface/transformers
// pipeline construction. The live embedder is exercised by the CLI smoke run.
// ===========================================================================

/** 384-dim zero vector as a YAML flow sequence (plan-level tests never dot it). */
const VEC = `[${new Array(384).fill(0).join(", ")}]`;

const USER_ID = "00000000-0000-4000-8000-000000000001";
const P_ROOT = "00000000-0000-4000-8000-000000000010";
const T_REFD = "00000000-0000-4000-8000-000000000100"; // has an embedding ref
const T_FILL = "00000000-0000-4000-8000-000000000101"; // null ref, titled
const T_EMPTY = "00000000-0000-4000-8000-000000000102"; // null ref, empty title
const SRC_THREAD = "00000000-0000-4000-8000-000000000999";

async function writeCorpus(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "eval-gen-embeddings-"));
  for (const [rel, content] of Object.entries(files)) {
    const path = join(dir, rel);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, content);
  }
  return dir;
}

function worldYaml(embeddings: string): string {
  return `
name: gen-emb-fixture
schema_version: 2
source: { kind: handcrafted }
user:
  id: "${USER_ID}"
  email: "u@e.test"
priorities:
  - { slug: root, id: "${P_ROOT}", path: root, title: Root }
contacts: []
groups: []
channels: []
embeddings:
${embeddings}
`;
}

const TRAININGS = `
name: full
threads:
  - id: "${T_REFD}"
    title: Refd training thread
    embedding_ref: emb-train1
    filed_to_priority: root
  - id: "${T_FILL}"
    title: Fillable training thread
    embedding_ref: null
    filed_to_priority: root
  - id: "${T_EMPTY}"
    title: ""
    embedding_ref: null
    filed_to_priority: root
`;

const CASES = `
cases:
  - id: 001-with-source
    source_thread_id: "${SRC_THREAD}"
    candidate:
      title: Case with source thread
      embedding_ref: null
    labels: { gold: root }
  - id: 002-no-source
    candidate:
      title: Case without source thread
      embedding_ref: null
    labels: { gold: root }
  - id: 003-already-refd
    candidate:
      title: Case already embedded
      embedding_ref: emb-case3
    labels: { gold: root }
`;

const EMBS_MIXED = `
  - { ref: emb-train1, source: thread-title, vector: ${VEC} }
  - { ref: emb-case3, source: thread-title, vector: ${VEC} }
`;

async function loadFixture(embeddings: string, opts?: {
  trainings?: string;
  cases?: string;
}) {
  const dir = await writeCorpus({
    "world.yaml": worldYaml(embeddings),
    "trainings/full.yaml": opts?.trainings ?? TRAININGS,
    "cases.yaml": opts?.cases ?? CASES,
  });
  const corpus = await loadCorpus(dir);
  const trainingFiles = await readTrainingDocs(dir);
  return { dir, corpus, trainingFiles };
}

// ===========================================================================
// cosine
// ===========================================================================

describe("cosine", () => {
  it("returns 1 for identical vectors", () => {
    const v = [0.3, -0.2, 0.5, 0.1];
    expect(cosine(v, v)).toBeCloseTo(1, 9);
  });

  it("returns 0 for orthogonal vectors", () => {
    expect(cosine([1, 0], [0, 1])).toBeCloseTo(0, 9);
  });

  it("throws on mismatched lengths", () => {
    expect(() => cosine([1, 2], [1, 2, 3])).toThrow(/length/i);
  });
});

// ===========================================================================
// localRef
// ===========================================================================

describe("localRef", () => {
  it("produces embl- prefixed 10-hex refs", () => {
    expect(localRef(T_FILL)).toMatch(/^embl-[0-9a-f]{10}$/);
  });

  it("is stable for the same input and distinct for different inputs", () => {
    expect(localRef(T_FILL)).toBe(localRef(T_FILL));
    expect(localRef(T_FILL)).not.toBe(localRef(SRC_THREAD));
  });

  it("does not collide with the prod emb- prefix check", () => {
    // Prod refs are `emb-<hash>`; local refs must NOT match startsWith("emb-").
    expect(localRef(T_FILL).startsWith("emb-")).toBe(false);
  });
});

// ===========================================================================
// planFill — fill planning
// ===========================================================================

describe("planFill fills", () => {
  it("lists exactly the null-embedding_ref entities with non-empty titles", async () => {
    const { corpus, trainingFiles } = await loadFixture(EMBS_MIXED);
    const plan = planFill(corpus, trainingFiles);

    const byId = new Map(plan.fills.map((f) => [f.id, f]));
    expect([...byId.keys()].sort()).toEqual(
      ["001-with-source", "002-no-source", T_FILL].sort()
    );

    // A case WITH a ref is not planned.
    expect(byId.has("003-already-refd")).toBe(false);
    // An empty-title training thread is not planned.
    expect(byId.has(T_EMPTY)).toBe(false);
    // A training thread with a ref is not planned.
    expect(byId.has(T_REFD)).toBe(false);
  });

  it("allocates refs per the hash-input rule", async () => {
    const { corpus, trainingFiles } = await loadFixture(EMBS_MIXED);
    const plan = planFill(corpus, trainingFiles);
    const byId = new Map(plan.fills.map((f) => [f.id, f]));

    // Case with source_thread_id hashes the source thread id.
    expect(byId.get("001-with-source")!.ref).toBe(localRef(SRC_THREAD));
    // Case without one hashes the case id.
    expect(byId.get("002-no-source")!.ref).toBe(localRef("002-no-source"));
    // Training thread hashes its own thread id.
    expect(byId.get(T_FILL)!.ref).toBe(localRef(T_FILL));
  });

  it("records kind, file, and title for each fill", async () => {
    const { corpus, trainingFiles } = await loadFixture(EMBS_MIXED);
    const plan = planFill(corpus, trainingFiles);
    const byId = new Map(plan.fills.map((f) => [f.id, f]));

    expect(byId.get("001-with-source")).toMatchObject({
      kind: "case",
      file: "cases.yaml",
      title: "Case with source thread",
    });
    expect(byId.get(T_FILL)).toMatchObject({
      kind: "training",
      file: "trainings/full.yaml",
      title: "Fillable training thread",
    });
  });
});

// ===========================================================================
// planFill — parity candidate selection
// ===========================================================================

describe("planFill parity candidates", () => {
  it("selects only source: thread-title vectors, recovering titles from cases AND trainings", async () => {
    const embeddings = `
  - { ref: emb-train1, source: thread-title, vector: ${VEC} }
  - { ref: emb-case3, source: thread-title, vector: ${VEC} }
  - { ref: emb-note, source: note-content, vector: ${VEC} }
  - { ref: emb-legacy, vector: ${VEC} }
  - { ref: embl-local1, source: local-title, vector: ${VEC} }
  - { ref: emb-orphan, source: thread-title, vector: ${VEC} }
`;
    const { corpus, trainingFiles } = await loadFixture(embeddings);
    const plan = planFill(corpus, trainingFiles);

    const refs = plan.parityCandidates.map((c) => c.ref).sort();
    // emb-train1: title recovered from a training thread; emb-case3: from a
    // case. note-content, legacy(null), local-title, and the orphan (no
    // owning entity) are all excluded.
    expect(refs).toEqual(["emb-case3", "emb-train1"]);

    const byRef = new Map(plan.parityCandidates.map((c) => [c.ref, c]));
    expect(byRef.get("emb-train1")!.title).toBe("Refd training thread");
    expect(byRef.get("emb-case3")!.title).toBe("Case already embedded");
    expect(byRef.get("emb-train1")!.vector).toHaveLength(384);
  });

  it("caps candidates at 5", async () => {
    const n = 7;
    const embLines = Array.from({ length: n }, (_, i) =>
      `  - { ref: emb-p${i}, source: thread-title, vector: ${VEC} }`
    ).join("\n");
    const threadLines = Array.from({ length: n }, (_, i) => {
      const id = `00000000-0000-4000-8000-0000000002${String(i).padStart(2, "0")}`;
      return [
        `  - id: "${id}"`,
        `    title: Parity thread ${i}`,
        `    embedding_ref: emb-p${i}`,
        `    filed_to_priority: root`,
      ].join("\n");
    }).join("\n");
    const { corpus, trainingFiles } = await loadFixture(embLines, {
      trainings: `name: full\nthreads:\n${threadLines}\n`,
      cases: "cases: []",
    });
    const plan = planFill(corpus, trainingFiles);
    expect(plan.parityCandidates).toHaveLength(5);
  });
});

// ===========================================================================
// planFill — no-mixing rule
// ===========================================================================

describe("planFill no-mixing rule", () => {
  it("blocks when emb- vectors exist but no parity candidate is checkable", async () => {
    // Prod vectors present, but none carry source: thread-title (legacy v1
    // style) → parity not checkable → conservative block.
    const embeddings = `
  - { ref: emb-train1, vector: ${VEC} }
  - { ref: emb-case3, source: note-content, vector: ${VEC} }
`;
    const { corpus, trainingFiles } = await loadFixture(embeddings);
    const plan = planFill(corpus, trainingFiles);
    expect(plan.hasProdVectors).toBe(true);
    expect(plan.parityCandidates).toHaveLength(0);
    expect(plan.blockedMixing).toBe(true);
  });

  it("does not block a uniformly-local corpus (parity skipped)", async () => {
    const embeddings = `
  - { ref: embl-aaaaaaaaaa, source: local-title, vector: ${VEC} }
`;
    const trainings = `
name: full
threads:
  - id: "${T_REFD}"
    title: Local thread
    embedding_ref: embl-aaaaaaaaaa
    filed_to_priority: root
`;
    const { corpus, trainingFiles } = await loadFixture(embeddings, {
      trainings,
      cases: "cases: []",
    });
    const plan = planFill(corpus, trainingFiles);
    expect(plan.hasProdVectors).toBe(false);
    expect(plan.blockedMixing).toBe(false);
    expect(plan.parityCandidates).toHaveLength(0);
  });

  it("does not block an empty-embeddings corpus", async () => {
    const trainings = `
name: full
threads:
  - id: "${T_FILL}"
    title: Fillable training thread
    embedding_ref: null
    filed_to_priority: root
`;
    const { corpus, trainingFiles } = await loadFixture("  []", {
      trainings,
      cases: "cases: []",
    });
    const plan = planFill(corpus, trainingFiles);
    expect(plan.hasProdVectors).toBe(false);
    expect(plan.blockedMixing).toBe(false);
  });

  it("does not block when a checkable parity candidate exists", async () => {
    const { corpus, trainingFiles } = await loadFixture(EMBS_MIXED);
    const plan = planFill(corpus, trainingFiles);
    expect(plan.hasProdVectors).toBe(true);
    expect(plan.parityCandidates.length).toBeGreaterThan(0);
    expect(plan.blockedMixing).toBe(false);
  });
});

// ===========================================================================
// runParityGate — injectable embedder, no model download
// ===========================================================================

/** Builds a unit vector in 384 dimensions with component 0 set to 1. */
function unitVec(dim = 384): number[] {
  const v = new Array<number>(dim).fill(0);
  v[0] = 1;
  return v;
}

/**
 * Returns a slightly rotated vector so that cosine(v, unitVec()) < 1.
 * The rotation is just enough to put the cosine below PARITY_THRESHOLD.
 */
function rotatedVec(dim = 384): number[] {
  const v = new Array<number>(dim).fill(0);
  // cos(theta) = a / sqrt(a^2 + b^2). With a=0.99 and b=sqrt(1-0.99^2) ≈ 0.141
  // cos ≈ 0.99, which is exactly at the threshold and might round either way.
  // Use b large enough to clearly sit below 0.99.
  v[0] = 0.98;
  v[1] = Math.sqrt(1 - 0.98 * 0.98); // ~0.199 → cosine ≈ 0.98 < 0.99
  return v;
}

describe("runParityGate", () => {
  it("(a) all-pass: fake embedder returns the stored vector → cosines 1.0 → status pass", async () => {
    const { corpus, trainingFiles } = await loadFixture(EMBS_MIXED);
    const plan = planFill(corpus, trainingFiles);

    // Override the stored vectors to match what our fake embedder will return.
    const storedVec = unitVec();
    for (const c of plan.parityCandidates) {
      c.vector = storedVec;
    }
    const fakeEmbed = async (_text: string): Promise<number[]> => storedVec;

    const outcome = await runParityGate(plan, fakeEmbed);
    expect(outcome.status).toBe("pass");
    expect(outcome.results.length).toBeGreaterThan(0);
    for (const r of outcome.results) {
      expect(r.cosine).toBeCloseTo(1.0, 9);
    }
  });

  it("(b) one-below-threshold: rotated vector for one candidate → status fail; per-candidate cosines reported", async () => {
    const { corpus, trainingFiles } = await loadFixture(EMBS_MIXED);
    const plan = planFill(corpus, trainingFiles);

    // Store unit vectors for all candidates.
    for (const c of plan.parityCandidates) {
      c.vector = unitVec();
    }

    let callCount = 0;
    const fakeEmbed = async (_text: string): Promise<number[]> => {
      callCount++;
      // Return a rotated vector only for the first call.
      return callCount === 1 ? rotatedVec() : unitVec();
    };

    const outcome = await runParityGate(plan, fakeEmbed);
    expect(outcome.status).toBe("fail");
    expect(outcome.results.length).toBe(plan.parityCandidates.length);
    // First result's cosine should be below threshold.
    expect(outcome.results[0]!.cosine).toBeLessThan(PARITY_THRESHOLD);
    // Subsequent results (if any) should be near 1.
    for (const r of outcome.results.slice(1)) {
      expect(r.cosine).toBeCloseTo(1.0, 9);
    }
  });

  it("(c) zero candidates with prod vectors → not-checkable", async () => {
    // Prod vectors exist but none are source: thread-title with a recoverable
    // title, so planFill will produce zero parityCandidates.
    const embeddings = `
  - { ref: emb-train1, source: note-content, vector: ${VEC} }
  - { ref: emb-case3, source: note-content, vector: ${VEC} }
`;
    const { corpus, trainingFiles } = await loadFixture(embeddings);
    const plan = planFill(corpus, trainingFiles);

    expect(plan.hasProdVectors).toBe(true);
    expect(plan.parityCandidates).toHaveLength(0);

    const fakeEmbed = async (_text: string): Promise<number[]> => unitVec();
    const outcome = await runParityGate(plan, fakeEmbed);
    expect(outcome.status).toBe("not-checkable");
    expect(outcome.results).toHaveLength(0);
  });

  it("(d) no prod vectors → skipped", async () => {
    // Corpus has no emb- vectors at all — uniformly local or empty.
    const { corpus, trainingFiles } = await loadFixture("  []", {
      trainings: `name: full\nthreads:\n  - id: "${T_FILL}"\n    title: Local only\n    embedding_ref: null\n    filed_to_priority: root\n`,
      cases: "cases: []",
    });
    const plan = planFill(corpus, trainingFiles);

    expect(plan.hasProdVectors).toBe(false);

    const fakeEmbed = async (_text: string): Promise<number[]> => unitVec();
    const outcome = await runParityGate(plan, fakeEmbed);
    expect(outcome.status).toBe("skipped");
    expect(outcome.results).toHaveLength(0);
  });
});
