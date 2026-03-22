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

    // Get all unread non-passive threads with their priority paths.
    // Excludes archived threads, draft threads (unless created by this user),
    // and private threads the user can't see.
    const threadsResult = await sql<{
      urgency: string;
      thread_id: string;
      thread_title: string | null;
      thread_preview: string | null;
      priority_id: string;
      priority_path: string;
      priority_title: string;
    }>`
      SELECT
        tu.urgency,
        t.id::text AS thread_id,
        t.title AS thread_title,
        t.preview AS thread_preview,
        p.id::text AS priority_id,
        p.path::text AS priority_path,
        p.title AS priority_title
      FROM thread_unread tu
      JOIN thread t ON t.id = tu.thread_id
      JOIN priority p ON p.id = t.priority_id
      WHERE tu.user_id = ${userId}::uuid
        AND tu.read_at IS NULL
        AND tu.urgency != 'passive'
        AND t.archived_at IS NULL
        AND (t.draft = false OR t.created_by = ${userId}::uuid)
        AND (
          t.private = false
          OR t.created_by = ${userId}::uuid
          OR "user".mentioned_in_thread(${userId}::uuid, t.id)
        )
      ORDER BY CASE tu.urgency
        WHEN 'interrupt' THEN 0
        WHEN 'inform-requests' THEN 1
        WHEN 'inform-updates' THEN 2
        ELSE 3
      END ASC
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

    const urgencyRank: Record<string, number> = {
      interrupt: 0,
      "inform-requests": 1,
      "inform-updates": 2,
      passive: 3,
    };

    type BatchData = {
      firstLevelPriorityId: string;
      priorityTitle: string;
      threads: Array<{
        id: string;
        title: string | null;
        preview: string | null;
      }>;
      highestUrgency: string;
      priorityPaths: string[];
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
          highestUrgency: "inform-updates",
          priorityPaths: [],
        };
        batchMap.set(firstLevelPath, batch);
      }

      batch.threads.push({
        id: row.thread_id,
        title: row.thread_title,
        preview: row.thread_preview,
      });
      batch.priorityPaths.push(row.priority_path);

      if (
        (urgencyRank[row.urgency] ?? 4) <
        (urgencyRank[batch.highestUrgency] ?? 4)
      ) {
        batch.highestUrgency = row.urgency;
      }
    }

    if (batchMap.size === 0) {
      return c.json({ summaries: [] });
    }

    // Compute LCA paths and look up their priority IDs
    const lcaPathSet = new Set<string>();
    for (const [firstLevelPath, batch] of batchMap) {
      lcaPathSet.add(computeLcaPath(batch.priorityPaths, firstLevelPath));
    }

    const lcaResult = await sql<{ id: string; path: string }>`
      SELECT id::text AS id, path::text AS path
      FROM priority
      WHERE path::text = ANY(${[...lcaPathSet]})
    `.execute(db);

    const priorityIdByPath = new Map<string, string>();
    for (const row of lcaResult.rows) {
      priorityIdByPath.set(row.path, row.id);
    }
    // Ensure first-level paths are also in the map as fallbacks
    for (const [path, info] of firstLevelByPath) {
      if (!priorityIdByPath.has(path)) {
        priorityIdByPath.set(path, info.id);
      }
    }

    // Check AI usage limit
    const aiAllowed = await checkAiLimit(c.env, db, userId, "note_processing");

    const summaries = await Promise.all(
      [...batchMap.entries()].map(async ([firstLevelPath, batch]) => {
        const lcaPath = computeLcaPath(batch.priorityPaths, firstLevelPath);
        const targetPriorityId =
          priorityIdByPath.get(lcaPath) ?? batch.firstLevelPriorityId;
        const threadList = batch.threads.slice(0, 10);

        const body = aiAllowed.allowed
          ? await generateSummary(c.env, threadList, c.var.user.name, batch.priorityTitle)
          : fallbackSummary(threadList);

        return {
          first_level_priority_id: batch.firstLevelPriorityId,
          title: batch.priorityTitle,
          body,
          target_priority_id: targetPriorityId,
          urgency: batch.highestUrgency,
          thread_ids: threadList.map((t) => t.id),
        };
      })
    );

    if (aiAllowed.allowed) {
      recordAiUsage(c.env, userId, "note_processing");
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

/** Compute lowest common ancestor path for a set of ltree paths. */
export function computeLcaPath(paths: string[], fallback: string): string {
  if (paths.length === 0) return fallback;
  if (paths.length === 1) return paths[0];

  const segments = paths.map((p) => p.split("."));
  const minLength = Math.min(...segments.map((s) => s.length));

  let commonLength = 0;
  for (let i = 0; i < minLength; i++) {
    const seg = segments[0][i];
    if (segments.every((s) => s[i] === seg)) {
      commonLength = i + 1;
    } else {
      break;
    }
  }

  if (commonLength === 0) return fallback;
  return segments[0].slice(0, commonLength).join(".");
}

export default notificationContent;
