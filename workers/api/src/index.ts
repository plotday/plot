import type { User } from "@supabase/supabase-js";

import * as Sentry from "@sentry/cloudflare";
import { withSentry } from "@sentry/cloudflare";
import { WorkerEntrypoint } from "cloudflare:workers";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { z } from "zod";

import type { Activity } from "@plotday/agents";
import type { SupabaseClient } from "@plotday/db";
import { createClient } from "@plotday/db";
import type { SyncRequest } from "@plotday/sync";

import {
  Plot,
  add as addAgent,
  deleteAgent,
  getById as getAgentById,
  getByPriority as getAgentsByPriority,
  getAll as getAllAgents,
  update as updateAgent,
} from "./agent";
import {
  create as createEvent,
  respond as respondEvent,
  update as updateEvent,
} from "./event";
import { summarize } from "./summary";
import { addAccount, syncCalendar } from "./sync";

// Helper function for handling validation errors
function handleValidationError(error: z.ZodError) {
  const messages = error.issues.map((e) => `${e.path.join(".")}: ${e.message}`);
  return new Response(`Validation error: ${messages.join(", ")}`, {
    status: 400,
  });
}

export abstract class AgentRunner extends WorkerEntrypoint {
  abstract activate(agentId: string, plot: Plot): Promise<void>;

  abstract activity(
    agentId: string,
    plot: Plot,
    activity: Activity
  ): Promise<void>;
}

export type Bindings = {
  readonly API_HMAC_SECRET?: string;
  readonly SENTRY_DSN: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_ANON_KEY: string;
  readonly SUPABASE_SERVICE_KEY: string;

  readonly GOOGLE_CLIENT_ID: string;
  readonly GOOGLE_OAUTH_SECRET: string;
  readonly MICROSOFT_CLIENT_ID: string;
  readonly MICROSOFT_OAUTH_SECRET: string;

  readonly AUTH_CALLBACK_URL: string;
  readonly CALENDAR_WEBHOOK_URL: string;

  readonly SYNC_QUEUE: Queue<SyncRequest>;
  readonly AI: Ai;
  readonly AGENT_RUNNER: Service<AgentRunner>;
};

declare module "hono" {
  interface ContextVariableMap {
    supabase: SupabaseClient;
    user: User;
  }
}

const app = new Hono<{ Bindings: Bindings }>();

