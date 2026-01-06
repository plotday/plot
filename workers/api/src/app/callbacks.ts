import { Hono } from "hono";

import { Callbacks } from "../twist/tools/callbacks";
import type { Bindings } from "../env";
import { extractRequestContext } from "../utils/log-context";
import { createLogger } from "../utils/logger";

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

    const result = await Callbacks.HandleLinkCallback(
      c.env.CALLBACKS,
      token,
      link
    );

    if (result) {
      return c.json(result);
    } else {
      return c.json({ success: true });
    }
  } catch (error) {
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Error processing link callback", error as Error, { token });
    return c.json({ message: "Internal server error" }, 500);
  }
});

export default callbacks;
