import * as crypto from "crypto";
import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { getUser } from "../utils/auth";
import { handleValidationError } from "../utils/validation";
import { createLogger } from "@plotday/worker-util";
import { tokenCreationRateLimiter } from "../middleware/rate-limit";

const tokens = new Hono<{ Bindings: Bindings }>();

const CreateTokenSchema = z.object({
  name: z.string().optional(),
});

const AuthorizeSessionSchema = z.object({
  sessionId: z.string().uuid(),
});

// POST /token - Create new token (requires authentication)
// Apply strict rate limiting (10 req/hour)
tokens.post("/token", tokenCreationRateLimiter, async (c) => {
  const userId = c.var.user?.id;
  if (!userId) {
    return new Response("Unauthorized", { status: 401 });
  }

  const rawBody = await c.req.json();
  const parseResult = CreateTokenSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { name } = parseResult.data;

  // Generate cryptographically secure token
  const tokenValue = crypto.randomBytes(32).toString("hex");

  // Store token in database
  const db = c.var.db;
  try {
    const token = await db
      .insertInto("token")
      .values({
        user_id: userId,
        token: tokenValue,
        name: name || null,
      })
      .returningAll()
      .executeTakeFirstOrThrow();

    return c.json({ token: tokenValue, id: token.id });
  } catch (error) {
    const logger = createLogger();
    logger.error("Error creating token", error as Error, { user_id: userId });
    return new Response(
      `Error creating token: ${error instanceof Error ? error.message : "Unknown error"}`,
      { status: 500 }
    );
  }
});

// GET /tokens - List user's tokens (requires authentication)
tokens.get("/tokens", async (c) => {
  const userId = c.var.user?.id;
  if (!userId) {
    return new Response("Unauthorized", { status: 401 });
  }

  const db = c.var.db;
  try {
    const userTokens = await db
      .selectFrom("token")
      .select(["id", "name", "created_at", "last_used_at"])
      .where("user_id", "=", userId)
      .where("archived_at", "is", null)
      .orderBy("created_at", "desc")
      .execute();

    return c.json(userTokens);
  } catch (error) {
    const logger = createLogger();
    logger.error("Error fetching tokens", error as Error, { user_id: userId });
    return new Response(
      `Error fetching tokens: ${error instanceof Error ? error.message : "Unknown error"}`,
      { status: 500 }
    );
  }
});

// DELETE /token/:id - Revoke token (requires authentication)
tokens.delete("/token/:id", async (c) => {
  const tokenId = c.req.param("id");
  const userId = c.var.user?.id;
  if (!userId) {
    return new Response("Unauthorized", { status: 401 });
  }

  const db = c.var.db;

  try {
    // Soft delete - set archived_at
    await db
      .updateTable("token")
      .set({ archived_at: new Date().toISOString() })
      .where("id", "=", tokenId)
      .where("user_id", "=", userId)
      .execute();

    return c.json({ success: true });
  } catch (error) {
    const logger = createLogger();
    logger.error("Error deleting token", error as Error, {
      user_id: userId,
      token_id: tokenId,
    });
    return new Response(
      `Error deleting token: ${error instanceof Error ? error.message : "Unknown error"}`,
      { status: 500 }
    );
  }
});

// GET /session/:sessionId - Poll for token completion (NO AUTH - public endpoint)
tokens.get("/session/:sessionId", async (c) => {
  const sessionId = c.req.param("sessionId");

  // Get session from Durable Object
  const sdkTokenStoreId = c.env.SDK_TOKEN_STORE.idFromName(sessionId);
  const sdkTokenStore = c.env.SDK_TOKEN_STORE.get(sdkTokenStoreId);
  const session = await sdkTokenStore.get(sessionId);

  if (!session) {
    return new Response("Session not found or expired", { status: 404 });
  }

  // Return token and user info, then delete session
  await sdkTokenStore.delete(sessionId);

  return c.json({
    token: session.token,
    user: {
      id: session.userId,
      email: session.email,
    },
  });
});

// POST /session/authorize - Authorize a session
// This is called from the site when user clicks "Authorize"
// Validates Clerk JWT to authenticate the user
// Apply strict rate limiting (10 req/hour)
tokens.post("/session/authorize", tokenCreationRateLimiter, async (c) => {
  // Extract access token from Authorization header
  const authHeader = c.req.header("Authorization");

  if (!authHeader?.startsWith("Bearer ")) {
    return new Response("Unauthorized: Missing Authorization header", {
      status: 401,
    });
  }

  const accessToken = authHeader.replace("Bearer ", "");

  // Validate the Clerk JWT using local PEM key (no network call)
  const db = c.var.db;
  const { user, claims, error: authError } = await getUser(
    db,
    accessToken,
    c.env.CLERK_JWT_KEY
  );
  if (claims && !user) {
    return new Response("Please activate your account in the Plot app first.", {
      status: 403,
    });
  }

  if (authError || !user) {
    const logger = createLogger();
    logger.error("Authentication error", authError as Error, {});
    return new Response("Unauthorized: Invalid or expired session", {
      status: 401,
    });
  }

  const userId = user.id;
  const userEmail = user.email || "unknown@plot.day";

  const rawBody = await c.req.json();
  const parseResult = AuthorizeSessionSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }

  const { sessionId } = parseResult.data;

  // Generate cryptographically secure token
  const tokenValue = crypto.randomBytes(32).toString("hex");

  // Store token in database
  try {
    await db
      .insertInto("token")
      .values({
        user_id: userId,
        token: tokenValue,
        name: "CLI Token",
      })
      .returningAll()
      .executeTakeFirstOrThrow();
  } catch (error) {
    const logger = createLogger();
    logger.error("Error creating token", error as Error, {
      user_id: userId,
      session_id: sessionId,
    });
    return new Response(
      `Error creating token: ${error instanceof Error ? error.message : "Unknown error"}`,
      { status: 500 }
    );
  }

  // Store session with token for CLI to poll in Durable Object
  const sdkTokenStoreId = c.env.SDK_TOKEN_STORE.idFromName(sessionId);
  const sdkTokenStore = c.env.SDK_TOKEN_STORE.get(sdkTokenStoreId);

  await sdkTokenStore.set(sessionId, {
    token: tokenValue,
    userId,
    email: userEmail,
  });

  // Expiration and cleanup are handled automatically by the Durable Object alarm

  return c.json({ success: true });
});

export default tokens;
