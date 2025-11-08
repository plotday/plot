import type { MiddlewareHandler } from "hono";
import type { PostHog } from "posthog-node";

import { type SupabaseClient, createClient } from "@plotday/db";

import type { Bindings } from "../env";

declare module "hono" {
  interface ContextVariableMap {
    postHog: PostHog;
    supabase: SupabaseClient;
    supabaseAdmin: SupabaseClient;
  }
}

/**
 * Authentication middleware for sync endpoints
 * Verifies HMAC signature from database triggers
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

  // Authenticate requests from the DB using HMAC
  const signature = c.req.header("X-Plot-Signature");
  if (!signature || !signature.startsWith("sha256=")) {
    return new Response("Unauthorized: Missing or invalid signature", {
      status: 401,
    });
  }

  let hmacSecret = c.env.API_HMAC_SECRET;
  if (ENV === "development") {
    hmacSecret ??= "dev-not-secret";
  }
  if (!hmacSecret) {
    return new Response("Server configuration error", { status: 500 });
  }

  // Get the raw body for HMAC verification
  const bodyText = await c.req.text();

  // Generate expected signature
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(hmacSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const expectedSignature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(bodyText)
  );

  const expectedHex = Array.from(new Uint8Array(expectedSignature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  const providedHex = signature.slice(7); // Remove "sha256=" prefix
  if (expectedHex !== providedHex) {
    return new Response("Unauthorized: Invalid signature", { status: 401 });
  }

  c.set("supabase", supabaseAdmin);

  return await next();
};
