import { describe, expect, it } from "vitest";
import { ActorType, type Note } from "@plotday/twister";

import {
  MAX_CHARS_PER_MESSAGE,
  buildMessages,
  partitionHistory,
  withSummary,
} from "./messages";

function note(author: ActorType, content: string): Note {
  return { content, author: { type: author } } as unknown as Note;
}

describe("buildMessages", () => {
  it("maps twist notes to assistant and others to user", () => {
    const out = buildMessages([note(ActorType.User, "hi"), note(ActorType.Twist, "hello")]);
    expect(out).toEqual([
      { role: "user", content: "hi" },
      { role: "assistant", content: "hello" },
    ]);
  });

  it("merges consecutive same-role turns", () => {
    const out = buildMessages([
      note(ActorType.User, "a"),
      note(ActorType.User, "b"),
      note(ActorType.Twist, "c"),
    ]);
    expect(out).toEqual([
      { role: "user", content: "a\n\nb" },
      { role: "assistant", content: "c" },
    ]);
  });

  it("drops leading assistant turns and empty notes", () => {
    const out = buildMessages([
      note(ActorType.Twist, "welcome"),
      note(ActorType.User, "  "),
      note(ActorType.User, "question"),
    ]);
    expect(out).toEqual([{ role: "user", content: "question" }]);
  });

  it("truncates a single note's content at MAX_CHARS_PER_MESSAGE with a trailing ellipsis", () => {
    const longContent = "x".repeat(MAX_CHARS_PER_MESSAGE + 500);
    const out = buildMessages([note(ActorType.User, longContent)]);
    expect(out).toHaveLength(1);
    expect(out[0].content.length).toBe(MAX_CHARS_PER_MESSAGE);
    expect(out[0].content.endsWith("…")).toBe(true);
  });
});

describe("partitionHistory", () => {
  const mk = (n: number) =>
    Array.from({ length: n }, (_, i) => ({
      role: (i % 2 === 0 ? "user" : "assistant") as "user" | "assistant",
      content: `m${i}`,
    }));

  it("keeps everything under the cap", () => {
    const { older, recent } = partitionHistory(mk(10));
    expect(older).toHaveLength(0);
    expect(recent).toHaveLength(10);
  });

  it("splits at the cap and starts recent on a user turn", () => {
    const { older, recent } = partitionHistory(mk(50), 40);
    expect(older.length + recent.length).toBe(50);
    expect(recent.length).toBeLessThanOrEqual(40);
    expect(recent[0].role).toBe("user");
  });

  it("walks the cut forward when it lands on an assistant turn", () => {
    // 43 messages, maxTurns 40 → natural cut at index 3, which is an
    // assistant turn (mk: even index = user, odd = assistant). The walk
    // must advance past it to index 4 (user), shrinking recent below the cap.
    const merged = mk(43);
    expect(merged[3].role).toBe("assistant");
    const { older, recent } = partitionHistory(merged, 40);
    expect(older.length + recent.length).toBe(merged.length);
    expect(recent[0].role).toBe("user");
    expect(older).toHaveLength(4);
    expect(recent).toHaveLength(39);
    expect(recent.length).toBeLessThan(40);
  });

  it("returns everything as recent at the exact cap boundary", () => {
    const { older, recent } = partitionHistory(mk(40), 40);
    expect(older).toHaveLength(0);
    expect(recent).toHaveLength(40);
  });
});

describe("withSummary", () => {
  it("prepends a user-role context block and preserves alternation", () => {
    const recent = [{ role: "user" as const, content: "latest" }];
    const out = withSummary(recent, "They discussed X.", 12);
    expect(out[0].role).toBe("user");
    expect(out[0].content).toContain("They discussed X.");
    expect(out[0].content).toContain("latest");
  });

  it("renders the omitted-count-only header when summary is null", () => {
    const recent = [
      { role: "user" as const, content: "latest" },
      { role: "assistant" as const, content: "reply" },
    ];
    const out = withSummary(recent, null, 7);
    expect(out).toHaveLength(2);
    expect(out[0].role).toBe("user");
    expect(out[0].content).toContain("7 earlier messages omitted.");
    expect(out[0].content).not.toContain("Summary:");
    expect(out[0].content).toContain("latest");
    expect(out[1]).toEqual({ role: "assistant", content: "reply" });
  });
});
