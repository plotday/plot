import type { User } from "@supabase/supabase-js";

import { withSentry } from "@sentry/cloudflare";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { z } from "zod";

import type { AuthProvider } from "@plotday/agent/tools/auth";
import type { Callback } from "@plotday/agent/tools/callback";
import { type SupabaseClient, createClient } from "@plotday/db";

import { type ToolDependencySpec, agentFactory, createTools } from "./agent";
import {
  add as addAgent,
  deleteAgent,
  getById as getAgentById,
  getByPriority as getAgentsByPriority,
  getAll as getAllAgents,
  update as updateAgent,
} from "./agent/management";
import { Auth } from "./agent/tools/auth";
import { CallbackTool } from "./agent/tools/callback";
import { Run, type RunMessage } from "./agent/tools/run";
import { Webhook } from "./agent/tools/webhook";
import { type Bindings, type QueueMessage, type UpdateMessage } from "./env";
import { summarize } from "./summary";
import { ItemSchema } from "./types";
import { processUpdates } from "./updates";

// Export Durable Objects
export { Storage } from "./storage";
export { Callbacks } from "./callbacks";
export { Broadcast } from "./broadcast";

// Helper function for handling validation errors
function handleValidationError(error: z.ZodError) {
  const messages = error.issues.map((e) => `${e.path.join(".")}: ${e.message}`);
  console.warn("Validation error:", messages);
  return new Response(`Validation error: ${messages.join(", ")}`, {
    status: 400,
  });
}

declare module "hono" {
  interface ContextVariableMap {
    supabase: SupabaseClient;
    user: User;
  }
}

const app = new Hono<{ Bindings: Bindings }>();

// CORS middleware
app.use((c, next) => {
  if (c.req.path.startsWith("/updates")) {
    // Skip CORS for WebSocket endpoints
    return next();
  }
  return cors({
    origin: [
      "http://localhost:8788",
      "https://preview.plot.day",
      "https://app.plot.day",
    ],
  })(c, next);
});
// Auth middleware
app.use("*", async (c, next) => {
  if (c.req.path.startsWith("/updates")) {
    // WebSocket protocol doesn't support custom headers, so we're using the
    // Sec-WebSocket-Protocol method, checked in the handler.
    return next();
  }
  if (new URL(c.req.url).pathname.startsWith("/_/")) {
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
    const supabase = createClient(
      c.env.SUPABASE_URL,
      c.env.SUPABASE_SERVICE_KEY
    );
    c.set("supabase", supabase);
    return await next();
  }
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
});

// WebSocket broadcast endpoint
app.get("/updates/:userId", async (c) => {
  const userId = c.req.param("userId");

  // Get the Broadcast DurableObject for this user
  const broadcastId = c.env.BROADCAST.idFromName(userId);
  const broadcast = c.env.BROADCAST.get(broadcastId);

  // Forward the request to the DurableObject
  return broadcast.fetch(c.req.raw);
});

const SummaryRequestSchema = z.object({
  body: z.string(),
});

app.post("/summary", async (c) => {
  try {
    const rawBody = await c.req.json();
    const parseResult = SummaryRequestSchema.safeParse(rawBody);
    if (!parseResult.success) {
      return handleValidationError(parseResult.error);
    }
    const body = parseResult.data;
    return c.json(await summarize(c.env.AI, body.body));
  } catch (error) {
    console.error("Error processing summary request:", error);
    return c.json({ error: "Error processing request." }, 500);
  }
});

app.get("/agents", async (c) => {
  const agents = await getAllAgents(c.var.supabase);
  return c.json(agents);
});

app.get("/agent/:id", async (c) => {
  const agentId = c.req.param("id");
  const agents = await getAgentById(c.var.supabase, agentId);
  return c.json(agents);
});

app.get("/agent", async (c) => {
  const priorityId = c.req.query("priorityId");
  if (!priorityId) {
    return new Response("Bad request (missing priorityId)", { status: 400 });
  }
  const agents = await getAgentsByPriority(c.var.supabase, priorityId);
  return c.json(agents);
});

const AgentRequestSchema = z.object({
  priorityId: z.string(),
  agentId: z.string(),
  name: z.string().optional(),
  config: z.record(z.string(), z.any()).optional(),
});

