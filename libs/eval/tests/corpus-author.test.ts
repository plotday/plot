import { describe, expect, it } from "vitest";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { loadCorpus } from "../src/corpus/load";

const WORLD = `
name: t
schema_version: 1
user: { id: "00000000-0000-4000-8000-000000000001", email: "u@e.test" }
priorities:
  - { slug: root, id: "00000000-0000-4000-8000-000000000010", path: "root", title: Root }
contacts:
  - { slug: alice, id: "00000000-0000-4000-8000-000000000020", email: "a@e.test", name: Alice }
`;

const TRAININGS_FULL = `
threads:
  - id: "00000000-0000-4000-8000-000000000100"
    title: t1
    filed_to_priority: root
    author: alice
  - id: "00000000-0000-4000-8000-000000000101"
    title: t2
    filed_to_priority: root
    author: "twist:gmail"
`;

const CASES = `
cases:
  - id: "001"
    candidate: { title: x, author: alice }
    labels: { gold: root }
`;

describe("corpus author resolution", () => {
  it("resolves contact slugs, twist:* slugs, and absent values", async () => {
    const dir = await mkdtemp(join(tmpdir(), "eval-corpus-"));
    await writeFile(join(dir, "world.yaml"), WORLD);
    await mkdir(join(dir, "trainings"));
    await writeFile(join(dir, "trainings", "full.yaml"), TRAININGS_FULL);
    await writeFile(join(dir, "cases.yaml"), CASES);

    const corpus = await loadCorpus(dir);
    const threads = corpus.trainingSets[0]!.threads;

    // v1 `author` semantics: the resolved value lands in createdByOverride
    // (v1 wrote it into thread.created_by, never thread.author_id).
    expect(threads[0]!.createdByOverride).toBe(
      "00000000-0000-4000-8000-000000000020"
    );
    expect(threads[1]!.createdByOverride).toMatch(/^[0-9a-f]{8}-/);
    expect(threads[1]!.createdByOverride).not.toBe(
      "00000000-0000-4000-8000-000000000020"
    );
    expect(corpus.cases[0]!.candidate.createdByOverride).toBe(
      "00000000-0000-4000-8000-000000000020"
    );
  });
});
