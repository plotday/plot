import { Hono } from "hono";
import { sql } from "kysely";

import type { Bindings } from "../env";
import { captureServerError } from "../utils/error-capture";
import { checkAiLimit, recordAiUsage } from "../utils/ai-limits";
import { generateSummary, fallbackSummary } from "./notification-summary";

const notificationContent = new Hono<{ Bindings: Bindings }>();

// GET /notification-content - Fetch fresh notification content for the authenticated user.
// Called by the device at push-receive time to get up-to-date summaries.
notificationContent.get("/notification-content", async (c) => {
  try {
    const db = c.var.db;
    const userId = c.var.user.id;

    // Get all notify-worthy unread threads (importance >= 50 OR urgent) with
    // their priority paths. Excludes archived threads, draft threads (unless
    // created by this user), and private threads the user can't see.
    const threadsResult = await sql<{
      urgent: boolean;
      importance: number;
      ts_updated_at: Date;
      thread_id: string;
      thread_title: string | null;
      thread_preview: string | null;
      priority_id: string;
      priority_path: string;
      priority_title: string;
      has_been_read: boolean;
      original_author_name: string | null;
      unread_author_names: string | null;
    }>`
      SELECT
        tu.urgent,
        tu.importance,
        tu.updated_at AS ts_updated_at,
        t.id::text AS thread_id,
        t.title AS thread_title,
        t.preview AS thread_preview,
        p.id::text AS priority_id,
        p.path::text AS priority_path,
        p.title AS priority_title,
        EXISTS (
          SELECT 1 FROM thread_read tr
          WHERE tr.thread_id = t.id AND tr.user_id = ${userId}::uuid
        ) AS has_been_read,
        (
          SELECT a.name FROM actor a
          WHERE a.id = COALESCE(
            t.author_id,
            (
              SELECT n.author_id FROM note n
              WHERE n.thread_id = t.id AND n.archived_at IS NULL
              ORDER BY n.created_at ASC LIMIT 1
            )
          )
        ) AS original_author_name,
        (
          SELECT string_agg(DISTINCT COALESCE(a.name, 'Someone'), ',')
          FROM note n
          JOIN actor a ON a.id = n.author_id
          LEFT JOIN thread_read tr ON tr.thread_id = t.id AND tr.user_id = ${userId}::uuid
          WHERE n.thread_id = t.id
            AND n.archived_at IS NULL
            AND n.draft = false
            AND NOT (n.author_id = ANY("user".user_contact_ids(${userId}::uuid)))
            AND (tr.read_at IS NULL OR n.created_at > tr.read_at)
        ) AS unread_author_names
      FROM thread_state tu
      JOIN thread t ON t.id = tu.thread_id
      JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
      JOIN priority p ON p.id = tp.priority_id
      -- The notification high-water mark lives on the first-level focus (the
      -- grouping unit for notifications and the row we stamp below), so resolve
      -- each thread's priority to its focus ancestor and read the watermark
      -- there — not from the leaf, which is never stamped.
      JOIN priority focus ON focus.user_id = p.user_id
        AND focus.path = subpath(p.path, 0, LEAST(2, nlevel(p.path)))
      WHERE tu.user_id = ${userId}::uuid
        AND tu.read_at IS NULL
        AND (tu.importance >= 50 OR tu.urgent = TRUE)
        AND (
          focus.notification_cleared_at IS NULL
          OR date_trunc('milliseconds', tu.updated_at) > focus.notification_cleared_at
        )
        AND t.archived_at IS NULL
        AND (t.draft = false OR t.created_by = ${userId}::uuid)
        AND (
          t.contacts && "user".user_contact_ids(${userId}::uuid)
          OR t.groups && "user".user_group_ids(${userId}::uuid)
        )
        AND COALESCE(t.facets ->> 'format', '') NOT IN ('notification', 'promotion')
        -- FYI is a muted focus — never summarize or stamp its watermark.
        AND focus.is_fyi = FALSE
      ORDER BY tu.urgent DESC, tu.importance DESC
    `.execute(db);

    if (threadsResult.rows.length === 0) {
      return c.json({ summaries: [] });
    }

    // Collect all unique first-level paths (depth 2 under each tree root).
    // For threads directly in a root priority (depth 1), use the root itself.
    const firstLevelPaths = new Set<string>();
    for (const row of threadsResult.rows) {
      const segments = row.priority_path.split(".");
      // First-level = first two segments (root.child), or the root itself if depth 1
      const firstLevelPath = segments.slice(0, Math.min(2, segments.length)).join(".");
      firstLevelPaths.add(firstLevelPath);
    }

    // Look up priority info for all first-level paths
    const firstLevelResult = await sql<{
      id: string;
      path: string;
      title: string;
    }>`
      SELECT id::text AS id, path::text AS path, title
      FROM priority
      WHERE path::text = ANY(${[...firstLevelPaths]})
    `.execute(db);

    const firstLevelByPath = new Map<string, { id: string; title: string }>();
    for (const fl of firstLevelResult.rows) {
      firstLevelByPath.set(fl.path, { id: fl.id, title: fl.title });
    }

    type BatchData = {
      firstLevelPriorityId: string;
      priorityTitle: string;
      threads: Array<{
        id: string;
        title: string | null;
        preview: string | null;
        has_been_read?: boolean;
        original_author_name?: string | null;
        unread_author_names?: string | null;
      }>;
      urgent: boolean;
      maxUpdatedAt: Date;
    };

    // Group threads by first-level priority
    const batchMap = new Map<string, BatchData>();

    for (const row of threadsResult.rows) {
      const segments = row.priority_path.split(".");
      const firstLevelPath = segments.slice(0, Math.min(2, segments.length)).join(".");
      const firstLevelInfo = firstLevelByPath.get(firstLevelPath);
      if (!firstLevelInfo) continue;

      let batch = batchMap.get(firstLevelPath);
      if (!batch) {
        batch = {
          firstLevelPriorityId: firstLevelInfo.id,
          priorityTitle: firstLevelInfo.title,
          threads: [],
          urgent: false,
          maxUpdatedAt: row.ts_updated_at,
        };
        batchMap.set(firstLevelPath, batch);
      } else if (row.ts_updated_at > batch.maxUpdatedAt) {
        batch.maxUpdatedAt = row.ts_updated_at;
      }

      batch.threads.push({
        id: row.thread_id,
        title: row.thread_title,
        preview: row.thread_preview,
        has_been_read: row.has_been_read,
        original_author_name: row.original_author_name,
        unread_author_names: row.unread_author_names,
      });

      if (row.urgent) batch.urgent = true;
    }

    if (batchMap.size === 0) {
      return c.json({ summaries: [] });
    }

    // Check AI usage limit
    const aiAllowed = await checkAiLimit(c.env, db, userId, "note_processing");

    const summaries = await Promise.all(
      [...batchMap.values()].map(async (batch) => {
        const targetPriorityId = batch.firstLevelPriorityId;
        const threadList = batch.threads.slice(0, 10);
        const displayTitle = batch.priorityTitle === "Everything" ? "Inbox" : batch.priorityTitle;

        const body = aiAllowed.allowed
          ? await generateSummary(c.env, threadList, c.var.user.name, displayTitle, c.var.user.id)
          : fallbackSummary(threadList);

        return {
          first_level_priority_id: batch.firstLevelPriorityId,
          title: displayTitle,
          body,
          target_priority_id: targetPriorityId,
          urgent: batch.urgent,
          thread_ids: threadList.map((t) => t.id),
        };
      })
    );

    if (aiAllowed.allowed) {
      recordAiUsage(c.env, userId, "note_processing");
    }

    // Advance the notification_cleared_at high-water mark for these focuses
    // so we don't re-notify for the same threads.
    for (const batch of batchMap.values()) {
      await sql`
        UPDATE priority
        SET notification_cleared_at = GREATEST(notification_cleared_at, ${batch.maxUpdatedAt.toISOString()})
        WHERE id = ${batch.firstLevelPriorityId}::uuid
          AND user_id = ${userId}::uuid
      `.execute(db);
    }

    return c.json({ summaries });
  } catch (error) {
    return captureServerError(
      c,
      error,
      "Error generating notification content."
    );
  }
});

export default notificationContent;
