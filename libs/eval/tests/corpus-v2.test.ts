import { describe, expect, it } from "vitest";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { loadCorpus } from "../src/corpus/load";

/** 384-dim zero vector as a YAML flow sequence. */
const VEC = `[${new Array(384).fill(0).join(", ")}]`;

const USER_ID = "00000000-0000-4000-8000-000000000001";
const P_ROOT = "00000000-0000-4000-8000-000000000010";
const P_ENG = "00000000-0000-4000-8000-000000000011";
const ALICE = "00000000-0000-4000-8000-000000000020";
const CONN_GMAIL = "00000000-0000-4000-8000-000000000030";
const CONN_SLACK = "00000000-0000-4000-8000-000000000031";
const T1 = "00000000-0000-4000-8000-000000000100";
const NEG1 = "00000000-0000-4000-8000-000000000200";
const SRC_THREAD = "00000000-0000-4000-8000-000000000999";

async function writeCorpus(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "eval-corpus-v2-"));
  for (const [rel, content] of Object.entries(files)) {
    const path = join(dir, rel);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, content);
  }
  return dir;
}

const WORLD_V2 = `
name: v2-fixture
schema_version: 2
source: { kind: handcrafted }
user:
  id: "${USER_ID}"
  email: "u@e.test"
  subscription: { plan: pro, status: active }
teams:
  - { slug: acme, id: 7, name: Acme }
connections:
  - { slug: gmail-work, id: "${CONN_GMAIL}", provider: google, account_contact: alice, team: acme }
  - { slug: slack-acme, id: "${CONN_SLACK}", provider: slack, account_contact: "${ALICE}", team: null }
priorities:
  - slug: root
    id: "${P_ROOT}"
    path: root
    title: Root
    description: Top of the tree
    facet_filters:
      automation: { exclude: [automated] }
      trustedSendersOnly: true
  - { slug: eng, id: "${P_ENG}", path: root.eng, title: Engineering }
contacts:
  - { slug: alice, id: "${ALICE}", email: "a@e.test", name: Alice }
channels:
  - { id: 164, connection: gmail-work, default_priority_id: null }
embeddings:
  - { ref: emb-src, source: thread-title, vector: ${VEC} }
  - { ref: emb-legacy, vector: ${VEC} }
`;

const TRAININGS_V2 = `
name: full
threads:
  - id: "${T1}"
    title: t1
    topic: "channel:164"
    contacts: [alice]
    embedding_ref: emb-src
    filed_to_priority: root
    author: alice
    connection: gmail-work
    facets: { format: message, automation: automated }
    created_at: "2026-04-02T10:00:00Z"
    moved_at: "2026-04-03T09:30:00Z"
negative_threads:
  - id: "${NEG1}"
    title: neg1
    contacts: [alice]
    author: alice
    connection: slack-acme
    created_at: "2026-04-01T00:00:00Z"
negatives:
  - { thread: "${NEG1}", priority: eng, source: moved_out, created_at: "2026-04-05T08:00:00Z" }
  - { thread: "${T1}", priority: root, source: deselected }
`;

const CASES_V2 = `
cases:
  - id: "001"
    source_thread_id: "${SRC_THREAD}"
    tags: [channel, facet-gate]
    as_of: "2026-05-01T12:00:00Z"
    candidate:
      title: x
      author: alice
      connection: slack-acme
      facets: { format: message }
      created_by_override: "twist:gmail"
      embedding_ref: emb-legacy
    labels:
      gold: root
      gold_source: llm-proposed
      expected: eng
      expected_stage: llm_tiebreaker
  - id: "002"
    candidate: { title: y }
    labels: { gold: root }
  - id: "003"
    candidate: { title: z }
    labels: {}
`;

function v2Files(): Record<string, string> {
  return {
    "world.yaml": WORLD_V2,
    "trainings/full.yaml": TRAININGS_V2,
    "cases.yaml": CASES_V2,
  };
}

