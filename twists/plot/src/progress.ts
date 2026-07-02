import type { Action, Uuid } from "@plotday/twister";
import type { Plot } from "@plotday/twister/tools/plot";

/**
 * A single note that tracks the assistant's work and finally BECOMES the
 * answer: created at turn start, updated as tools run, replaced by the
 * final content (so the thread never shows a stale "working…" stub).
 */
export class TurnProgress {
  private constructor(
    private readonly plot: Plot,
    private readonly threadId: Uuid,
    readonly noteId: Uuid
  ) {}

  static async start(plot: Plot, threadId: Uuid, initial = "Working on it…"): Promise<TurnProgress> {
    const noteId = await plot.createNote({
      thread: { id: threadId },
      content: `*${initial}*`,
    });
    return new TurnProgress(plot, threadId, noteId);
  }

  async update(message: string): Promise<void> {
    try {
      await this.plot.updateNote({ id: this.noteId, content: `*${message}*` });
    } catch (error) {
      // Progress is cosmetic — never let it break the turn.
      console.error("Progress update failed", error);
    }
  }

  async finish(content: string, actions?: Action[]): Promise<void> {
    await this.plot.updateNote({
      id: this.noteId,
      content,
      actions: actions && actions.length > 0 ? actions : undefined,
    });
  }
}
