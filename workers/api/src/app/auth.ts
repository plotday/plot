import type { Kysely } from "kysely";
import type { MiddlewareHandler } from "hono";

import type { DB } from "../db";
import type { Bindings } from "../env";
import { type AuthUser, type ClerkClaims, getUser } from "../utils/auth";
import type { Tracker } from "../utils/tracker";

declare module "hono" {
  interface ContextVariableMap {
    tracker: Tracker;
    db: Kysely<DB>;
    user: AuthUser;
    /** Verified Clerk JWT claims. Set whenever the JWT verifies, regardless of
     * whether the DB user exists (new users hitting /activate, existing users
     * on any endpoint that wants to read fresh Clerk-side fields like avatar). */
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
  // WebSocket protocol doesn't support custom headers, so we're using the
  // Sec-WebSocket-Protocol method, checked in the handler.
  if (c.req.path.startsWith("/app/updates")) {
    return next();
  }

  // Allow OAuth token exchange (codes are single-use, exchange requires server-side secret)
  if (c.req.path === "/app/auth" && c.req.method === "POST") {
    return next();
  }

  // Allow OAuth URL generation (no sensitive data, just generates redirect URLs with state + PKCE)
  if (c.req.path === "/app/auth" && c.req.method === "GET") {
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
  const { user, claims, dbUnavailable } = await getUser(
    c.var.db,
    access_token,
    c.env.CLERK_JWT_KEY
  );

  if (user) {
    c.set("user", user);
    if (claims) c.set("clerkClaims", claims);
    return next();
  }

  // JWT verified but the DB was unreachable while looking up the user (e.g.
  // Postgres restarting / in recovery). This is transient and unrelated to the
  // user's credentials — return 503 so the client retries with backoff. A 401
  // here would make the app treat a brief DB blip as a dead session and sign
  // the user out (the local-first app should ride out a server outage).
  if (dbUnavailable) {
    console.warn(
      `Auth deferred on ${c.req.method} ${c.req.path}: DB unavailable during user lookup`
    );
    return c.json({ message: "Service Unavailable" }, 503);
  }

  // JWT was valid but user doesn't exist in DB — allow /activate to create them.
  if (claims && c.req.path === "/app/activate" && c.req.method === "POST") {
    c.set("clerkClaims", claims);
    return next();
  }

  if (claims) {
    // JWT was valid but the user row is missing from the DB. This is unrecoverable
    // without re-activation (e.g. DB reset, account deletion). Signal the client
    // to sign out immediately rather than retrying indefinitely.
    console.warn(
      `Auth rejected on ${c.req.method} ${c.req.path}: JWT valid but no DB user`,
      { clerkId: claims.clerkId }
    );
    return c.json({ message: "Unauthorized", code: "user_not_found" }, 401);
  }

  console.warn(
    `Auth rejected on ${c.req.method} ${c.req.path}: JWT error (see above)`
  );
  return c.json({ message: "Unauthorized" }, 401);
};
