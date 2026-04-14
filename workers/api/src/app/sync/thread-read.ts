import { Hono } from "hono";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { notifySync, notifyUserSync, getPriorityForThread } from "./notify";

const threadRead = new Hono<{ Bindings: Bindings }>();

// POST /sync/thread-read - Upsert read records
threadRead.post("/sync/thread-read", async (c) => {
  const body = await c.req.json();
  const userId = c.var.user.id;

  await withUserDb(c.var.db, userId, async (trx) => {
    const records = Array.isArray(body) ? body : [body];
    for (const record of records) {
      await rpcUser(trx, "upsert_thread_read", {
        user_id: userId,
        p_thread_id: record.thread_id,
        p_read_at: record.read_at,
        p_bumped_at: record.bumped_at || null,
      });
    }
  });

  notifyUserSync(c, userId);

  // Notify TwistSync for source onThreadRead callbacks
  const threadReads = Array.isArray(body) ? body : [body];
  const priorityIds = new Set<string>();
  for (const record of threadReads) {
    try {
      const priorityId = await getPriorityForThread(c.var.db, record.thread_id, c.var.user.id);
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

// DELETE /sync/thread-read - Delete read records
threadRead.delete("/sync/thread-read", async (c) => {
  const userId = c.var.user.id;
  const threadId = c.req.query("thread_id");

  if (!threadId) {
    return c.json({ error: "thread_id is required" }, 400);
  }

  await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await rpcUser(trx, "delete_thread_read", {
      user_id: userId,
      p_thread_id: threadId,
    });
  });

  notifyUserSync(c, userId);

  return c.json({ ok: true });
});

export default threadRead;
