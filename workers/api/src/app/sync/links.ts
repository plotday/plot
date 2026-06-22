import { Hono } from "hono";

import { sql, withUserDb, createFrontendDb } from "../../db";
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
import { twistFactory } from "../../twist/factory";

const links = new Hono<{ Bindings: Bindings }>();

/**
 * Merge the visible (`user.link`) and access-loss (`user.link_redacted`) row
 * sets for a single GET /sync/links page, re-sort across both, and slice to
 * `limit`. Each input is already bounded by `limit` on the server side; the
 * redacted set is typically tiny. Mirrors the inline merge in threads.ts /
 * notes.ts exactly so the page boundary matches the single-view path:
 *   - seq cursor: sort by (seq asc, id asc), seq compared as a decimal string.
 *   - legacy cursor: sort by (updated_at asc, id asc).
 */
export function mergeSeqRows<T extends Record<string, any>>(
  visible: T[],
  redacted: T[],
  useSeqCursor: boolean,
  limit: number,
): T[] {
  const merged = [...visible, ...redacted];
  if (useSeqCursor) {
    merged.sort((a, b) => {
      const as = (a as any).seq ?? "0";
      const bs = (b as any).seq ?? "0";
      if (as !== bs) return as < bs ? -1 : 1;
      const aid = (a as any).id ?? "";
      const bid = (b as any).id ?? "";
      return aid < bid ? -1 : aid > bid ? 1 : 0;
    });
  } else {
    merged.sort((a, b) => {
      const au = (a as any).updated_at ? (a as any).updated_at.getTime() : 0;
      const bu = (b as any).updated_at ? (b as any).updated_at.getTime() : 0;
      if (au !== bu) return au - bu;
      const aid = (a as any).id ?? "";
      const bid = (b as any).id ?? "";
      return aid < bid ? -1 : aid > bid ? 1 : 0;
    });
  }
  return merged.slice(0, limit);
}

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

  // On initial sync (epoch or seq=0), a fresh client has nothing to reconcile,
  // so the access-loss tombstones from user.link_redacted are useless noise.
  // Skip that branch on initial pulls and only query it on incremental syncs,
  // matching the user.thread / user.note redacted-view pattern.
  const isInitialSync = useSeqCursor
    ? seqSince === "0"
    : !updatedSince || updatedSince === "1970-01-01T00:00:00.000Z";

  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    const buildQuery = (view: "user.link" | "user.link_redacted") => {
      let query = trx
        .selectFrom(view as any)
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

      // Priority filter: exact match on the per-user filing (flat model).
      if (priorityId) {
        query = query.where("priority_id", "=", priorityId);
      } else if (priorityPath) {
        query = query.where(
          sql<boolean>`priority_path = ${priorityPath}::ltree`
        );
      }

      // Range filtering on updated_at (scalar)
      if (rangeStart) {
        query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
      }
      if (rangeEnd) {
        query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);
      }

      return query;
    };

    const visible = await buildQuery("user.link").execute();
    const horizonValue = useSeqCursor ? await readSafeHorizon(trx) : "0";

    if (isInitialSync) {
      return { rows: visible, horizon: horizonValue };
    }

    const redacted = await buildQuery("user.link_redacted").execute();
    const merged = mergeSeqRows(visible as any[], redacted as any[], useSeqCursor, limit);
    return { rows: merged, horizon: horizonValue };
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
    // Propagate the active state flag declared on the LinkStatus
    // to per-user thread_state. Best-effort.
    try {
      await propagateLinkStateFlagsFromDb(c.var.db, result);
    } catch {
      // Non-critical
    }
  }

  const assigneeId = result.assignee_id;
  const linkThreadId = result.thread_id;

  // When a link status becomes "done", clear the assignee's thread_state
  // todo intent (mark it read so the row drops out of action tabs). The
  // "has outstanding sub-items" badge in the Flutter app is now derived
  // from note_tag / link state directly.
  if (linkThreadId && linkData.status !== undefined) {
    c.executionCtx.waitUntil(
      (async () => {
        const db = createFrontendDb(c.env);
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
        const db = createFrontendDb(c.env);
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
