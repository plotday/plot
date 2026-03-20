import { Hono } from "hono";

import { withUserDb } from "../../db";
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

  await withUserDb(c.var.db, userId, async (trx) => {
    const records = Array.isArray(body) ? body : [body];
    for (const record of records) {
      if (record.read_at) {
        // Mark as read — pass client's read_at so we don't clear unread rows
        // that were created after the client's last sync (new activity from others).
        await rpcUser(trx, "clear_thread_unread", {
          user_id: userId,
          p_thread_id: record.thread_id,
          p_read_at: record.read_at,
          ...(record.bumped_at ? { p_bumped_at: record.bumped_at } : {}),
        });
      } else {
        // Mark as unread
        await rpcUser(trx, "upsert_thread_unread", {
          user_id: userId,
          p_thread_id: record.thread_id,
          p_urgency: record.urgency || "inform-updates",
          ...(record.bumped_at ? { p_bumped_at: record.bumped_at } : {}),
        });
      }
    }
  });

  notifyUserSync(c, userId);

  // Notify TwistSync for source onThreadRead callbacks
  const threadReads = Array.isArray(body) ? body : [body];
  const priorityIds = new Set<string>();
  for (const record of threadReads) {
    try {
      const priorityId = await getPriorityForThread(c.var.db, record.thread_id);
      priorityIds.add(priorityId);
    } catch {
      // Thread may not exist; skip
    }
  }
  for (const priorityId of priorityIds) {
    notifySync(c, priorityId);
  }

  return c.json({ ok: true });
});

export default threadUnread;
