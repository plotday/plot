import { Hono } from "hono";

import type { Bindings } from "../env";
import { refreshAllChannels } from "../scheduled/refresh-channels";
import { createLogger } from "@plotday/worker-util";

const admin = new Hono<{ Bindings: Bindings }>();

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

admin.use("/admin/*", async (c, next) => {
  const expected = c.env.ADMIN_API_KEY;
  if (!expected) {
    return c.json({ error: "Admin API not configured" }, 503);
  }
  const header = c.req.header("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const provided = header.slice("Bearer ".length);
  if (!timingSafeEqual(provided, expected)) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  return next();
});

// Re-runs the same daily sweep that the cron triggers at 05:00 UTC. Iterates
// every active twist_instance_connection, calls refreshChannels per row, which
// goes through getActorToken — broken connections get flagged with
// twist_instance_connection.needs_reauth_at as a side effect.
admin.post("/admin/refresh-channels", async (c) => {
  const logger = createLogger({ operation: "adminRefreshChannels" });
  const startedAt = Date.now();
  try {
    await refreshAllChannels(c.env, c.executionCtx as unknown as ExecutionContext);
    return c.json({
      ok: true,
      durationMs: Date.now() - startedAt,
    });
  } catch (error) {
    logger.error("admin refresh-channels failed", error as Error);
    c.var.tracker?.captureException(error as Error, {
      operation: "adminRefreshChannels",
    });
    return c.json(
      {
        ok: false,
        error: (error as Error).message,
        durationMs: Date.now() - startedAt,
      },
      500
    );
  }
});

export default admin;
