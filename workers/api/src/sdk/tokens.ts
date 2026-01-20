import * as crypto from "crypto";
import { Hono } from "hono";
import { z } from "zod";

import { createClient } from "@plotday/db";

import type { Bindings } from "../env";
import { getUser } from "../utils/auth";
import { handleValidationError } from "../utils/validation";
import { createLogger } from "../utils/logger";
import { tokenCreationRateLimiter } from "../middleware/rate-limit";
import { disposeRpc } from "../utils/rpc";

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
  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);
  const { data: token, error } = await supabase
    .from("token")
    .insert({
      user_id: userId,
      token: tokenValue,
      name: name || null,
    })
    .select()
    .single();

  if (error) {
    const logger = createLogger();
    logger.error("Error creating token", error as Error, { user_id: userId });
    return new Response(`Error creating token: ${error.message}`, {
      status: 500,
    });
  }

  return c.json({ token: tokenValue, id: token.id });
});

// GET /tokens - List user's tokens (requires authentication)
tokens.get("/tokens", async (c) => {
  const userId = c.var.user?.id;
  if (!userId) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);
  const { data: userTokens, error } = await supabase
    .from("token")
    .select("id, name, created_at, last_used_at")
    .eq("user_id", userId)
    .is("archived_at", null)
    .order("created_at", { ascending: false });

  if (error) {
    const logger = createLogger();
    logger.error("Error fetching tokens", error as Error, { user_id: userId });
    return new Response(`Error fetching tokens: ${error.message}`, {
      status: 500,
    });
  }

  return c.json(userTokens);
});

// DELETE /token/:id - Revoke token (requires authentication)
tokens.delete("/token/:id", async (c) => {
  const tokenId = c.req.param("id");
  const userId = c.var.user?.id;
  if (!userId) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);

  // Soft delete - set archived_at
  const { error } = await supabase
    .from("token")
    .update({ archived_at: new Date().toISOString() })
    .eq("id", tokenId)
    .eq("user_id", userId);

  if (error) {
    const logger = createLogger();
    logger.error("Error deleting token", error as Error, {
      user_id: userId,
      token_id: tokenId
    });
    return new Response(`Error deleting token: ${error.message}`, {
      status: 500,
    });
  }

  return c.json({ success: true });
});

// GET /session/:sessionId - Poll for token completion (NO AUTH - public endpoint)
tokens.get("/session/:sessionId", async (c) => {
  const sessionId = c.req.param("sessionId");

  // Get session from Durable Object
  const sdkTokenStoreId = c.env.SDK_TOKEN_STORE.idFromName(sessionId);
  const sdkTokenStore = c.env.SDK_TOKEN_STORE.get(sdkTokenStoreId);
  const session = await sdkTokenStore.get(sessionId);
  disposeRpc(session);

  if (!session) {
    return new Response("Session not found or expired", { status: 404 });
  }

  // Return token and user info, then delete session
  const deleteResult = await sdkTokenStore.delete(sessionId);
  disposeRpc(deleteResult);

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
// Validates Supabase session token to authenticate the user
// Apply strict rate limiting (10 req/hour)
tokens.post("/session/authorize", tokenCreationRateLimiter, async (c) => {
  // Extract Supabase access token from Authorization header
  const authHeader = c.req.header("Authorization");

  if (!authHeader?.startsWith("Bearer ")) {
    return new Response("Unauthorized: Missing Authorization header", {
      status: 401,
    });
  }

  const accessToken = authHeader.replace("Bearer ", "");

  // Validate the Supabase session token
  const supabaseAdmin = createClient(
    c.env.SUPABASE_URL,
    c.env.SUPABASE_SERVICE_KEY
  );
  const { user, error: authError } = await getUser(supabaseAdmin, accessToken);
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
  const { error } = await supabaseAdmin
    .from("token")
    .insert({
      user_id: userId,
      token: tokenValue,
      name: "CLI Token",
    })
    .select()
    .single();

  if (error) {
    const logger = createLogger();
    logger.error("Error creating token", error as Error, {
      user_id: userId,
      session_id: sessionId
    });
    return new Response(`Error creating token: ${error.message}`, {
      status: 500,
    });
  }

  // Store session with token for CLI to poll in Durable Object
  const sdkTokenStoreId = c.env.SDK_TOKEN_STORE.idFromName(sessionId);
  const sdkTokenStore = c.env.SDK_TOKEN_STORE.get(sdkTokenStoreId);

  const setResult = await sdkTokenStore.set(sessionId, {
    token: tokenValue,
    userId,
    email: userEmail,
  });
  disposeRpc(setResult);

  // Expiration and cleanup are handled automatically by the Durable Object alarm

  return c.json({ success: true });
});

export default tokens;
