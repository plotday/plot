import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpc, rpcUser } from "../../rpc";
import { cleanTitle } from "../../twist/tools/plot/thread";
import { createPreviewFromMarkdown } from "../../twist/tools/plot/thread-helpers";
import { notifySync } from "./notify";

const BASE58_ALPHABET =
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function uuidToBase58(uuid: string): string {
  const hex = uuid.replace(/-/g, "").toUpperCase();
  let num = BigInt("0x" + hex);
  if (num === 0n) return BASE58_ALPHABET[0];
  let result = "";
  const base = BigInt(58);
  while (num > 0n) {
    result = BASE58_ALPHABET[Number(num % base)] + result;
    num = num / base;
  }
  return result;
}

const capture = new Hono<{ Bindings: Bindings }>();

// POST /sync/capture — extension-friendly endpoint that creates a thread + link
// from { source_url, title, preview }, auto-files the thread to the user's
// best-matching priority, and deduplicates against an existing user-visible
// link with the same source_url so re-saving the same page returns the
// existing thread instead of a duplicate.
capture.post("/sync/capture", async (c) => {
  const body = await c.req.json<{
    source_url?: unknown;
    title?: unknown;
    preview?: unknown;
  }>();

  const sourceUrl =
    typeof body.source_url === "string" ? body.source_url.trim() : "";
  if (!sourceUrl) {
    return c.json({ error: "source_url is required" }, 400);
  }

  const rawTitle =
    typeof body.title === "string" && body.title.trim().length > 0
      ? cleanTitle(body.title)
      : sourceUrl;
  const title = rawTitle.length > 0 ? rawTitle : sourceUrl;

  const rawPreview =
    typeof body.preview === "string" ? body.preview : undefined;
  const preview =
    rawPreview && rawPreview.length > 0
      ? createPreviewFromMarkdown(rawPreview)
      : null;

  const userId = c.var.user.id;

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    // Dedup: look up the user's most-recent existing link for this URL.
    // `user.link` is already scoped to threads the caller can see, so we
    // don't need to repeat visibility filters here.
    const existing = await sql<{ thread_id: string; priority_id: string }>`
      SELECT l.thread_id::text AS thread_id,
             tp.priority_id::text AS priority_id
      FROM "user".link l
      LEFT JOIN public.thread_priority tp
        ON tp.thread_id = l.thread_id AND tp.user_id = l.user_id
      WHERE l.user_id = ${userId}::uuid
        AND l.source_url = ${sourceUrl}
        AND l.thread_id IS NOT NULL
      ORDER BY l.created_at DESC
      LIMIT 1
    `.execute(trx);

    if (existing.rows.length > 0) {
      const row = existing.rows[0];
      return {
        thread_id: row.thread_id,
        short_id: uuidToBase58(row.thread_id),
        priority_id: row.priority_id ?? null,
        created: false,
      };
    }

    // Create the thread first so the link has a thread_id to attach to.
    const thread = (await rpcUser(trx, "upsert_thread", {
      user_id: userId,
      p_thread: { title, preview } as any,
      p_defaults: {} as any,
    })) as { id: string };
    const threadId: string = thread.id;

    // Auto-classify the new thread into the user's best-matching priority.
    // Mirrors the logic in POST /sync/threads when auto_file is set: embed
    // the title, persist the embedding, then let classify_thread_for_user()
    // score it against the user's training set and only overwrite the
    // current filing if the user hasn't moved it themselves.
    try {
      const textToEmbed = title || preview || "";
      let queryEmbedding: string | undefined;
      if (textToEmbed) {
        const response = (await c.env.AI.run("@cf/baai/bge-small-en-v1.5", {
          text: textToEmbed,
        })) as { data: number[][] };
        queryEmbedding = JSON.stringify(response.data[0]);
        await sql`UPDATE thread SET embedding = ${sql.val(queryEmbedding!)}::halfvec
                  WHERE id = ${sql.val(threadId)}`.execute(trx);
      }
      const matched = await rpc(trx, "classify_thread_for_user", {
        p_user_id: userId,
        p_thread_id: threadId,
        p_embedding: queryEmbedding ?? null,
      });
      if (matched) {
        await sql`UPDATE thread_priority SET priority_id = ${sql.val(matched)}
                  WHERE thread_id = ${sql.val(threadId)}
                    AND user_id = ${sql.val(userId)}
                    AND user_moved = FALSE`.execute(trx);
      }
    } catch (error) {
      console.error("[sync/capture] Auto-classification failed:", error);
      c.var.tracker.captureException(error as Error);
    }

    // Attach the page as a link on the new thread.
    await rpcUser(trx, "upsert_link", {
      user_id: userId,
      p_link: {
        thread_id: threadId,
        source_url: sourceUrl,
        title,
        preview,
      } as any,
      p_defaults: {} as any,
    });

    // Re-read the final priority assignment after classification ran.
    const finalPriority = await sql<{ priority_id: string }>`
      SELECT priority_id::text AS priority_id
      FROM thread_priority
      WHERE thread_id = ${sql.val(threadId)} AND user_id = ${sql.val(userId)}
      LIMIT 1
    `.execute(trx);
    const priorityId = finalPriority.rows[0]?.priority_id ?? null;

    return {
      thread_id: threadId as string,
      short_id: uuidToBase58(threadId as string),
      priority_id: priorityId,
      created: true,
    };
  });

  if (result.created && result.priority_id) {
    notifySync(c, result.priority_id);
  }

  const { priority_id: _priorityId, ...response } = result;
  return c.json(response);
});

export default capture;
