import { describe, expect, it, vi } from "vitest";

import type { Uuid } from "@plotday/twister";

import { TurnProgress } from "./progress";

const threadId = "thread-1" as Uuid;
const noteId = "note-1" as Uuid;

function makePlot(overrides: Partial<{ createNote: any; updateNote: any }> = {}) {
  return {
    createNote: vi.fn().mockResolvedValue(noteId),
    updateNote: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  } as any;
}

describe("TurnProgress", () => {
  it("start() creates a note on the thread and exposes its id", async () => {
    const plot = makePlot();
    const progress = await TurnProgress.start(plot, threadId);

    expect(plot.createNote).toHaveBeenCalledTimes(1);
    expect(plot.createNote).toHaveBeenCalledWith({
      thread: { id: threadId },
      content: "*Working on it…*",
    });
    expect(progress.noteId).toBe(noteId);
  });

  it("start() accepts a custom initial message", async () => {
    const plot = makePlot();
    await TurnProgress.start(plot, threadId, "Searching…");

    expect(plot.createNote).toHaveBeenCalledWith({
      thread: { id: threadId },
      content: "*Searching…*",
    });
  });

  it("update() updates the same note by id", async () => {
    const plot = makePlot();
    const progress = await TurnProgress.start(plot, threadId);

    await progress.update("Reading thread…");

    expect(plot.updateNote).toHaveBeenCalledTimes(1);
    expect(plot.updateNote).toHaveBeenCalledWith({
      id: noteId,
      content: "*Reading thread…*",
    });
  });

  it("update() swallows errors instead of throwing (cosmetic only)", async () => {
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const plot = makePlot({
      updateNote: vi.fn().mockRejectedValue(new Error("network blip")),
    });
    const progress = await TurnProgress.start(plot, threadId);

    await expect(progress.update("Still working…")).resolves.toBeUndefined();
    expect(consoleSpy).toHaveBeenCalledWith(
      "Progress update failed",
      expect.any(Error)
    );

    consoleSpy.mockRestore();
  });

  it("finish() replaces the progress note with the final content and actions", async () => {
    const plot = makePlot();
    const progress = await TurnProgress.start(plot, threadId);
    const actions = [{ type: "open" }] as any;

    await progress.finish("Here is your answer.", actions);

    expect(plot.updateNote).toHaveBeenCalledWith({
      id: noteId,
      content: "Here is your answer.",
      actions,
    });
  });

  it("finish() omits actions when the list is empty or absent", async () => {
    const plot = makePlot();
    const progress = await TurnProgress.start(plot, threadId);

    await progress.finish("Here is your answer.", []);

    expect(plot.updateNote).toHaveBeenCalledWith({
      id: noteId,
      content: "Here is your answer.",
      actions: undefined,
    });

    await progress.finish("Another answer.");

    expect(plot.updateNote).toHaveBeenLastCalledWith({
      id: noteId,
      content: "Another answer.",
      actions: undefined,
    });
  });

  it("finish() propagates errors (unlike update())", async () => {
    const plot = makePlot({
      updateNote: vi.fn().mockRejectedValue(new Error("thread archived")),
    });
    const progress = await TurnProgress.start(plot, threadId);

    await expect(progress.finish("Here is your answer.")).rejects.toThrow(
      "thread archived"
    );
  });
});
