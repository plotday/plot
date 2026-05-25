import { Hono } from "hono";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { notifySync } from "./notify";

const priorityAttention = new Hono<{ Bindings: Bindings }>();

// POST /sync/priority-attention - Set/clear per-priority response-time settings.
//
// Six per-priority keys split into two clearly-labelled mechanisms:
//   - Schedule time to respond: `respond_schedule_enabled` toggle,
//     `respond_window` (active hours) and `respond_within` (response SLA).
//   - Early notifications: `early_notifications_enabled` toggle,
//     `notify_window` (when interruptions are allowed) and `see_within`
//     (max delay before notification fires).
//
// Each value pairs with a `set_*` flag so a partial payload only writes the
// keys the client intended to change; passing a null value with the flag
// clears the override and reverts to the inherited value.
priorityAttention.post("/sync/priority-attention", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  await withUserDb(c.var.db, userId, async (trx) => {
    return rpcUser(trx, "upsert_priority_attention", {
      p_user_id: userId,
      p_priority_id: body.priority_id,
      p_respond_schedule_enabled: body.respond_schedule_enabled ?? null,
      p_set_respond_schedule_enabled: body.set_respond_schedule_enabled ?? false,
      p_respond_window: body.respond_window ?? null,
      p_set_respond_window: body.set_respond_window ?? false,
      p_respond_within: body.respond_within ?? null,
      p_set_respond_within: body.set_respond_within ?? false,
      p_early_notifications_enabled: body.early_notifications_enabled ?? null,
      p_set_early_notifications_enabled: body.set_early_notifications_enabled ?? false,
      p_notify_window: body.notify_window ?? null,
      p_set_notify_window: body.set_notify_window ?? false,
      p_see_within: body.see_within ?? null,
      p_set_see_within: body.set_see_within ?? false,
    });
  });

  notifySync(c, body.priority_id);

  return c.json({ success: true });
});

export default priorityAttention;
