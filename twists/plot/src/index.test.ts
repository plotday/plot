import { beforeEach, describe, expect, it, vi } from "vitest";

import { Tag, type Uuid } from "@plotday/twister";

import PlotTwist from "./index";

/**
 * Construct a PlotTwist with a mock ToolShed so we can exercise
 * `continueInBackground` — the fresh-budget background continuation — in
 * isolation. Only `plot`, `ai`, and `store` are used by that method.
 */
function makeTwist() {
  const store = {
    get: vi.fn(),
    set: vi.fn().mockResolvedValue(undefined),
    clear: vi.fn().mockResolvedValue(undefined),
  };
  const plot = {
    updateNote: vi.fn().mockResolvedValue(undefined),
    updateThread: vi.fn().mockResolvedValue(undefined),
  };
  const ai = {
    available: vi.fn().mockResolvedValue({ prompt: true, webSearch: true }),
    prompt: vi.fn().mockResolvedValue({
      text: "The answer.",
      sources: [],
      finishReason: "stop",
    }),
  };
  const toolShed = { getTools: () => ({ plot, ai, store }) } as any;
  const twist = new (PlotTwist as any)("twist-id" as Uuid, toolShed) as PlotTwist;
  return { twist, store, plot, ai };
}

const STATE = {
  threadId: "thread-1",
  focusId: "focus-1",
  progressNoteId: "note-1",
  messages: [{ role: "user", content: "hi" }],
};

describe("continueInBackground", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("no-ops when the stored state is missing (already handled/expired)", async () => {
    const { twist, store, plot } = makeTwist();
    store.get.mockResolvedValue(null);

    await twist.continueInBackground("bg:note-1");

    expect(store.get).toHaveBeenCalledWith("bg:note-1");
    // Early return happens before the try — no note/thread mutation, no clear.
    expect(plot.updateNote).not.toHaveBeenCalled();
    expect(plot.updateThread).not.toHaveBeenCalled();
    expect(store.clear).not.toHaveBeenCalled();
  });

  it("runs one final turn, writes the answer, then clears state + Tag.Twist", async () => {
    const { twist, store, plot, ai } = makeTwist();
    store.get.mockResolvedValue(STATE);

    await twist.continueInBackground("bg:note-1");

    // Exactly one prompt round (no re-hand-off regardless of finishReason).
    expect(ai.prompt).toHaveBeenCalledTimes(1);
    // The progress note becomes the final answer.
    expect(plot.updateNote).toHaveBeenCalledWith({
      id: "note-1",
      content: "The answer.",
      actions: undefined,
    });
    // Cleanup in finally: state cleared, working flag lowered.
    expect(store.clear).toHaveBeenCalledWith("bg:note-1");
    expect(plot.updateThread).toHaveBeenCalledWith({
      id: "thread-1",
      twistTags: { [Tag.Twist]: false },
    });
  });

  it("does NOT re-hand-off even when the final turn ends on tool-calls", async () => {
    const { twist, store, ai, plot } = makeTwist();
    store.get.mockResolvedValue(STATE);
    ai.prompt.mockResolvedValue({
      text: "Best effort answer.",
      sources: [],
      finishReason: "tool-calls",
    });

    await twist.continueInBackground("bg:note-1");

    expect(ai.prompt).toHaveBeenCalledTimes(1);
    expect(plot.updateNote).toHaveBeenCalledWith(
      expect.objectContaining({ content: "Best effort answer." })
    );
    expect(store.clear).toHaveBeenCalledWith("bg:note-1");
  });

  it("falls back to a narrowing prompt when the model returns empty text", async () => {
    const { twist, store, ai, plot } = makeTwist();
    store.get.mockResolvedValue(STATE);
    ai.prompt.mockResolvedValue({ text: "   ", sources: [], finishReason: "stop" });

    await twist.continueInBackground("bg:note-1");

    expect(plot.updateNote).toHaveBeenCalledWith(
      expect.objectContaining({
        content: expect.stringContaining("couldn't finish cleanly"),
      })
    );
  });

  it("surfaces a failure message and STILL clears state + Tag.Twist when the prompt throws", async () => {
    const { twist, store, ai, plot } = makeTwist();
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    store.get.mockResolvedValue(STATE);
    // Non-transient error so promptWithRetry rethrows immediately.
    ai.prompt.mockRejectedValue(new Error("boom"));

    await twist.continueInBackground("bg:note-1");

    expect(plot.updateNote).toHaveBeenCalledWith(
      expect.objectContaining({
        content: expect.stringContaining("ran out of room"),
      })
    );
    // finally still runs after the catch.
    expect(store.clear).toHaveBeenCalledWith("bg:note-1");
    expect(plot.updateThread).toHaveBeenCalledWith({
      id: "thread-1",
      twistTags: { [Tag.Twist]: false },
    });
    consoleSpy.mockRestore();
  });
});
