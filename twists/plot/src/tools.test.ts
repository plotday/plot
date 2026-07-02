import { describe, expect, it } from "vitest";

import { formatThreadNotes, truncateText } from "./tools";

describe("truncateText", () => {
  it("passes through short text and null", () => {
    expect(truncateText("short", 10)).toBe("short");
    expect(truncateText(null, 10)).toBeNull();
  });
  it("truncates with ellipsis marker", () => {
    const out = truncateText("x".repeat(50), 10)!;
    expect(out.length).toBeLessThan(30);
    expect(out).toContain("…");
  });
});

describe("formatThreadNotes", () => {
  it("caps each note and the total budget", () => {
    const notes = Array.from({ length: 20 }, (_, i) => ({
      author: "user",
      content: "y".repeat(3000),
    }));
    const out = formatThreadNotes(notes, 2000, 15000);
    expect(out.totalNotes).toBe(20);
    expect(out.truncated).toBe(true);
    expect(out.notes.length).toBeLessThan(20);
    for (const n of out.notes) expect(n.content.length).toBeLessThanOrEqual(2001);
  });
});
