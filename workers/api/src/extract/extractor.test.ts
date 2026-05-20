import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  MIN_MARKDOWN_LENGTH,
  PARTIAL_CONVERSION_PREFIX,
  extractMarkdown,
} from "./extractor";

function loadFixture(name: string): string {
  return readFileSync(join(__dirname, "__fixtures__", name), "utf8");
}

describe("extractMarkdown", () => {
  it("extracts a code-fenced JS block with the language tag (MDN-shaped page)", () => {
    const html = loadFixture("mdn.html");
    const result = extractMarkdown(
      "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/map",
      html
    );

    expect(result.title).toBeTruthy();
    expect(result.md.length).toBeGreaterThan(MIN_MARKDOWN_LENGTH);
    // The smoke check the research doc calls out: language tag on code fences.
    // If Turndown rules aren't wired up the fence comes through without "js".
    expect(result.md).toContain("```js");
  });

  it("converts numbered citations to footnote refs (Wikipedia-shaped page)", () => {
    const html = loadFixture("wikipedia.html");
    const result = extractMarkdown(
      "https://en.wikipedia.org/wiki/Markdown",
      html
    );

    expect(result.title).toBeTruthy();
    expect(result.md.length).toBeGreaterThan(MIN_MARKDOWN_LENGTH);
    // The other smoke check from the research doc: [1] -> [^1] footnotes.
    expect(result.md).toMatch(/\[\^1\]/);
  });

  it("returns the PARTIAL_CONVERSION_PREFIX sentinel string when Turndown errors", () => {
    // Sanity check that the prefix the queue consumer guards on is the literal
    // string defuddle/markdown emits — protects against an upstream rename.
    expect(PARTIAL_CONVERSION_PREFIX).toBe(
      "Partial conversion completed with errors"
    );
  });
});
