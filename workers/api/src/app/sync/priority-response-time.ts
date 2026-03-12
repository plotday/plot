import { Hono } from "hono";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { notifySync } from "./notify";

const priorityResponseTime = new Hono<{ Bindings: Bindings }>();

// POST /sync/priority-response-time - Set/clear response time settings
priorityResponseTime.post("/sync/priority-response-time", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_priority_response_time", {
      user_id: userId,
      p_priority_id: body.priority_id,
      p_response_window: body.response_window ?? null,
      p_turnaround: body.turnaround ?? null,
      p_set_response_window: body.set_response_window ?? false,
      p_set_turnaround: body.set_turnaround ?? false,
    });
  });

  notifySync(c, body.priority_id);

  return c.json({ success: true });
});

export default priorityResponseTime;
