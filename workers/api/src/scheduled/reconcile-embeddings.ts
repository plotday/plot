import { sql } from "kysely";

import { createLogger } from "@plotday/worker-util";

import { createDb } from "../db";
import type { Bindings } from "../env";

// Per-tick caps. Each embedded row is one Workers AI subrequest, so we stay
// well under the per-invocation subrequest budget and leave room for the rest
// of the cron's work. The sweep is idempotent and self-draining: rows fall out
// of the `embedding IS NULL` predicate as they're filled, so the backlog clears
// over successive ticks and then the queries return nothing.
const THREADS_PER_TICK = 300;
const NOTES_PER_TICK = 300;
// How many embeddings to request concurrently from Workers AI within a tick.
const EMBED_CONCURRENCY = 25;
// Bound the text we send per item. bge-small truncates at 512 tokens anyway;
// this just keeps payloads small for very long notes.
const MAX_EMBED_CHARS = 4000;

const EMBED_MODEL = "@cf/baai/bge-small-en-v1.5";

type PendingRow = { id: string; text: string };
type EmbeddedRow = { id: string; emb: string };

/**
 * Periodic reconciliation sweep that backfills missing `embedding` values on
 * threads and notes — both the historical backlog (rows created before
 * embeddings were persisted, or while creation-time embedding failed) and any
 * future row whose creation-time embedding didn't land.
 *
 * This is the resiliency backstop for focus-matching / classification: even if
 * the inline embedding at create time fails (transient Workers AI error, etc.),
 * the row is picked up here within a few minutes. Embedding is cheap and runs
 * entirely in-network, so it is NOT gated by the free-tier AI quota — only the
 * user's built-in-AI opt-out (`ai_preference.builtin_ai_disabled`) is honored:
 * a thread/note is skipped while any user who has it filed has opted out.
 *
 * Idempotent and bounded: re-running embeds whatever is still NULL, so a failed
 * embed simply retries next tick.
 */
export async function reconcileMissingEmbeddings(
  env: Bindings,
  _ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "reconcile-embeddings" });
  const db = createDb(env);
  try {
    // --- Threads ---
    const threadRows = await sql<PendingRow>`
      SELECT
        t.id,
        left(trim(coalesce(t.title, '') || ' ' || coalesce(t.preview, '')), ${MAX_EMBED_CHARS}) AS text
      FROM public.thread t
      WHERE t.embedding IS NULL
        AND t.title IS NOT NULL
        AND length(trim(t.title)) > 0
        AND t.archived_at IS NULL
        AND NOT EXISTS (
          SELECT 1
          FROM public.thread_priority tp
          JOIN public.ai_preference ap ON ap.user_id = tp.user_id
          WHERE tp.thread_id = t.id AND ap.builtin_ai_disabled = TRUE
        )
      ORDER BY t.created_at DESC
      LIMIT ${THREADS_PER_TICK}
    `.execute(db);

    const threadEmbeds = await embedRows(env, threadRows.rows, logger);
    if (threadEmbeds.length > 0) {
      await applyEmbeddings(db, "thread", threadEmbeds);
    }

    // --- Notes ---
    const noteRows = await sql<PendingRow>`
      SELECT
        n.id,
        left(trim(n.content), ${MAX_EMBED_CHARS}) AS text
      FROM public.note n
      WHERE n.embedding IS NULL
        AND n.content IS NOT NULL
        AND length(trim(n.content)) > 0
        AND n.draft = FALSE
        AND n.archived_at IS NULL
        AND NOT EXISTS (
          SELECT 1
          FROM public.thread_priority tp
          JOIN public.ai_preference ap ON ap.user_id = tp.user_id
          WHERE tp.thread_id = n.thread_id AND ap.builtin_ai_disabled = TRUE
        )
      ORDER BY n.created_at DESC
      LIMIT ${NOTES_PER_TICK}
    `.execute(db);

    const noteEmbeds = await embedRows(env, noteRows.rows, logger);
    if (noteEmbeds.length > 0) {
      await applyEmbeddings(db, "note", noteEmbeds);
    }

    if (threadEmbeds.length > 0 || noteEmbeds.length > 0) {
      logger.info("[reconcile-embeddings] backfilled embeddings", {
        threads: threadEmbeds.length,
        notes: noteEmbeds.length,
      });
    }
  } finally {
    await db.destroy();
  }
}

/**
 * Embed a batch of rows with bounded concurrency. Failures are logged and
 * dropped (the row stays NULL and is retried on a later tick).
 */
async function embedRows(
  env: Bindings,
  rows: PendingRow[],
  logger: ReturnType<typeof createLogger>
): Promise<EmbeddedRow[]> {
  const out: EmbeddedRow[] = [];
  for (let i = 0; i < rows.length; i += EMBED_CONCURRENCY) {
    const chunk = rows.slice(i, i + EMBED_CONCURRENCY);
    const settled = await Promise.allSettled(
      chunk.map(async (row): Promise<EmbeddedRow> => {
        const response = (await env.AI.run(EMBED_MODEL, {
          text: row.text,
        })) as { data: number[][] };
        return { id: row.id, emb: JSON.stringify(response.data[0]) };
      })
    );
    for (const result of settled) {
      if (result.status === "fulfilled") {
        out.push(result.value);
      } else {
        logger.warn("[reconcile-embeddings] embed failed", {
          error:
            result.reason instanceof Error
              ? result.reason.message
              : String(result.reason),
        });
      }
    }
  }
  return out;
}

/**
 * Write embeddings back in a single statement via UPDATE ... FROM (VALUES ...)
 * so a whole chunk costs one round-trip instead of N.
 */
async function applyEmbeddings(
  db: ReturnType<typeof createDb>,
  table: "thread" | "note",
  pairs: EmbeddedRow[]
): Promise<void> {
  const values = sql.join(
    pairs.map((p) => sql`(${p.id}::uuid, ${p.emb}::halfvec)`)
  );
  const target = table === "thread" ? sql`public.thread` : sql`public.note`;
  await sql`
    UPDATE ${target} AS t
    SET embedding = v.emb
    FROM (VALUES ${values}) AS v(id, emb)
    WHERE t.id = v.id
  `.execute(db);
}