describe("corpus schema v2: world", () => {
  it("parses teams, connections, subscription, descriptions, facet_filters, channels", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    const { world } = corpus;

    expect(world.schemaVersion).toBe(2);
    expect(world.user.subscription).toEqual({ plan: "pro", status: "active" });
    expect(world.teams).toEqual([{ slug: "acme", id: 7, name: "Acme" }]);

    expect(world.connections).toHaveLength(2);
    const gmail = world.connections.find((c) => c.slug === "gmail-work")!;
    expect(gmail.id).toBe(CONN_GMAIL);
    expect(gmail.provider).toBe("google");
    expect(gmail.accountContactId).toBe(ALICE);
    expect(gmail.teamId).toBe(7);
    const slack = world.connections.find((c) => c.slug === "slack-acme")!;
    expect(slack.accountContactId).toBe(ALICE);
    expect(slack.teamId).toBeNull();

    const root = world.priorities.find((p) => p.slug === "root")!;
    expect(root.description).toBe("Top of the tree");
    expect(root.facetFilters).toEqual({
      automation: { exclude: ["automated"] },
      trustedSendersOnly: true,
    });
    const eng = world.priorities.find((p) => p.slug === "eng")!;
    expect(eng.description).toBeNull();
    expect(eng.facetFilters).toBeNull();

    expect(world.channels).toEqual([
      { id: 164, connectionId: CONN_GMAIL, default_priority_id: null },
    ]);
  });

  it("treats absent subscription as null", async () => {
    const files = v2Files();
    files["world.yaml"] = WORLD_V2.replace(
      /^ {2}subscription:.*\n/m,
      ""
    );
    const dir = await writeCorpus(files);
    const corpus = await loadCorpus(dir);
    expect(corpus.world.user.subscription).toBeNull();
  });

  it("rejects unknown connection refs on channels", async () => {
    const files = v2Files();
    files["world.yaml"] = WORLD_V2.replace(
      "connection: gmail-work, default_priority_id: null",
      "connection: nope, default_priority_id: null"
    );
    const dir = await writeCorpus(files);
    await expect(loadCorpus(dir)).rejects.toThrow(/connection/i);
  });

  it("keeps optional embedding source (legacy entries → null)", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    expect(corpus.embeddings.get("emb-src")!.source).toBe("thread-title");
    expect(corpus.embeddings.get("emb-legacy")!.source).toBeNull();
  });
});

describe("corpus schema v2: trainings", () => {
  it("parses author/connection/facets/timestamps into the internal model", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    const ts = corpus.trainingSets.find((t) => t.name === "full")!;
    const t = ts.threads[0]!;

    expect(t.authorContactId).toBe(ALICE);
    expect(t.connectionId).toBe(CONN_GMAIL);
    expect(t.createdByOverride).toBeNull();
    expect(t.facets).toEqual({ format: "message", automation: "automated" });
    expect(t.createdAt).toBeInstanceOf(Date);
    expect(t.createdAt!.toISOString()).toBe("2026-04-02T10:00:00.000Z");
    expect(t.movedAt).toBeInstanceOf(Date);
    expect(t.movedAt!.toISOString()).toBe("2026-04-03T09:30:00.000Z");
    expect(t.filedToPriority).toBe(P_ROOT);
    expect(t.contacts).toEqual([ALICE]);
  });

  it("parses negative_threads and negatives (with and without created_at)", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    const ts = corpus.trainingSets.find((t) => t.name === "full")!;

    expect(ts.negativeThreads).toHaveLength(1);
    const neg = ts.negativeThreads[0]!;
    expect(neg.id).toBe(NEG1);
    expect(neg.authorContactId).toBe(ALICE);
    expect(neg.connectionId).toBe(CONN_SLACK);
    expect(neg.createdAt!.toISOString()).toBe("2026-04-01T00:00:00.000Z");

    expect(ts.negatives).toHaveLength(2);
    expect(ts.negatives[0]).toEqual({
      threadId: NEG1,
      priorityId: P_ENG,
      source: "moved_out",
      createdAt: new Date("2026-04-05T08:00:00Z"),
    });
    expect(ts.negatives[1]!.threadId).toBe(T1);
    expect(ts.negatives[1]!.source).toBe("deselected");
    expect(ts.negatives[1]!.createdAt).toBeNull();
  });

  it("throws when a negative references an unknown thread id", async () => {
    const files = v2Files();
    files["trainings/full.yaml"] = TRAININGS_V2.replace(
      `thread: "${NEG1}"`,
      `thread: "00000000-0000-4000-8000-00000000dead"`
    );
    const dir = await writeCorpus(files);
    await expect(loadCorpus(dir)).rejects.toThrow(
      /negatives.*00000000-0000-4000-8000-00000000dead/s
    );
  });

  it("throws on invalid timestamp strings with context", async () => {
    const files = v2Files();
    files["trainings/full.yaml"] = TRAININGS_V2.replace(
      `created_at: "2026-04-02T10:00:00Z"`,
      `created_at: "not-a-date"`
    );
    const dir = await writeCorpus(files);
    await expect(loadCorpus(dir)).rejects.toThrow(/not-a-date/);
  });
});

