import { randomUUID } from "node:crypto";

import { describe, expect, it, vi } from "vitest";

import type { Bindings } from "../../env";
import { Integrations } from "./integrations";

type WriteBackGuard = {
  wasNoteWrittenBack(noteId: string): Promise<boolean>;
  markNoteWrittenBack(noteId: string): Promise<void>;
};

/**
 * Minimal Integrations instance exercising only the per-instance store, which
 * is all `wasNoteWrittenBack` / `markNoteWrittenBack` touch — no DB needed.
 */
function makeTool(store: { get: unknown; set: unknown }): WriteBackGuard {
  const env = {
    CALLBACKS: { idFromName: () => ({ name: "stub" }), get: () => ({}) },
  } as unknown as Bindings;

  return new Integrations({
    store: store as never,
    env,
    ctx: { exports: {} as never },
    db: {} as never,
    twistInstanceId: randomUUID(),
    twistId: randomUUID(),
    environment: "development" as never,
    path: [],
    sourceProvider: { provider: "test" },
  }) as unknown as WriteBackGuard;
}

describe("Integrations reply-write-back idempotency marker", () => {
  it("is unset until marked, then set — scoped per note under a reserved key", async () => {
    const data = new Map<string, unknown>();
    const store = {
      get: vi.fn(async (k: string) => (data.has(k) ? data.get(k) : null)),
      set: vi.fn(async (k: string, v: unknown) => {
        data.set(k, v);
      }),
    };
    const tool = makeTool(store);

    expect(await tool.wasNoteWrittenBack("note-1")).toBe(false);

    await tool.markNoteWrittenBack("note-1");
    // Reserved `__` prefix keeps it clear of connector-defined keys.
    expect(store.set).toHaveBeenCalledWith("__writeback:note-1", true);

    expect(await tool.wasNoteWrittenBack("note-1")).toBe(true);
    // A different note is independent.
    expect(await tool.wasNoteWrittenBack("note-2")).toBe(false);
  });

  it("fails closed: a transient store read propagates instead of reading as not-sent", async () => {
    const store = {
      get: vi.fn(async () => {
        throw new Error(
          "storage operation exceeded timeout which caused object to be reset"
        );
      }),
      set: vi.fn(),
    };
    const tool = makeTool(store);

    // Must NOT resolve to false (which would let a resend through) — the error
    // propagates so the queue retries and re-reads on a healthy attempt.
    await expect(tool.wasNoteWrittenBack("note-1")).rejects.toThrow(
      /storage operation exceeded timeout/
    );
  });
});
