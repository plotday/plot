import type { User } from "@supabase/supabase-js";

import type { MiddlewareHandler } from "hono";
import type { PostHog } from "posthog-node";

import { type SupabaseClient, createClient } from "@plotday/db";

import type { Bindings } from "../env";
import { getUser } from "../utils/auth";

declare module "hono" {
  interface ContextVariableMap {
    postHog: PostHog;
    supabase: SupabaseClient;
    supabaseAdmin: SupabaseClient;
    user: User;
  }
}

/**
 * Authentication middleware for app endpoints
 * Handles Supabase Bearer token verification
 * Special handling for WebSocket endpoints (/updates)
 */
export const authMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  const supabaseAdmin = createClient(
    c.env.SUPABASE_URL,
    c.env.SUPABASE_SERVICE_KEY
  );
  c.set("supabaseAdmin", supabaseAdmin);

  // WebSocket protocol doesn't support custom headers, so we're using the
  // Sec-WebSocket-Protocol method, checked in the handler.
  if (c.req.path.startsWith("/app/updates")) {
    return next();
  }

  // Allow public auth endpoints (no authentication required)
  if (c.req.path === "/app/auth/send-code" && c.req.method === "POST") {
    return next();
  }

  // Allow OAuth token exchange (codes are single-use, exchange requires server-side secret)
  if (c.req.path === "/app/auth" && c.req.method === "POST") {
    return next();
  }

  // Allow invitation lookup without auth (uses supabaseAdmin, no user identity needed)
  if (c.req.path.startsWith("/app/invitation/") && c.req.method === "GET") {
    return next();
  }

  // Allow OPTIONS requests through (CORS preflight)
  if (c.req.method === "OPTIONS") {
    return await next();
  }

  const authHeader = c.req.header("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return c.json({ message: "Unauthorized" }, 401);
  }
  const access_token = authHeader.replace(/\s*Bearer\s+/, "");

  // Validate JWT via getClaims — rejects expired tokens without ever
  // consuming the client's refresh token (unlike setSession)
  const { user, error } = await getUser(supabaseAdmin, access_token);
  if (error || !user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  // Create Supabase client with the user's token for RLS
  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_ANON_KEY, {
    global: {
      headers: { Authorization: `Bearer ${access_token}` },
    },
  });

  c.set("supabase", supabase);
  c.set("user", user as unknown as User);
  await next();
};
