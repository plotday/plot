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

  // Allow invitation lookup without auth (uses supabaseAdmin, no user identity needed)
  if (c.req.path.startsWith("/app/invitation/") && c.req.method === "GET") {
    return next();
  }

  // Allow OPTIONS requests through (CORS preflight)
  if (c.req.method === "OPTIONS") {
    return await next();
  }

  let tokens = c.req.header("Authorization");
  if (!tokens?.startsWith("Bearer ")) {
    return c.json({ message: "Unauthorized" }, 401);
  }
  tokens = tokens.replace(/\s*Bearer\s+/, "");
  const [access_token, refresh_token] = tokens?.split("/");
  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_ANON_KEY);

  // Validate JWT locally before calling setSession to avoid consuming
  // the client's refresh token on expired access tokens
  const { error } = await getUser(supabase, access_token);
  if (error) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  // JWT is valid — setSession won't attempt a refresh
  const session = await supabase.auth.setSession({
    access_token,
    refresh_token: refresh_token ?? "",
  });
  const user = session.data?.user;
  if (!user) {
    return c.json({ message: "Unauthorized" }, 401);
  }

  c.set("supabase", supabase);
  c.set("user", user);
  await next();
};
