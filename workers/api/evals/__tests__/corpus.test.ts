import { describe, it, expect } from "vitest";

import { loadCorpus, parseSpecFile } from "../lib/corpus";

const FIXTURE = `---
id: sample-spec
category: smoke
difficulty: easy
assertions:
  - match: 'createThread'
    why: must create a thread
notMatch:
  - pattern: 'extends\\s+Connector'
    why: twists extend Twist
allowDeps: []
---
# Sample

Do a thing.
`;

describe("parseSpecFile", () => {
  it("parses frontmatter and body", () => {
    const spec = parseSpecFile(FIXTURE, "sample.md");
    expect(spec.id).toBe("sample-spec");
    expect(spec.category).toBe("smoke");
    expect(spec.difficulty).toBe("easy");
    expect(spec.assertions).toEqual([
      { match: "createThread", why: "must create a thread" },
    ]);
    expect(spec.notMatch).toEqual([
      { pattern: "extends\\s+Connector", why: "twists extend Twist" },
    ]);
    expect(spec.body).toContain("Do a thing.");
    expect(spec.body).not.toContain("---");
    expect(spec.corpusHash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("rejects a file without frontmatter", () => {
    expect(() => parseSpecFile("# no frontmatter", "bad.md")).toThrow(
      /frontmatter/
    );
  });

  it("rejects an invalid regex", () => {
    const bad = FIXTURE.replace("createThread", "((unclosed");
    expect(() => parseSpecFile(bad, "bad.md")).toThrow(/regex/i);
  });

  it("rejects an unknown difficulty", () => {
    const bad = FIXTURE.replace("difficulty: easy", "difficulty: brutal");
    expect(() => parseSpecFile(bad, "bad.md")).toThrow(/difficulty/);
  });
});

describe("shipped corpus", () => {
  it("loads all 12 specs with unique ids and non-empty bodies", async () => {
    const corpus = await loadCorpus();
    expect(corpus).toHaveLength(12);
    const ids = new Set(corpus.map((s) => s.id));
    expect(ids.size).toBe(12);
    for (const spec of corpus) {
      expect(spec.body.length).toBeGreaterThan(40);
      expect(spec.assertions.length).toBeGreaterThan(0);
    }
  });
});
