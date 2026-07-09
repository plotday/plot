/* SPEC:
When someone writes a journal note in another language, reply in the same
thread with a short plain-English summary of what they wrote, so they can
check their own understanding. Don't react to notes written by automations.
*/
import { ActorType, Twist, type Note, type ToolBuilder } from "@plotday/twister";
import { AI } from "@plotday/twister/tools/ai";
import { Plot, ThreadAccess } from "@plotday/twister/tools/plot";

export default class LanguageJournal extends Twist<LanguageJournal> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        // onNoteCreated only fires for notes on threads this twist created,
        // so Create access is required even though nothing else reads or
        // updates other threads.
        thread: { access: ThreadAccess.Create },
      }),
      ai: build(AI),
    };
  }

  async activate() {
    // Seed the standing thread the user writes journal entries into.
    await this.tools.plot.createThread({
      title: "Language journal",
      notes: [
        {
          content:
            "Write your journal entries here in any language — I'll reply with a plain-English summary.",
        },
      ],
    });
  }

  // Fires for every new note on a thread this twist created. Guard against
  // notes from twists/automations so we never loop on our own replies.
  async onNoteCreated(note: Note): Promise<void> {
    if (note.author.type === ActorType.Twist) {
      return;
    }
    if (!note.content || note.content.trim().length === 0) {
      return;
    }

    const response = await this.tools.ai.prompt({
      model: { speed: "fast", cost: "low" },
      prompt: `Summarize this journal entry in one or two plain-English sentences:\n\n${note.content}`,
    });
    if (!response.text) {
      return;
    }

    // Reply in the same thread the note belongs to.
    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `English summary: ${response.text}`,
    });
  }
}
