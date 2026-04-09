import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { checkAiLimit, recordAiUsage } from "../../utils/ai-limits";
import { loadBuiltinProviderConfig, summarizeWithProvider } from "../../utils/ai-provider";
import { cleanTitle } from "../../twist/tools/plot/thread";
import { titleFromContent, createPreviewFromMarkdown } from "../../twist/tools/plot/thread-helpers";
import { summarize } from "../summary";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { notifySync } from "./notify";

const threads = new Hono<{ Bindings: Bindings }>();

// GET /sync/threads
threads.get("/sync/threads", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
    initial,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.thread")
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort: use custom sort when not doing cursor pagination
    if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      // When sorting by agenda_at (a tstzrange), sort by its lower bound
      const sortExpr = sortBy === 'agenda_at' ? sql`lower(agenda_at)` : sql.ref(sortBy);
      query = query.orderBy(sortExpr, sortDir).orderBy("id", sortDir);
    }

    // Don't apply limit for initial pulls
    if (!initial) {
      query = query.limit(limit);
    }

    // Single-row fetch by ID
    if (id) {
      query = query.where("id", "=", id);
    }

    // Cursor pagination (uses date_trunc to match JS Date millisecond precision)
    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Initial pull: fetch unread non-archived threads
    if (initial && archived !== true) {
      query = query.where(
        sql<boolean>`(archived_at IS NULL AND draft = false AND unread = true)`
      );
    } else {
      // Archived filter (only when not initial)
      if (archived === true) {
        query = query.where("archived_at", "is not", null);
      } else if (archived === false) {
        query = query.where("archived_at", "is", null);
      }
    }

    // Priority filter: prefer ID-based lookup, fall back to path for backward compatibility
    if (priorityId) {
      query = query.where(
        sql<boolean>`priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`
      );
    } else if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Range filtering (for pullTo pagination by sortBy column)
    if (sortBy === 'agenda_at') {
      // agenda_at is a tstzrange — use overlap (&&) operator
      if (rangeStart && rangeEnd) {
        query = query.where(sql<boolean>`agenda_at && tstzrange(${rangeStart}::timestamptz, ${rangeEnd}::timestamptz)`);
      } else if (rangeStart) {
        query = query.where(sql<boolean>`agenda_at && tstzrange(${rangeStart}::timestamptz, NULL)`);
      } else if (rangeEnd) {
        query = query.where(sql<boolean>`agenda_at && tstzrange(NULL, ${rangeEnd}::timestamptz)`);
      }
    } else {
      // Scalar comparison for activity_at, created_at, updated_at
      if (rangeStart) {
        query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
      }
      if (rangeEnd) {
        query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);
      }
    }

    return query.execute();
  });

  const apiVersion = c.var.apiVersion ?? 0;

  // For old clients (version < 1): translate access/access_contacts back to private/mentions
  if (apiVersion < 1) {
    for (const row of rows as any[]) {
      row.private = row.access !== 'public';
      // Merge access_contacts into synthetic mentions field for backwards compat
      row.mentions = row.access_contacts ?? [];
    }
  }

  return c.json(rows as any);
});

// POST /sync/threads - Upsert via upsert_thread() RPC
threads.post("/sync/threads", async (c) => {
  const body = await c.req.json();
  const apiVersion = c.var.apiVersion ?? 0;

  const threadData = body.thread || body;

  // For old clients (version < 1): translate private → access/access_contacts
  if (apiVersion < 1 && 'private' in threadData) {
    if (threadData.private === true) {
      // Private thread: check if priority has viewers to determine access level
      // For priorities with viewers, use 'private'; otherwise use 'members'
      if (threadData.priority_id) {
        const hasViewers = await c.var.db
          .selectFrom("priority_user")
          .select("user_id")
          .where("priority_id", "=", threadData.priority_id)
          .where("role", "=", "viewer")
          .where("archived_at", "is", null)
          .executeTakeFirst();
        threadData.access = hasViewers ? 'members' : 'members';
      } else {
        threadData.access = 'members';
      }
    } else {
      // Public thread: check if priority has viewers
      if (threadData.priority_id) {
        const hasViewers = await c.var.db
          .selectFrom("priority_user")
          .select("user_id")
          .where("priority_id", "=", threadData.priority_id)
          .where("role", "=", "viewer")
          .where("archived_at", "is", null)
          .executeTakeFirst();
        threadData.access = hasViewers ? 'public' : 'members';
      } else {
        threadData.access = 'members';
      }
    }
    // Old clients don't send access_contacts, so leave it unset (existing value preserved by JSONB upsert)
    delete threadData.private;
  }

  if (threadData.title && typeof threadData.title === "string") {
    threadData.title = cleanTitle(threadData.title);
  }

  // Generate AI title when client sends title=null with preview content
  if (
    !threadData.title &&
    threadData.preview &&
    typeof threadData.preview === "string" &&
    threadData.draft !== true
  ) {
    try {
      const aiAllowed = await checkAiLimit(c.env, c.var.db, c.var.user.id, "note_processing");
      if (aiAllowed.allowed) {
        const providerConfig = await loadBuiltinProviderConfig(c.var.db, c.var.user.id, c.env);
        let aiTitle: string | null = null;

        if (providerConfig) {
          aiTitle = await summarizeWithProvider(providerConfig, threadData.preview);
        }
        if (!aiTitle) {
          const result = await summarize(c.env.AI, threadData.preview);
          aiTitle = result.title;
        }

        if (aiTitle) {
          recordAiUsage(c.env, c.var.user.id, "note_processing");
          threadData.title = aiTitle;
        }
      }
    } catch (error) {
      console.error("[sync/threads] AI title generation failed:", error);
      c.var.tracker.captureException(error as Error);
    }

    // Fallback: derive title from content if AI didn't produce one
    if (!threadData.title) {
      threadData.title = titleFromContent(threadData.preview) ?? "Untitled";
    }

    // Truncate preview for storage now that title is set
    threadData.preview = createPreviewFromMarkdown(threadData.preview);
  }

  // Always truncate oversized preview (e.g. client set title via /summary but preview is still full content)
  if (threadData.preview && typeof threadData.preview === "string" && threadData.preview.length > 200) {
    threadData.preview = createPreviewFromMarkdown(threadData.preview);
  }

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_thread", {
      user_id: c.var.user.id,
      p_thread: threadData as any,
      p_defaults: (body.defaults || {}) as any,
    });
  });

  notifySync(c, threadData.priority_id);

  return c.json(result as any);
});

export default threads;
