import type { MiddlewareHandler } from "hono";
import type { PostHog } from "posthog-node";
import type { Kysely } from "kysely";

import { type DB, createDb } from "../db";
import type { Bindings } from "../env";
import { type AuthUser, getUser } from "../utils/auth";

declare module "hono" {
  interface ContextVariableMap {
    postHog: PostHog;
    db: Kysely<DB>;
    user: AuthUser;
  }
}

/**
 * Authentication middleware for sync endpoints
 * Verifies Bearer token from authenticated clients
 */
export const syncAuthMiddleware: MiddlewareHandler<{
  Bindings: Bindings;
}> = async (c, next) => {
  c.set("db", createDb(c.env));

  // Allow OPTIONS requests through (CORS preflight)
  if (c.req.method === "OPTIONS") {
    return await next();
  }

  const authHeader = c.req.header("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response("Unauthorized: Missing Bearer token", { status: 401 });
  }

  const access_token = authHeader.replace(/\s*Bearer\s+/, "");

  // Validate Clerk JWT using local PEM key (no network call)
  const { user } = await getUser(
    c.var.db,
    access_token,
    c.env.CLERK_JWT_KEY
  );
  if (!user) {
    return new Response("Unauthorized: Invalid token", { status: 401 });
  }

  c.set("user", user);
  return await next();
};