// Auth middleware
app.use(
  "/*",
  cors({
    origin: [
      "http://localhost:8788",
      "https://preview.plot.day",
      "https://app.plot.day",
    ],
  })
);
app.use("*", async (c, next) => {
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

const SyncRequestSchema = z.object({
  calendarId: z.number().optional(),
  code: z.string().optional(),
  provider: z.enum(["google", "outlook"]).optional(),
});

app.post("/sync", async (c) => {
  const supabaseAdmin = createClient(
    c.env.SUPABASE_URL,
    c.env.SUPABASE_SERVICE_KEY
  );

  const rawBody = await c.req.json();
  const parseResult = SyncRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;

  if (body.calendarId) {
    const calendar = await supabaseAdmin
      .from("calendar")
      .select("account(user_id)")
      .eq("id", body.calendarId)
      .single();
    if (calendar.data?.account?.user_id !== c.var.user.id) {
      return new Response("Forbidden", { status: 403 });
    }
    await syncCalendar(c.env, body.calendarId);
    return c.json({});
  }

  if (!body.code) {
    return new Response("Bad request (missing code)", { status: 400 });
  }
  if (!body.provider) {
    return new Response("Bad request (missing provider)", { status: 400 });
  }
  const account = await addAccount(
    c.env,
    supabaseAdmin,
    c.var.user,
    body.provider,
    body.code
  );
  return c.json(account);
});

const EventRequestSchema = z.object({
  event: z.object({
    at: z.unknown(),
    availability: z
      .enum(["busy", "away", "focus", "free", "location"])
      .optional(),
    calendar_id: z.number().nullable().optional(),
    conferencing_url: z.string().nullable().optional(),
    created_at: z.string().optional(),
    deleted_at: z.string().nullable().optional(),
    description: z.string().nullable().optional(),
    draft: z.boolean().optional(),
    id: z.string().optional(),
    invitees_hidden: z.boolean().optional(),
    name: z.string().nullable().optional(),
    optional: z.boolean().optional(),
    organizer_email: z.string().nullable().optional(),
    provider_id: z.string().nullable().optional(),
    provider_link: z.string().nullable().optional(),
    response: z
      .enum(["accepted", "declined", "tentative"])
      .nullable()
      .optional(),
    sequence: z.number().optional(),
    series: z.string().nullable().optional(),
    status: z.enum(["confirmed", "cancelled", "tentative"]).optional(),
    summary: z.string().nullable().optional(),
    updated_at: z.string().optional(),
    updated_by: z.number().optional(),
    user_id: z.string().nullable().optional(),
    visibility: z
      .enum(["normal", "private", "confidential", "public", "personal"])
      .optional(),
  }),
});

app.post("/event", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = EventRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  const dbEvent = await createEvent(c.env, c.var.supabase, body.event);
  return c.json(dbEvent);
});

const EventUpdateRequestSchema = z.object({
  event: z.object({
    at: z.unknown().optional(),
    availability: z
      .enum(["busy", "away", "focus", "free", "location"])
      .optional(),
    calendar_id: z.number().nullable().optional(),
    conferencing_url: z.string().nullable().optional(),
    created_at: z.string().optional(),
    deleted_at: z.string().nullable().optional(),
    description: z.string().nullable().optional(),
    draft: z.boolean().optional(),
    id: z.string().optional(),
    invitees_hidden: z.boolean().optional(),
    name: z.string().nullable().optional(),
    optional: z.boolean().optional(),
    organizer_email: z.string().nullable().optional(),
    provider_id: z.string().nullable().optional(),
    provider_link: z.string().nullable().optional(),
    response: z
      .enum(["accepted", "declined", "tentative"])
      .nullable()
      .optional(),
    sequence: z.number().optional(),
    series: z.string().nullable().optional(),
    status: z.enum(["confirmed", "cancelled", "tentative"]).optional(),
    summary: z.string().nullable().optional(),
    updated_at: z.string().optional(),
    updated_by: z.number().optional(),
    user_id: z.string().nullable().optional(),
    visibility: z
      .enum(["normal", "private", "confidential", "public", "personal"])
      .optional(),
  }),
  response: z.enum(["accepted", "declined", "tentative"]).nullable().optional(),
});

app.patch("/event/:id", async (c) => {
  const eventId = parseInt(c.req.param("id"));
  const rawBody = await c.req.json();
  const parseResult = EventUpdateRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  const dbEvent = await updateEvent(c.env, c.var.supabase, eventId, body.event);
  if (body.response) {
    await respondEvent(c.env, c.var.supabase, eventId, body.response);
  }
  return c.json(dbEvent);
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
    const plot = new Plot({
      supabase: c.var.supabase,
      priorityId: body.priorityId,
      priorityAgentId: dbPriorityAgent.id,
      ai: c.env.AI,
      config: body.config,
    });
    await c.env.AGENT_RUNNER.activate(body.agentId, plot);
    return c.json(dbPriorityAgent.id);
  } catch (error) {
    if (error instanceof Error) {
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

const DatabaseUpdateRequestSchema = z.object({
  item: z.object({
    id: z.string().optional(),
    created_by: z.string().optional(),
    priority_id: z.unknown(),
    do_at: z.unknown(),
    done_at: z.string().nullable().optional(),
    note: z.string().nullable().optional(),
    title: z.string().nullable().optional(),
    parent_id: z.string().nullable().optional(),
    path: z.unknown().optional(),
    pinned: z.boolean().optional(),
  }),
  agents: z.array(
    z.object({
      public_id: z.string(),
      priority_agent_id: z.string(),
      config: z.record(z.string(), z.any()).optional(),
    })
  ),
});

app.post("/_/update", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = DatabaseUpdateRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  const activity = body.item;

  for (const agent of body.agents) {
    Sentry.withScope((scope) => {
      scope.setExtra("agent-public-id", agent.public_id);
      Sentry.captureMessage(agent.public_id, "error");
    });
    try {
      const plot = new Plot({
        supabase: c.var.supabase,
        priorityId: String(activity.priority_id),
        priorityAgentId: agent.priority_agent_id,
        ai: c.env.AI,
        config: agent.config,
      });
      await c.env.AGENT_RUNNER.activity(agent.public_id, plot, {
        id: String(activity.id || ""),
        createdBy: String(activity.created_by || ""),
        priorityId: String(activity.priority_id),
        doAt: activity.do_at ? String(activity.do_at) : undefined,
        doneAt: activity.done_at
          ? new Date(String(activity.done_at))
          : undefined,
        note: activity.note ? String(activity.note) : undefined,
        title: activity.title ? String(activity.title) : undefined,
        parentId: activity.parent_id ? String(activity.parent_id) : undefined,
        path: String(activity.path || ""),
        pinned: Boolean(activity.pinned),
      });
    } catch (error) {
      if (error instanceof Error) {
        console.error(
          `Error processing activity for agent ${agent.public_id}: ${error.message}`
        );
        return new Response(
          `Error processing activity for agent ${agent.public_id}: ${error.message}`,
          { status: 400 }
        );
      }
      throw error;
    }
  }
  return c.json({ success: true });
});

const DatabaseActivateRequestSchema = z.object({
  public_id: z.string(),
  priority_agent_id: z.string(),
  priority_id: z.string(),
  config: z.record(z.string(), z.any()).optional(),
});

app.post("/_/activate", async (c) => {
  const rawBody = await c.req.json();
  const parseResult = DatabaseActivateRequestSchema.safeParse(rawBody);
  if (!parseResult.success) {
    return handleValidationError(parseResult.error);
  }
  const body = parseResult.data;
  try {
    const plot = new Plot({
      supabase: c.var.supabase,
      priorityId: body.priority_id,
      priorityAgentId: body.priority_agent_id,
      ai: c.env.AI,
      config: body.config,
    });
    await c.env.AGENT_RUNNER.activate(body.public_id, plot);
    return c.json({ success: true });
  } catch (error) {
    if (error instanceof Error) {
      return new Response(
        `Error activating agent ${body.public_id}: ${error.message}`,
        { status: 400 }
      );
    }
    throw error;
  }
});

export default withSentry(
  (env) => ({
    dsn: (env as Bindings).SENTRY_DSN,
    release: RELEASE,
    dist: PACKAGE,
    environment: ENV,
    enabled: ENV !== "development",
  }),
  app as any
);
