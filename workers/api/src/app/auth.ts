import type { Kysely } from "kysely";
import type { MiddlewareHandler } from "hono";

import { type DB, createDb } from "../db";
import type { Bindings } from "../env";
import { type AuthUser, type ClerkClaims, getUser } from "../utils/auth";
import type { Tracker } from "../utils/tracker";

declare module "hono" {
  interface ContextVariableMap {
    tracker: Tracker;
    db: Kysely<DB>;
    user: AuthUser;
    /** Set when JWT is valid but user doesn't exist in DB (new user hitting /activate). */
    clerkClaims: ClerkClaims;
  }
}

/**
 * Authentication middleware for app endpoints
 * Handles Clerk Bearer token verification
 * Special handling for WebSocket endpoints (/updates)
 */
export const authMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  c.set("db", createDb(c.env));

  // WebSocket protocol doesn't support custom headers, so we're using the
  // Sec-WebSocket-Protocol method, checked in the handler.
  if (c.req.path.startsWith("/app/updates")) {
    return next();
  }

  // Allow OAuth token exchange (codes are single-use, exchange requires server-side secret)
  if (c.req.path === "/app/auth" && c.req.method === "POST") {
    return next();
  }

  // Allow invitation lookup without auth (no user identity needed)
  if (c.req.path.startsWith("/app/invitation/") && c.req.method === "GET") {
    return next();
  }

  // Allow OPTIONS requests through (CORS preflight)
  if (c.req.method === "OPTIONS") {
    return await next();
  }

  const authHeader = c.req.header("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    console.warn(`Auth rejected: missing Bearer token on ${c.req.method} ${c.req.path}`);
    return c.json({ message: "Unauthorized" }, 401);
  }
  const access_token = authHeader.replace(/\s*Bearer\s+/, "");

  // Validate Clerk JWT using local PEM key (no network call)
  const { user, claims, error } = await getUser(
    c.var.db,
    access_token,
    c.env.CLERK_JWT_KEY
  );

  if (user) {
    c.set("user", user);
    return next();
  }

  // JWT was valid but user doesn't exist in DB — allow /activate to create them.
  if (claims && c.req.path === "/app/activate" && c.req.method === "POST") {
    c.set("clerkClaims", claims);
    return next();
  }

  console.warn(
    `Auth rejected on ${c.req.method} ${c.req.path}:`,
    error ? `JWT error: ${error}` : "no user and no claims"
  );
  return c.json({ message: "Unauthorized" }, 401);
};
