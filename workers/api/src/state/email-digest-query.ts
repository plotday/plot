import { sql, type Kysely } from "kysely";

import type { DB } from "../db";

/** One unread thread eligible for the email digest, with its filing priority. */
export type DigestThreadRow = {
  thread_id: string;
  thread_title: string | null;
  thread_preview: string | null;
  thread_updated_at: string;
  priority_id: string;
  priority_path: string;
  priority_title: string;
  author_names: string | null;
  note_count: number;
};

/**
 * Select the unread threads that should appear in a user's email digest,
 * newest first.
 *
 * Only genuine Plot activity qualifies:
 *   - connector-synced threads (`thread.twist_id IS NOT NULL`) are excluded, and
 *   - the thread must contain at least one non-archived note authored in Plot
 *     (`note.link_id IS NULL`) by someone other than the recipient
 *     (`note.author_id` not among the user's linked contacts).
 *
 * `db` may be a Kysely instance or a transaction handle (Transaction extends Kysely).
 */
export async function selectDigestThreads(
  db: Kysely<DB>,
  userId: string
): Promise<DigestThreadRow[]> {
  const result = await sql<DigestThreadRow>`
    SELECT
      t.id::text AS thread_id,
      t.title AS thread_title,
      t.preview AS thread_preview,
      tu.updated_at::text AS thread_updated_at,
      p.id::text AS priority_id,
      p.path::text AS priority_path,
      p.title AS priority_title,
      (
        SELECT string_agg(DISTINCT COALESCE(a.name, 'Someone'), ',')
        FROM note n
        JOIN actor a ON a.id = n.author_id
        WHERE n.thread_id = t.id
          AND n.link_id IS NULL
          AND n.archived_at IS NULL
          AND NOT (n.author_id = ANY("user".user_contact_ids(${userId}::uuid)))
      ) AS author_names,
      (
        SELECT count(n.id)::int
        FROM note n
        WHERE n.thread_id = t.id
          AND n.link_id IS NULL
          AND n.archived_at IS NULL
          AND NOT (n.author_id = ANY("user".user_contact_ids(${userId}::uuid)))
      ) AS note_count
    FROM thread_state tu
    JOIN thread t ON t.id = tu.thread_id
    JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
    JOIN priority p ON p.id = tp.priority_id
    WHERE tu.user_id = ${userId}::uuid
      AND tu.read_at IS NULL
      AND (tu.importance >= 50 OR tu.urgent = TRUE)
      AND t.archived_at IS NULL
      AND (t.draft = false OR t.created_by = ${userId}::uuid)
      AND (
        t.contacts && "user".user_contact_ids(${userId}::uuid)
        OR t.groups && "user".user_group_ids(${userId}::uuid)
      )
      AND t.twist_id IS NULL
      AND COALESCE(t.facets ->> 'format', '') NOT IN ('notification', 'promotion')
      AND EXISTS (
        SELECT 1 FROM note n
        WHERE n.thread_id = t.id
          AND n.link_id IS NULL
          AND n.archived_at IS NULL
          AND NOT (n.author_id = ANY("user".user_contact_ids(${userId}::uuid)))
      )
    ORDER BY tu.updated_at DESC
  `.execute(db);
  return result.rows;
}
