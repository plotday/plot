import type { Kysely } from "kysely";
import type { MiddlewareHandler } from "hono";

import { type DB, createDb } from "../db";
import type { Bindings } from "../env";
import type { AuthUser } from "../utils/auth";
import type { Tracker } from "../utils/tracker";

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
  const db = createDb(c.env);
  c.set("db", db);

  let tokenData;
  try {
    tokenData = await db
      .selectFrom("token")
      .select(["id", "user_id", "publisher_id"])
      .where("token", "=", tokenValue)
      .where("archived_at", "is", null)
      .executeTakeFirst();
  } catch (error) {
    // Transient database error — log and return 503
    console.error("Token lookup failed:", error);
    c.var.tracker?.captureException(
      new Error(`Token lookup failed: ${error instanceof Error ? error.message : "Unknown error"}`),
      { path: c.req.path }
    );
    return new Response("Service temporarily unavailable", { status: 503 });
  }

  if (!tokenData) {
    return new Response("Unauthorized: Invalid or revoked token", {
      status: 401,
    });
  }

  // Update last_used_at
  await db
    .updateTable("token")
    .set({ last_used_at: new Date().toISOString() })
    .where("id", "=", tokenData.id)
    .execute();

  // Handle user tokens
  if (tokenData.user_id) {
    // Fetch user data from public."user" table
    let userData;
    try {
      userData = await db
        .selectFrom("user")
        .select(["id", "email", "name", "clerk_id"])
        .where("id", "=", tokenData.user_id)
        .executeTakeFirst();
    } catch (error) {
      // Transient database error — log and return 503
      console.error("User lookup failed:", error);
      c.var.tracker?.captureException(
        new Error(`User lookup failed: ${error instanceof Error ? error.message : "Unknown error"}`),
        { path: c.req.path }
      );
      return new Response("Service temporarily unavailable", { status: 503 });
    }

    if (!userData) {
      return new Response("Unauthorized: User not found", {
        status: 401,
      });
    }

    // Store token and user data in context for the handler
    c.set("userToken", {
      id: tokenData.id,
      user_id: tokenData.user_id!,
      publisher_id: tokenData.publisher_id ? Number(tokenData.publisher_id) : null,
    });
    c.set("user", {
      id: userData.id,
      clerkId: userData.clerk_id ?? "",
      email: userData.email,
      name: userData.name,
    });
  }
  // Handle publisher tokens
  else if (tokenData.publisher_id) {
    // Fetch publisher data
    let publisherData;
    try {
      publisherData = await db
        .selectFrom("publisher")
        .select(["id", "name", "email", "url"])
        .where("id", "=", tokenData.publisher_id)
        .executeTakeFirst();
    } catch (error) {
      // Transient database error — log and return 503
      console.error("Publisher lookup failed:", error);
      c.var.tracker?.captureException(
        new Error(`Publisher lookup failed: ${error instanceof Error ? error.message : "Unknown error"}`),
        { path: c.req.path }
      );
      return new Response("Service temporarily unavailable", { status: 503 });
    }

    if (!publisherData) {
      return new Response("Unauthorized: Publisher not found", {
        status: 401,
      });
    }

    // Store token and publisher data in context for the handler
    c.set("publisherToken", {
      id: tokenData.id,
      user_id: tokenData.user_id,
      publisher_id: Number(tokenData.publisher_id!),
    });
    c.set("publisher", {
      ...publisherData,
      id: Number(publisherData.id),
    });
  } else {
    return new Response("Unauthorized: Invalid token configuration", {
      status: 401,
    });
  }

  await next();
};

declare module "hono" {
  interface ContextVariableMap {
    tracker: Tracker;
    db: Kysely<DB>;
    user: AuthUser;
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
