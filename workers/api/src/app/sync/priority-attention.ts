import { Hono } from "hono";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { notifySync } from "./notify";

const priorityAttention = new Hono<{ Bindings: Bindings }>();

// POST /sync/priority-attention - Set/clear attention settings
priorityAttention.post("/sync/priority-attention", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_priority_attention", {
      p_user_id: userId,
      p_priority_id: body.priority_id,
      p_attention_window: body.attention_window ?? null,
      p_set_attention_window: body.set_attention_window ?? false,
      p_see_within_requests: body.see_within_requests ?? null,
      p_see_within_updates: body.see_within_updates ?? null,
      p_set_see_within_requests: body.set_see_within_requests ?? false,
      p_set_see_within_updates: body.set_see_within_updates ?? false,
    });
  });

  notifySync(c, body.priority_id);

  return c.json({ success: true });
});

export default priorityAttention;
