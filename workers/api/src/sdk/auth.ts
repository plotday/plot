import type { MiddlewareHandler } from "hono";
import type { PostHog } from "posthog-node";

import { createClient } from "@plotday/db";

import type { Bindings } from "../env";

/**
 * Authentication middleware for SDK endpoints
 * Verifies personal access tokens from the token table
 */
export const authMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  // Skip auth for session endpoints (polling and authorize)
  // The path here doesn't include the /v1 prefix since it's already mounted
  if (c.req.path.match(/\/session\//)) {
    return next();
  }

  const authHeader = c.req.header("Authorization");

  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(
      "Unauthorized: Missing or invalid Authorization header",
      {
        status: 401,
      }
    );
  }

  const tokenValue = authHeader.replace("Bearer ", "");

  // Validate token exists and is not deleted
  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);
  const { data: tokenData, error: tokenError } = await supabase
    .from("token")
    .select("id, user_id, publisher_id")
    .eq("token", tokenValue)
    .is("archived_at", null)
    .single();

  if (tokenError || !tokenData) {
    // PGRST116 = "no rows returned" from .single() — legitimate "not found"
    if (!tokenError || tokenError.code === "PGRST116") {
      return new Response("Unauthorized: Invalid or revoked token", {
        status: 401,
      });
    }
    // Transient database error — log and return 503
    console.error("Token lookup failed:", tokenError);
    c.var.postHog?.captureException(
      new Error(`Token lookup failed: ${tokenError.message}`),
      undefined,
      { code: tokenError.code, path: c.req.path }
    );
    return new Response("Service temporarily unavailable", { status: 503 });
  }

  // Update last_used_at
  await supabase
    .from("token")
    .update({ last_used_at: new Date().toISOString() })
    .eq("id", tokenData.id);

  // Handle user tokens
  if (tokenData.user_id) {
    // Fetch user data
    const { data: userData, error: userError } =
      await supabase.auth.admin.getUserById(tokenData.user_id);

    if (userError || !userData?.user) {
      if (userError) {
        // Transient auth service error — log and return 503
        console.error("User lookup failed:", userError);
        c.var.postHog?.captureException(
          new Error(`User lookup failed: ${userError.message}`),
          undefined,
          { code: (userError as any).code, path: c.req.path }
        );
        return new Response("Service temporarily unavailable", { status: 503 });
      }
      return new Response("Unauthorized: User not found", {
        status: 401,
      });
    }

    // Store token and user data in context for the handler
    c.set("userToken", {
      id: tokenData.id,
      user_id: tokenData.user_id!,
      publisher_id: tokenData.publisher_id,
    });
    c.set("user", userData.user);
  }
  // Handle publisher tokens
  else if (tokenData.publisher_id) {
    // Fetch publisher data
    const { data: publisherData, error: publisherError } = await supabase
      .from("publisher")
      .select("id, name, email, url")
      .eq("id", tokenData.publisher_id)
      .single();

    if (publisherError || !publisherData) {
      // PGRST116 = "no rows returned" from .single() — legitimate "not found"
      if (!publisherError || publisherError.code === "PGRST116") {
        return new Response("Unauthorized: Publisher not found", {
          status: 401,
        });
      }
      // Transient database error — log and return 503
      console.error("Publisher lookup failed:", publisherError);
      c.var.postHog?.captureException(
        new Error(`Publisher lookup failed: ${publisherError.message}`),
        undefined,
        { code: publisherError.code, path: c.req.path }
      );
      return new Response("Service temporarily unavailable", { status: 503 });
    }

    // Store token and publisher data in context for the handler
    c.set("publisherToken", {
      id: tokenData.id,
      user_id: tokenData.user_id,
      publisher_id: tokenData.publisher_id!,
    });
    c.set("publisher", publisherData);
  } else {
    return new Response("Unauthorized: Invalid token configuration", {
      status: 401,
    });
  }

  await next();
};

declare module "hono" {
  interface ContextVariableMap {
    postHog: PostHog;
    userToken: {
      id: string;
      user_id: string;
      publisher_id: number | null;
    };
    publisherToken: {
      id: string;
      user_id: string | null;
      publisher_id: number;
    };
    publisher: {
      id: number;
      name: string;
      email: string | null;
      url: string | null;
    };
  }
}
