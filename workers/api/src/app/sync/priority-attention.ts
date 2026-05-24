import { Hono } from "hono";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { notifySync } from "./notify";

const priorityAttention = new Hono<{ Bindings: Bindings }>();

// POST /sync/priority-attention - Set/clear per-priority attention settings.
//
// `see_within` is a single delay applied to non-urgent notifications. Items
// flagged urgent fire immediately regardless. The legacy split between
// see_within_requests and see_within_updates was retired with the move to
// the action_type taxonomy.
priorityAttention.post("/sync/priority-attention", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_priority_attention", {
      p_user_id: userId,
      p_priority_id: body.priority_id,
      p_attention_window: body.attention_window ?? null,
      p_set_attention_window: body.set_attention_window ?? false,
      p_see_within: body.see_within ?? null,
      p_set_see_within: body.set_see_within ?? false,
    });
  });

  notifySync(c, body.priority_id);

  return c.json({ success: true });
});

export default priorityAttention;
