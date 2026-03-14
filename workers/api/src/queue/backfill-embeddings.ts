import { createDb } from "../db";
import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";

const BATCH_SIZE = 50;

/**
 * Backfill embeddings for notes that were skipped due to free-tier AI limits.
 * Called when a user upgrades to a paid plan.
 */
export async function backfillEmbeddings(
  env: Bindings,
  userId: string
): Promise<void> {
  const logger = createLogger({
    operation: "backfill-embeddings",
    user_id: userId,
  });

  const db = createDb(env);
  try {
    // Find notes without embeddings in the user's priorities
    const notes = await db
      .selectFrom("note as n")
      .innerJoin("thread as t", "t.id", "n.thread_id")
      .innerJoin("priority_contact as pc", "pc.priority_id", "t.priority_id")
      .innerJoin("contact as c", (join) =>
        join
          .onRef("c.id", "=", "pc.contact_id")
          .on("c.user_id", "=", userId)
      )
      .select(["n.id", "n.content"])
      .where("n.embedding", "is", null)
      .where("n.content", "is not", null)
      .where("n.draft", "=", false)
      .where("n.archived_at", "is", null)
      .limit(BATCH_SIZE)
      .execute();

    if (notes.length === 0) {
      logger.info("[backfill] No notes need embedding backfill");
      return;
    }

    let generated = 0;
    for (const note of notes) {
      if (!note.content || note.content.trim().length === 0) continue;

      try {
        const response = (await env.AI.run("@cf/baai/bge-small-en-v1.5", {
          text: note.content,
        })) as { data: number[][] };

        const embedding = response.data[0];
        await db
          .updateTable("note")
          .set({ embedding: JSON.stringify(embedding) })
          .where("id", "=", note.id)
          .execute();

        generated++;
      } catch (error) {
        logger.warn("[backfill] Failed to generate embedding for note", {
          note_id: note.id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    logger.info(`[backfill] Generated embeddings for ${generated} notes for user ${userId}`);
  } finally {
    await db.destroy();
  }
}
