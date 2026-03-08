import type { MiddlewareHandler } from "hono";
import { cors } from "hono/cors";

import type { Bindings } from "../env";

/**
 * CORS middleware for app endpoints
 * Skips WebSocket endpoints (/updates)
 */
export const corsMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = (
  c,
  next
) => {
  if (c.req.path.startsWith("/app/updates")) {
    // Skip CORS for WebSocket endpoints
    return next();
  }
  return cors({
    origin: [
      "http://localhost:8788",
      "https://preview.plot.day",
      "https://app.plot.day",
      "https://plot.day",
    ],
  })(c, next);
};