describe("corpus schema v2: cases", () => {
  it("parses source_thread_id, tags, as_of, candidate connection/facets/override", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    const cs = corpus.cases.find((c) => c.id === "001")!;

    expect(cs.sourceThreadId).toBe(SRC_THREAD);
    expect(cs.tags).toEqual(["channel", "facet-gate"]);
    expect(cs.asOf).toBeInstanceOf(Date);
    expect(cs.asOf!.toISOString()).toBe("2026-05-01T12:00:00.000Z");

    expect(cs.candidate.authorContactId).toBe(ALICE);
    expect(cs.candidate.connectionId).toBe(CONN_SLACK);
    expect(cs.candidate.facets).toEqual({ format: "message" });
    // twist:* overrides hash to a deterministic synthetic uuid.
    expect(cs.candidate.createdByOverride).toMatch(/^[0-9a-f]{8}-/);
    expect(cs.candidate.embedding_ref).toBe("emb-legacy");
  });

  it("accepts free-form expected_stage values like llm_tiebreaker", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    expect(corpus.cases.find((c) => c.id === "001")!.labels.expectedStage).toBe(
      "llm_tiebreaker"
    );
  });

  it("applies gold_source defaults: explicit wins, absent backfills from gold", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    expect(corpus.cases.find((c) => c.id === "001")!.labels.goldSource).toBe(
      "llm-proposed"
    );
    // gold set, gold_source absent → human
    expect(corpus.cases.find((c) => c.id === "002")!.labels.goldSource).toBe(
      "human"
    );
    // no gold → null
    const c3 = corpus.cases.find((c) => c.id === "003")!;
    expect(c3.labels.gold).toBeNull();
    expect(c3.labels.goldSource).toBeNull();
    // inert defaults
    expect(c3.sourceThreadId).toBeNull();
    expect(c3.tags).toEqual([]);
    expect(c3.asOf).toBeNull();
  });
});

describe("corpus schema v2: embeddings.yaml sibling", () => {
  it("merges sibling embeddings with world embeddings", async () => {
    const files = v2Files();
    files["embeddings.yaml"] = `
embeddings:
  - { ref: emb-sib, vector: ${VEC} }
  - { ref: emb-sib-src, source: note-content, vector: ${VEC} }
`;
    const dir = await writeCorpus(files);
    const corpus = await loadCorpus(dir);
    expect(corpus.embeddings.has("emb-src")).toBe(true);
    expect(corpus.embeddings.get("emb-sib")!.source).toBeNull();
    expect(corpus.embeddings.get("emb-sib-src")!.source).toBe("note-content");
    expect(corpus.world.embeddings).toHaveLength(4);
  });

  it("throws on duplicate refs across world.yaml and embeddings.yaml", async () => {
    const files = v2Files();
    files["embeddings.yaml"] = `
embeddings:
  - { ref: emb-src, vector: ${VEC} }
`;
    const dir = await writeCorpus(files);
    await expect(loadCorpus(dir)).rejects.toThrow(/emb-src/);
  });
});

