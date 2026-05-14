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
    origin: (origin) => {
      // Static allowlist for first-party web origins.
      if (
        origin === "http://localhost:5173" ||
        origin === "http://localhost:8788" ||
        origin === "https://preview.plot.day" ||
        origin === "https://app.plot.day" ||
        origin === "https://plot.day"
      ) {
        return origin;
      }
      // Browser extensions (Chrome, Edge, Firefox) — auth is bearer-token only
      // so there's no cookie-credentials exposure from allowing any extension
      // origin: a request still requires a valid Clerk JWT signed for our
      // instance to reach a handler.
      if (origin?.startsWith("chrome-extension://")) return origin;
      if (origin?.startsWith("moz-extension://")) return origin;
      return null;
    },
  })(c, next);
};
