import type { User } from "@supabase/supabase-js";

import type { MiddlewareHandler } from "hono";

import { type SupabaseClient, createClient } from "@plotday/db";

import type { Bindings } from "../env";

declare module "hono" {
  interface ContextVariableMap {
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

  // Allow OPTIONS requests through (CORS preflight)
  if (c.req.method === "OPTIONS") {
    return await next();
  }

  let tokens = c.req.header("Authorization");
  if (!tokens?.startsWith("Bearer ")) {
    return new Response("Forbidden", { status: 403 });
  }
  tokens = tokens.replace(/\s*Bearer\s+/, "");
  const [access_token, refresh_token] = tokens?.split("/");
  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_ANON_KEY);
  const session = await supabase.auth.setSession({
    access_token,
    refresh_token,
  });
  const user = session.data?.user;
  if (!user) {
    return new Response("Forbidden", { status: 403 });
  }
  c.set("supabase", supabase);
  c.set("user", user);
  await next();
};