describe("corpus schema v1 normalization", () => {
  const WORLD_V1 = `
name: v1-fixture
schema_version: 1
user: { id: "${USER_ID}", email: "u@e.test" }
priorities:
  - { slug: root, id: "${P_ROOT}", path: root, title: Root }
contacts:
  - { slug: alice, id: "${ALICE}", email: "a@e.test", name: Alice }
embeddings:
  - { ref: emb-old, vector: ${VEC} }
`;

  // Arbitrary UUID not declared anywhere in world.yaml — v1 author semantics
  // pass it through without a membership check (kris corpus relies on this).
  const FOREIGN_UUID = "11111111-1111-4111-8111-111111111111";

  const TRAININGS_V1 = `
threads:
  - id: "${T1}"
    title: t1
    filed_to_priority: root
    author: alice
  - id: "00000000-0000-4000-8000-000000000101"
    title: t2
    filed_to_priority: root
    author: "twist:gmail"
  - id: "00000000-0000-4000-8000-000000000102"
    title: t3
    filed_to_priority: root
    author: "${FOREIGN_UUID}"
  - id: "00000000-0000-4000-8000-000000000103"
    title: t4
    filed_to_priority: root
`;

  const CASES_V1 = `
cases:
  - id: "001"
    candidate: { title: x, author: alice, embedding_ref: emb-old }
    labels: { gold: root, expected_stage: scoring }
  - id: "002"
    candidate: { title: y }
    labels: {}
`;

  async function loadV1() {
    const dir = await writeCorpus({
      "world.yaml": WORLD_V1,
      "trainings/full.yaml": TRAININGS_V1,
      "cases.yaml": CASES_V1,
    });
    return loadCorpus(dir);
  }

  it("carries v1 author into createdByOverride with exact v1 semantics", async () => {
    const corpus = await loadV1();
    const threads = corpus.trainingSets[0]!.threads;

    // Contact slug → contact uuid.
    expect(threads[0]!.createdByOverride).toBe(ALICE);
    // twist:* → deterministic synthetic uuid (not the contact's).
    expect(threads[1]!.createdByOverride).toMatch(/^[0-9a-f]{8}-/);
    expect(threads[1]!.createdByOverride).not.toBe(ALICE);
    // Arbitrary uuid passes through WITHOUT world-membership check.
    expect(threads[2]!.createdByOverride).toBe(FOREIGN_UUID);
    // Absent author → null.
    expect(threads[3]!.createdByOverride).toBeNull();

    // v1 never sets the v2-only fields.
    for (const t of threads) {
      expect(t.authorContactId).toBeNull();
      expect(t.connectionId).toBeNull();
      expect(t.facets).toBeNull();
      expect(t.createdAt).toBeNull();
      expect(t.movedAt).toBeNull();
    }
  });

  it("normalizes v1 cases: candidate override, goldSource backfill, inert defaults", async () => {
    const corpus = await loadV1();
    const c1 = corpus.cases.find((c) => c.id === "001")!;
    expect(c1.candidate.createdByOverride).toBe(ALICE);
    expect(c1.candidate.authorContactId).toBeNull();
    expect(c1.candidate.connectionId).toBeNull();
    expect(c1.candidate.facets).toBeNull();
    expect(c1.labels.goldSource).toBe("human");
    expect(c1.labels.expectedStage).toBe("scoring");
    expect(c1.sourceThreadId).toBeNull();
    expect(c1.tags).toEqual([]);
    expect(c1.asOf).toBeNull();

    const c2 = corpus.cases.find((c) => c.id === "002")!;
    expect(c2.labels.gold).toBeNull();
    expect(c2.labels.goldSource).toBeNull();
  });

  it("normalizes v1 world: empty teams/connections, null subscription, v1 channels", async () => {
    const corpus = await loadV1();
    expect(corpus.world.schemaVersion).toBe(1);
    expect(corpus.world.teams).toEqual([]);
    expect(corpus.world.connections).toEqual([]);
    expect(corpus.world.user.subscription).toBeNull();
    for (const p of corpus.world.priorities) {
      expect(p.description).toBeNull();
      expect(p.facetFilters).toBeNull();
    }
    for (const e of corpus.world.embeddings) {
      expect(e.source).toBeNull();
    }
    expect(corpus.trainingSets[0]!.negativeThreads).toEqual([]);
    expect(corpus.trainingSets[0]!.negatives).toEqual([]);
  });

  it("merges a sibling embeddings.yaml for v1 corpora too", async () => {
    const dir = await writeCorpus({
      "world.yaml": WORLD_V1,
      "trainings/full.yaml": TRAININGS_V1,
      "cases.yaml": CASES_V1,
      "embeddings.yaml": `
embeddings:
  - { ref: emb-sib, vector: ${VEC} }
`,
    });
    const corpus = await loadCorpus(dir);
    expect(corpus.embeddings.has("emb-old")).toBe(true);
    expect(corpus.embeddings.get("emb-sib")!.source).toBeNull();
  });
});
