import { describe, expect, it } from "vitest";

import {
  canonicalInput,
  sha256Hex,
  type CanonicalContextSnapshot,
} from "../src/canonical-input";

const ctx: CanonicalContextSnapshot = {
  userId: "11111111-2222-3333-4444-555555555555",
  priorities: [
    { id: "p2-id", key: "work" },
    { id: "p1-id", key: null },
    { id: "p3-id", key: "personal" },
  ],
};

const cand = {
  threadId: "thread-1",
  title: "Hello",
  topic: "channel:42",
  contacts: ["c2-id", "c1-id"],
  groups: ["g2-id", "g1-id"],
  embedding: [0.123456, 0.234567, 0.345678],
  author: null,
};

describe("canonicalInput", () => {
  it("produces byte-identical output regardless of input ordering", () => {
    const a = canonicalInput("p1", ctx, cand);
    const b = canonicalInput("p1", ctx, {
      ...cand,
      contacts: [...cand.contacts].reverse(),
      groups: [...cand.groups].reverse(),
    });
    expect(a).toBe(b);
  });

  it("produces byte-identical output regardless of priority ordering", () => {
    const a = canonicalInput("p1", ctx, cand);
    const b = canonicalInput(
      "p1",
      { ...ctx, priorities: [...ctx.priorities].reverse() },
      cand
    );
    expect(a).toBe(b);
  });

  it("rounds embedding floats to 4 decimal places", () => {
    const a = canonicalInput("p1", ctx, { ...cand, embedding: [0.123456789] });
    const b = canonicalInput("p1", ctx, { ...cand, embedding: [0.123455] });
    expect(a).toBe(b);
  });

  it("differs when promptId differs", () => {
    expect(canonicalInput("p1", ctx, cand)).not.toBe(
      canonicalInput("p2", ctx, cand)
    );
  });

  it("differs when topic differs", () => {
    expect(canonicalInput("p1", ctx, cand)).not.toBe(
      canonicalInput("p1", ctx, { ...cand, topic: "channel:99" })
    );
  });

  it("sha256Hex is hex-stable", async () => {
    const h1 = await sha256Hex("hello");
    const h2 = await sha256Hex("hello");
    expect(h1).toBe(h2);
    expect(h1).toMatch(/^[0-9a-f]{64}$/);
  });
});
