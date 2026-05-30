import type { SearchResult, SearchOptions } from "@plotday/twister/tools/plot";
import { SEARCH_DEFAULT_LIMIT, SEARCH_MAX_LIMIT } from "@plotday/twister/tools/plot";
import { createLogger } from "@plotday/worker-util";
import { sql } from "kysely";
import { rpc } from "../../../rpc";
import type { Plot } from "./index";

export async function search(
  plot: Plot,
  query: string,
  options?: SearchOptions
): Promise<SearchResult[]> {
  const logger = createLogger({ twist_instance_id: plot.twistInstanceId });

  if (!query?.trim()) {
    logger.info("[search] Empty query, returning no results");
    return [];
  }

  // Skip search when AI is disabled (embeddings required for semantic search)
  if (!(await plot.isAiEnabled())) {
    logger.info("[search] AI disabled, returning no results");
    return [];
  }

  const scopePriorityId =
    options?.focusId ?? (await plot.getRootPriorityId());
  await plot.validatePriorityAccess(scopePriorityId);

  const limit = Math.min(options?.limit ?? SEARCH_DEFAULT_LIMIT, SEARCH_MAX_LIMIT);
  const threshold = options?.threshold ?? 0.3;

  logger.info("[search] Starting search", {
    query: query.substring(0, 100),
    scope_priority_id: scopePriorityId,
    limit,
    threshold,
  });

  // Check if there are any notes with embeddings in scope
  const userId = await plot.getUserId();
  const embeddingCount = await plot.db
    .selectFrom("note")
    .innerJoin("thread", "thread.id", "note.thread_id")
    .innerJoin("thread_priority", "thread_priority.thread_id", "thread.id")
    .innerJoin("priority_child", (join) =>
      join
        .onRef("priority_child.child_id", "=", "thread_priority.priority_id")
        .on("priority_child.priority_id", "=", scopePriorityId)
    )
    .select(sql<number>`count(*)`.as("total"))
    .where("note.embedding", "is not", null)
    .where("note.archived_at", "is", null)
    .where("note.draft", "=", false)
    .where("thread.archived_at", "is", null)
    .where("thread_priority.user_id", "=", userId)
    .executeTakeFirst();

  const totalNotesInScope = await plot.db
    .selectFrom("note")
    .innerJoin("thread", "thread.id", "note.thread_id")
    .innerJoin("thread_priority", "thread_priority.thread_id", "thread.id")
    .innerJoin("priority_child", (join) =>
      join
        .onRef("priority_child.child_id", "=", "thread_priority.priority_id")
        .on("priority_child.priority_id", "=", scopePriorityId)
    )
    .select(sql<number>`count(*)`.as("total"))
    .where("note.archived_at", "is", null)
    .where("note.draft", "=", false)
    .where("thread.archived_at", "is", null)
    .where("thread_priority.user_id", "=", userId)
    .executeTakeFirst();

  logger.info("[search] Notes in scope", {
    with_embeddings: embeddingCount?.total ?? 0,
    total: totalNotesInScope?.total ?? 0,
    scope_priority_id: scopePriorityId,
  });

  const embedding = await plot.ai.embed(query);
  logger.info("[search] Generated query embedding", {
    embedding_length: embedding.length,
    embedding_sample: embedding.slice(0, 5),
  });

  logger.info("[search] Requesting user", { user_id: userId });

  const results = await rpc(plot.db, "search_notes_and_links", {
    query_embedding: JSON.stringify(embedding),
    scope_priority_id: scopePriorityId,
    requesting_user_id: userId,
    exclude_created_by: plot.twistInstanceId,
    similarity_threshold: threshold,
    match_limit: limit,
  });

  logger.info("[search] Raw RPC result", {
    is_array: Array.isArray(results),
    is_null: results === null || results === undefined,
    type: typeof results,
    value: JSON.stringify(results)?.substring(0, 500),
  });

  const rows = Array.isArray(results) ? results : results ? [results] : [];

  logger.info("[search] Search results", {
    count: rows.length,
    results: rows.map((r: any) => ({
      type: r.result_type,
      id: r.result_id,
      similarity: r.similarity,
      thread_title: r.thread_title,
      content_preview: r.content?.substring(0, 50),
    })),
  });

  return rows.map((r: any): SearchResult =>
    r.result_type === 'note'
      ? {
          type: 'note',
          id: r.result_id,
          thread: { id: r.thread_id, title: r.thread_title },
          focus: { id: r.priority_id, title: r.priority_title },
          content: r.content,
          similarity: r.similarity,
        }
      : {
          type: 'link',
          id: r.result_id,
          thread: { id: r.thread_id, title: r.thread_title },
          focus: { id: r.priority_id, title: r.priority_title },
          title: r.title,
          sourceUrl: r.source_url,
          content: r.content,
          similarity: r.similarity,
        }
  );
}
