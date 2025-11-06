import * as crypto from "crypto";
import { Hono } from "hono";
import { z } from "zod";

import { createClient } from "@plotday/db";

import type { Bindings } from "../env";
import { getUser } from "../utils/auth";
import { handleValidationError } from "../utils/validation";

const tokens = new Hono<{ Bindings: Bindings }>();

// In-memory session storage (for MVP - could be moved to KV or Durable Object for persistence)
const sessionStore = new Map<
  string,
  { token: string; userId: string; email: string }
>();

const CreateTokenSchema = z.object({
  name: z.string().optional(),
});

const AuthorizeSessionSchema = z.object({
  sessionId: z.string().uuid(),
});

// POST /token - Create new token (requires authentication)
tokens.post("/token", async (c) => {
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
    console.error("Error creating token:", error);
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
    console.error("Error fetching tokens:", error);
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
    console.error("Error deleting token:", error);
    return new Response(`Error deleting token: ${error.message}`, {
      status: 500,
    });
  }

  return c.json({ success: true });
});

// GET /session/:sessionId - Poll for token completion (NO AUTH - public endpoint)
tokens.get("/session/:sessionId", async (c) => {
  const sessionId = c.req.param("sessionId");

  const session = sessionStore.get(sessionId);
  if (!session) {
    return new Response("Session not found or expired", { status: 404 });
  }

  // Return token and user info, then delete session
  sessionStore.delete(sessionId);

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
tokens.post("/session/authorize", async (c) => {
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
  console.log("Authorized user:", user);
  if (authError || !user) {
    console.error("Authentication error:", authError);
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
    console.error("Error creating token:", error);
    return new Response(`Error creating token: ${error.message}`, {
      status: 500,
    });
  }

  // Store session with token for CLI to poll
  sessionStore.set(sessionId, {
    token: tokenValue,
    userId,
    email: userEmail,
  });

  // Set expiration to clean up after 5 minutes
  setTimeout(() => {
    sessionStore.delete(sessionId);
  }, 5 * 60 * 1000);

  return c.json({ success: true });
});

export default tokens;
