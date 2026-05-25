import { Hono } from "hono";

import { sql, withUserDb, createDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import {
  parseReadParams,
  readSafeHorizon,
  seqEnvelope,
  seqSinceCursor,
  updatedSinceCursor,
} from "./helpers";
import { getPriorityForThread, notifySync } from "./notify";
import { isLinkStatusDone, propagateLinkStateFlagsFromDb, propagateLinkStatusTagsFromDb } from "./link-tags";
import { createSchedule } from "./smart-schedule";
import { twistFactory } from "../../twist/factory";

const links = new Hono<{ Bindings: Bindings }>();

// GET /sync/links
links.get("/sync/links", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    seqSince,
    pageSeq,
    pageId,
    limit,
    id,
    sortBy,
    sortDir,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
  } = parseReadParams(c);
  const useSeqCursor = seqSince !== null;

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.link" as any)
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort
    if (useSeqCursor) {
      query = query.orderBy("seq", "asc").orderBy("id", "asc");
    } else if (updatedSince) {
      query = query.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc");
    } else {
      query = query.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    }

    query = query.limit(limit);

    // Single-row fetch by ID
    if (id) {
      query = query.where("id", "=", id);
    }

    // Cursor pagination
    if (useSeqCursor) {
      query = query.where(seqSinceCursor(seqSince, pageSeq, pageId));
    } else if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Priority filter (same pattern as threads)
    if (priorityId) {
      query = query.where(
        sql<boolean>`priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`
      );
    } else if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Range filtering on updated_at (scalar)
    if (rangeStart) {
      query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
    }
    if (rangeEnd) {
      query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);
    }

    const fetchedRows = await query.execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";
    return { rows: fetchedRows, horizon: horizonValue };
  });

  if (useSeqCursor) {
    return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  }
  return c.json(rows as any);
});

// POST /sync/links - Upsert via upsert_link() RPC
links.post("/sync/links", async (c) => {
  const body = await c.req.json();

  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    return rpcUser(trx, "upsert_link", {
      user_id: c.var.user.id,
      p_link: (body.link || body) as any,
      p_defaults: (body.defaults || {}) as any,
    });
  });

  // Propagate status tags if the link has a thread and status was included
  const linkData = body.link || body;
  if (result.thread_id && linkData.status !== undefined) {
    try {
      await propagateLinkStatusTagsFromDb(c.var.db, result);
    } catch {
      // Non-critical: tag propagation failure shouldn't break the sync
    }
    // Propagate active/task/toRead state flags declared on the LinkStatus
    // to per-user thread_state. Best-effort.
    try {
      await propagateLinkStateFlagsFromDb(c.var.db, result);
    } catch {
      // Non-critical
    }
  }

  // Create task schedule when link is assigned to a user
  // Uses its own DB connection since the request-scoped one is destroyed after the response
  const assigneeId = result.assignee_id;
  const linkThreadId = result.thread_id;
  if (assigneeId && linkThreadId) {
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          const contact = await db
            .selectFrom("contact")
            .select("user_id")
            .where("id", "=", assigneeId)
            .executeTakeFirst();
          if (!contact?.user_id) return;

          // Only file task=true thread_state if the link's status is not "done"
          const isDone = await isLinkStatusDone(db, result);
          if (!isDone) {
            await createSchedule(db, contact.user_id, linkThreadId, 'task');
          }
        } catch (error) {
          console.error("[thread_state] Failed to file thread_state from link assignment:", error);
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  // When a link status becomes "done", clear the assignee's thread_state
  // todo intent (mark it read so the row drops out of action tabs). The
  // "has outstanding sub-items" badge in the Flutter app is now derived
  // from note_tag / link state directly.
  if (linkThreadId && linkData.status !== undefined) {
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          const isDone = await isLinkStatusDone(db, result);
          if (!isDone) return;

          if (assigneeId) {
            const contact = await db
              .selectFrom("contact")
              .select("user_id")
              .where("id", "=", assigneeId)
              .executeTakeFirst();
            if (contact?.user_id) {
              await db
                .updateTable("thread_state")
                .set({ read_at: new Date() })
                .where("thread_id", "=", linkThreadId)
                .where("user_id", "=", contact.user_id)
                .where("read_at", "is", null)
                .execute();
            }
          } else {
            // Unassigned: clear unread for every user with a state row
            await db
              .updateTable("thread_state")
              .set({ read_at: new Date() })
              .where("thread_id", "=", linkThreadId)
              .where("read_at", "is", null)
              .execute();
          }
        } catch (error) {
          console.error("[thread_state] Failed to clear thread_state on link done:", error);
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  // Notify sync so twist callbacks (e.g. onLinkUpdated) can fire
  if (linkData.thread_id) {
    try {
      const priorityId = await getPriorityForThread(c.var.db, linkData.thread_id, c.var.user.id);
      notifySync(c, priorityId);
    } catch {
      // Thread lookup may fail for orphaned links
    }
  } else if (linkData.priority_id) {
    // Threadless links have priority_id directly
    notifySync(c, linkData.priority_id);
  }

  // Direct dispatch to connector's onLinkUpdated when user changes a connector-owned link.
  // The view-based TwistSync path doesn't cover connectors observing their own links,
  // so we dispatch directly here for immediate feedback.
  // POST /sync/links is only called by the Flutter app, so this is always a user action.
  // Connectors use integrations.saveLink() which goes through a different path.
  if (result.created_by) {
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          // Check if created_by is a connector (has channel rows)
          const isConnector = await db
            .selectFrom("channel")
            .select("twist_instance_id")
            .where("twist_instance_id", "=", result.created_by)
            .limit(1)
            .executeTakeFirst();

          if (!isConnector) return;

          const factory = twistFactory({
            env: c.env,
            ctx: c.executionCtx as any,
            db,
          });

          const twistWrapper = await factory({
            twistInstanceId: result.created_by!,
          });

          await twistWrapper.dispatch("Integrations", {
            itemType: "link" as const,
            item: result,
            isCreate: false,
          });
        } catch (error) {
          console.error("[sync/links] Direct connector dispatch failed:", error);
        } finally {
          await db.destroy();
        }
      })()
    );
  }

  return c.json(result as any);
});

export default links;
