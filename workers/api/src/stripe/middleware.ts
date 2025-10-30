import type { MiddlewareHandler } from "hono";

import { createClient } from "@plotday/db";

import type { Bindings } from "../env";

/**
 * Middleware for Stripe endpoints
 * Sets up Supabase client for database access
 * Integrations is handled via Stripe signature verification in the endpoint
 */
export const stripeMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  const supabaseAdmin = createClient(
    c.env.SUPABASE_URL,
    c.env.SUPABASE_SERVICE_KEY
  );
  c.set("supabaseAdmin", supabaseAdmin);
  c.set("supabase", supabaseAdmin);

  await next();
};
