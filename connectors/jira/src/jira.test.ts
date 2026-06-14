import { describe, it, expect } from "vitest";

import { textToADF, adfToText } from "./jira-adf";
import { statusCategoryToIcon } from "./jira";

describe("ADF round-trip", () => {
  for (const s of ["hello", "para one\n\npara two", "line", "a\n\nb\n\nc"]) {
    it(`round-trips ${JSON.stringify(s)}`, () => {
      expect(adfToText(textToADF(s))).toBe(s.trim());
    });
  }

  it("textToADF makes one paragraph per blank-line block", () => {
    expect(textToADF("a\n\nb").content).toHaveLength(2);
  });

  it("textToADF trims surrounding whitespace before splitting", () => {
    // Leading/trailing blank lines must not add empty paragraphs, so the
    // round-trip baseline equals `s.trim()`.
    expect(adfToText(textToADF("  \n\nhello\n\n  "))).toBe("hello");
  });

  it("adfToText returns '' for empty / non-object input", () => {
    expect(adfToText(null)).toBe("");
    expect(adfToText(undefined)).toBe("");
    expect(adfToText("plain string")).toBe("");
  });

  it("textToADF produces a valid empty doc for empty text", () => {
    const doc = textToADF("");
    expect(doc.type).toBe("doc");
    expect(doc.version).toBe(1);
    expect(doc.content).toHaveLength(0);
  });

  it("adfToText joins multiple paragraphs with a blank line", () => {
    const doc = {
      version: 1,
      type: "doc",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "first" }] },
        { type: "paragraph", content: [{ type: "text", text: "second" }] },
      ],
    };
    expect(adfToText(doc)).toBe("first\n\nsecond");
  });
});

describe("statusCategoryToIcon", () => {
  it("maps status categories to icons", () => {
    expect(statusCategoryToIcon("new")).toBe("todo");
    expect(statusCategoryToIcon("indeterminate")).toBe("inProgress");
    expect(statusCategoryToIcon("done")).toBe("done");
  });

  it("defaults unknown / missing categories to todo", () => {
    expect(statusCategoryToIcon("anything-else")).toBe("todo");
    expect(statusCategoryToIcon(undefined)).toBe("todo");
    expect(statusCategoryToIcon(null)).toBe("todo");
  });
});
