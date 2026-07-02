import { Hono } from "hono";

import { Callbacks } from "../twist/tools/callbacks";
import type { Bindings } from "../env";
import { captureServerError } from "../utils/error-capture";

const callbacks = new Hono<{ Bindings: Bindings }>();

// Callback link endpoint - handles activity link callbacks
callbacks.post("/callback/:token", async (c) => {
  try {
    const token = c.req.param("token");
    if (!token) {
      return c.json({ message: "Bad request (missing token)" }, 400);
    }

    const link = await c.req.json();
    if (!link) {
      return c.json({ message: "Bad request (missing link data)" }, 400);
    }

    // The route runs behind appAuthMiddleware, so c.var.user is the
    // authenticated approver. Plumbed through so the plan branch can enforce
    // owner-only execution of server-stored plans.
    using result = await Callbacks.HandleLinkCallback(
      c.env,
      c.executionCtx as unknown as { exports: ExecutionContext["exports"] },
      token,
      link,
      c.var.user?.id ?? null
    );

    if (result) {
      return c.json(result);
    } else {
      return c.json({ success: true });
    }
  } catch (error) {
    return captureServerError(c, error, "Internal server error", { token: c.req.param("token") });
  }
});

export default callbacks;
