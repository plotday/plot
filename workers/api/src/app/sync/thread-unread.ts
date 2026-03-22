import { Hono } from "hono";

import { mapPgError } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { notifySync, notifyUserSync, getPriorityForThread } from "./notify";

const threadUnread = new Hono<{ Bindings: Bindings }>();

// POST /sync/thread-unread - Mark thread read or unread
// read_at present → mark read (clear_thread_unread)
// urgency present, no read_at → mark unread (upsert_thread_unread)
threadUnread.post("/sync/thread-unread", async (c) => {
  const body = await c.req.json();
  const userId = c.var.user.id;
  const records = Array.isArray(body) ? body : [body];

  const failed: string[] = [];
  const succeededThreadIds: string[] = [];

  for (const record of records) {
    try {
      if (record.read_at) {
        await rpcUser(c.var.db, "clear_thread_unread", {
          user_id: userId,
          p_thread_id: record.thread_id,
          p_read_at: record.read_at,
          ...(record.bumped_at ? { p_bumped_at: record.bumped_at } : {}),
        });
      } else {
        await rpcUser(c.var.db, "upsert_thread_unread", {
          user_id: userId,
          p_thread_id: record.thread_id,
          p_urgency: record.urgency || "inform-updates",
          ...(record.bumped_at ? { p_bumped_at: record.bumped_at } : {}),
        });
      }
      succeededThreadIds.push(record.thread_id);
    } catch (err) {
      if (mapPgError(err)) {
        failed.push(record.thread_id);
      } else {
        throw err;
      }
    }
  }

  notifyUserSync(c, userId);

  // Notify TwistSync for source onThreadRead callbacks (only for successful records)
  const priorityIds = new Set<string>();
  for (const threadId of succeededThreadIds) {
    try {
      const priorityId = await getPriorityForThread(c.var.db, threadId);
      priorityIds.add(priorityId);
    } catch {
      // Thread may not exist; skip
    }
  }
  for (const priorityId of priorityIds) {
    notifySync(c, priorityId);
  }

  if (failed.length > 0) {
    return c.json({ ok: true, failed });
  }
  return c.json({ ok: true });
});

export default threadUnread;