app.post("/agent", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = AgentRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    const dbPriorityAgent = await addAgent(
      c.var.supabase,
      body.priorityId,
      body.agentId,
      body.name,
      body.config
    );
    const tools = createTools(
      {
        path: [body.agentId],
        dependencies: dbPriorityAgent.tools as ToolDependencySpec[],
      },
      {
        ai: c.env.AI,
        supabase: c.var.supabase,
        priorityId: body.priorityId,
        priorityAgentId: dbPriorityAgent.id,
        storage: c.env.STORAGE,
        callbacks: c.env.CALLBACKS,
        env: c.env,
        agents: agentFactory(c.env),
      }
    );
    await agentFactory(c.env)(body.agentId).activate(tools, {
      id: body.priorityId,
    });
    return c.json(dbPriorityAgent.id);
  } catch (error) {
    console.error("Error adding agent:", error);
    if (error instanceof Error) {
      console.warn(error.stack);
      return new Response(`Error adding agent: ${error.message}`, {
        status: 400,
      });
    }
    throw error;
  }
});

const AgentUpdateRequestSchema = z.object({
  agent: z.record(z.string(), z.any()),
});

app.patch("/agent/:id", async (c) => {
  const agentId = c.req.param("id");
  const rawBody = await c.req.json();
  const parseResult = AgentUpdateRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    const dbAgent = await updateAgent(c.var.supabase, agentId, body.agent);
    return c.json(dbAgent);
  } catch (error) {
    if (error instanceof Error) {
      return new Response(`Error updating agent: ${error.message}`, {
        status: 400,
      });
    }
    throw error;
  }
});

app.delete("/agent/:id", async (c) => {
  const agentId = c.req.param("id");
  await deleteAgent(c.var.supabase, agentId);
  return c.json({ success: true });
});

// Webhook endpoint - handles all HTTP methods for webhook URLs
app.all(Webhook.PATH, async (c) => {
  try {
    const token = c.req.param("token");
    if (!token) {
      return new Response("Bad request (missing token)", { status: 400 });
    }

    // Extract request data
    const method = c.req.method;
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries(c.req.header())) {
      headers[key] = value;
    }

    // Get URL parameters
    const url = new URL(c.req.url);
    const params: Record<string, string> = {};
    url.searchParams.forEach((value, key) => {
      params[key] = value;
    });

    // Parse body based on content type
    let body: any = null;
    const contentType = c.req.header("content-type");

    if (method !== "GET" && method !== "HEAD") {
      try {
        if (contentType?.includes("application/json")) {
          body = await c.req.json();
        } else if (contentType?.includes("application/x-www-form-urlencoded")) {
          body = await c.req.parseBody();
        } else {
          body = await c.req.text();
        }
      } catch (error) {
        console.warn("Failed to parse callback request body:", error);
        body = await c.req.text();
      }
    }

    const result = await Webhook.Handle(c.env.CALLBACKS, token, {
      method,
      headers,
      params,
      body,
    });

    // Return the result from the callback function
    if (result) {
      // @ts-ignore
      return c.json(result);
    } else {
      return new Response("OK", { status: 200 });
    }
  } catch (error) {
    console.error("Error processing callback:", error);
    return new Response("Internal server error", { status: 500 });
  }
});

// Auth callback endpoint - handles OAuth redirects
app.post("/auth/callback", async (c) => {
  try {
    return await Auth.HandleOauthCallback(
      c.env.STORAGE,
      c.env.CALLBACKS,
      c.req.query(),
      c.env
    );
  } catch (error) {
    console.error("Error processing auth callback:", error);
    return new Response("Internal server error", { status: 500 });
  }
});

// Callback link endpoint - handles activity link callbacks
app.post("/callback/link/:token", async (c) => {
  try {
    const token = c.req.param("token");
    if (!token) {
      return new Response("Bad request (missing token)", { status: 400 });
    }

    const link = await c.req.json();
    if (!link) {
      return new Response("Bad request (missing link data)", { status: 400 });
    }

    const result = await CallbackTool.HandleLinkCallback(
      c.env.CALLBACKS,
      token,
      link
    );

    if (result) {
      return c.json(result);
    } else {
      return c.json({ success: true });
    }
  } catch (error) {
    console.error("Error processing link callback:", error);
    return new Response("Internal server error", { status: 500 });
  }
});

const AuthUrlRequestSchema = z.object({
  provider: z.string(),
  level: z.string(),
  scopes: z.array(z.string()),
  callback: z.string().optional(),
  redirectUri: z.url(),
  platform: z.enum(["ios", "android", "desktop"]).optional(),
});

