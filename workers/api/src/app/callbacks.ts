import { Hono } from "hono";

import { Callbacks } from "../twist/tools/callbacks";
import type { Bindings } from "../env";

const callbacks = new Hono<{ Bindings: Bindings }>();

// Callback link endpoint - handles activity link callbacks
callbacks.post("/callback/:token", async (c) => {
  try {
    const token = c.req.param("token");
    if (!token) {
      return new Response("Bad request (missing token)", { status: 400 });
    }

    const link = await c.req.json();
    if (!link) {
      return new Response("Bad request (missing link data)", { status: 400 });
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
    console.error("Error processing link callback:", error);
    return new Response("Internal server error", { status: 500 });
  }
});

export default callbacks;
