import { Hono } from "hono";

import type { Bindings } from "../env";

const updates = new Hono<{ Bindings: Bindings }>();

// WebSocket broadcast endpoint
updates.get("/updates/:userId", async (c) => {
  const userId = c.req.param("userId");

  // Get the Broadcast DurableObject for this user
  const broadcastId = c.env.BROADCAST.idFromName(userId);
  const broadcast = c.env.BROADCAST.get(broadcastId);

  // Forward the request to the DurableObject
  return broadcast.fetch(c.req.raw);
});

export default updates;