// Auth URL generation endpoint - generates platform-specific auth URLs
app.get("/auth/url", async (c) => {
  try {
    // Use queries() to handle array parameters like scopes correctly
    const { scopes } = c.req.queries();
    const parseResult = AuthUrlRequestSchema.safeParse({
      ...c.req.query(),
      ...(scopes ? { scopes } : {}),
    });

    if (!parseResult.success) {
      return handleValidationError(parseResult.error);
    }

    const {
      provider,
      level,
      scopes: requestScopes,
      callback,
      redirectUri,
      platform,
    } = parseResult.data;

    // Use the scopes from the request or from query parameters
    const scopesToUse = requestScopes?.length > 0 ? requestScopes : scopes;

    const result = await Auth.GenerateAuthUrl({
      provider: provider as AuthProvider,
      level: level as any, // AuthLevel type
      scopes: scopesToUse,
      callback: callback as Callback | undefined,
      redirectUri,
      platform,
      env: c.env,
      storage: c.env.STORAGE, // DurableObject namespace for global storage
    });

    if (!result) {
      return new Response("No client ID configured for this platform", {
        status: 400,
      });
    }

    return c.json(result);
  } catch (error) {
    console.error("Error generating auth URL:", error);
    if (error instanceof Error) {
      return new Response(`Error generating auth URL: ${error.message}`, {
        status: 400,
      });
    }
    return new Response("Internal server error", { status: 500 });
  }
});

const ToolSchema: z.ZodType<{
  id: string;
  tools?: { id: string; tools?: any }[];
}> = z.lazy(() =>
  z.object({
    id: z.string(),
    tools: z.array(ToolSchema).optional(),
  })
);

// Export types for external use
export type {
  ActivityItem,
  PriorityItem,
  SessionItem,
  UpdateItem,
} from "./types";

const DatabaseUpdateRequestSchema = z.object({
  type: z.enum(["activity", "priority", "session"]),
  event: z.enum(["created", "updated", "deleted"]),
  item: ItemSchema,
  agents: z.array(
    z.object({
      agent_id: z.string(),
      priority_agent_id: z.string(),
      config: z.record(z.string(), z.any()).optional(),
      tools: z.array(ToolSchema).optional(),
    })
  ),
  users: z
    .array(
      z.object({
        user_id: z.string(),
      })
    )
    .optional(),
  timestamp: z.number().optional(),
  table: z.string().optional(),
});

export type DatabaseUpdateRequest = z.infer<typeof DatabaseUpdateRequestSchema>;

app.post("/_/update", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = DatabaseUpdateRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    console.warn("Validation error:", parseResult.error);
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;

  // Add message to the updates queue for processing
  await c.env.UPDATES_QUEUE.send({
    type: body.type,
    event: body.event,
    item: body.item,
    agents: body.agents,
    users: body.users,
    timestamp: body.timestamp,
    table: body.table,
  });

  return c.json({ success: true });
});

const DatabaseActivateRequestSchema = z.object({
  agent_id: z.string(),
  priority_agent_id: z.string(),
  priority_id: z.string(),
  tools: z
    .array(
      z.object({
        id: z.string(),
        tool: z.string().optional(),
        account: z.string().optional(),
      })
    )
    .optional(),
});

app.post("/_/activate", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = DatabaseActivateRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    const tools = createTools(
      {
        path: [body.agent_id],
        dependencies: body.tools || [],
      },
      {
        ai: c.env.AI,
        supabase: c.var.supabase,
        priorityId: body.priority_id,
        priorityAgentId: body.priority_agent_id,
        storage: c.env.STORAGE,
        callbacks: c.env.CALLBACKS,
        env: c.env,
        agents: agentFactory(c.env),
      }
    );
    await agentFactory(c.env)(body.agent_id).activate(tools, {
      id: body.priority_id,
    });
    return c.json({ success: true });
  } catch (error) {
    if (error instanceof Error) {
      return new Response(
        `Error activating agent ${body.agent_id}: ${error.message}`,
        { status: 400 }
      );
    }
    throw error;
  }
});

// Queue consumer handler for run callbacks and updates
export async function queue(
  batch: MessageBatch<QueueMessage>,
  env: Bindings,
  _ctx: ExecutionContext
): Promise<void> {
  // Use batch.queue to distinguish between run and updates queues
  switch (batch.queue) {
    case "run-development":
    case "run-production":
      await Run.processQueue(env, batch as MessageBatch<RunMessage>);
      break;

    case "updates-development":
    case "updates-production":
      await processUpdates(batch as MessageBatch<UpdateMessage>, env);
      break;

    default:
      console.error(`Unknown queue: ${batch.queue}`, {
        queue: batch.queue,
        messageCount: batch.messages.length,
      });
  }
}

export default withSentry(
  (env) => ({
    dsn: (env as Bindings).SENTRY_DSN,
    release: RELEASE,
    dist: PACKAGE,
    environment: ENV,
    enabled: ENV !== "development",
  }),
  {
    ...(app as any),
    queue,
  }
);
