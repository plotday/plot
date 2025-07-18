import * as Sentry from "@sentry/cloudflare";

import type { User } from "@supabase/supabase-js";

import { withSentry } from "@sentry/cloudflare";
import { WorkerEntrypoint } from "cloudflare:workers";
import { Hono } from "hono";
import { cors } from "hono/cors";

import type { SupabaseClient } from "@plotday/db";
import { createClient } from "@plotday/db";
import type { SyncRequest } from "@plotday/sync";

import type { Activity } from "@plotday/agents/src/priority";

import { 
  create as createActivity, 
  update as updateActivity 
} from "./activity";
import {
  create as createEvent,
  respond as respondEvent,
  update as updateEvent,
} from "./event";
import { Priority } from "./priority";
import { summarize } from "./summary";
import { addAccount, syncCalendar } from "./sync";
import { 
  add as addAgent,
  getAll as getAllAgents, 
  getById as getAgentById, 
  getByPriority as getAgentsByPriority, 
  update as updateAgent,
  deleteAgent
} from "./agent";

export abstract class AgentRunner extends WorkerEntrypoint {
  abstract activate(agentId: string, priority: Priority, config: any): Promise<void>;

  abstract activity(agentId: string, activity: Activity, config: any, priority: Priority): Promise<void>;
}

export type Bindings = {
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
    const supabase = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_KEY);
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

app.post("/sync", async (c) => {
  const supabaseAdmin = createClient(
    c.env.SUPABASE_URL,
    c.env.SUPABASE_SERVICE_KEY
  );

  const body = await c.req.json();

  const calendarId = (body as any)?.calendarId;
  if (calendarId) {
    const calendar = await supabaseAdmin
      .from("calendar")
      .select("account(user_id)")
      .eq("id", calendarId)
      .single();
    if (calendar.data?.account?.user_id !== c.var.user.id) {
      return new Response("Forbidden", { status: 403 });
    }
    await syncCalendar(c.env, calendarId);
    return c.json({});
  }

  const code = (body as any)?.code;
  if (!code) {
    return new Response("Bad request (missing code)", { status: 400 });
  }
  const provider = (body as any)?.provider;
  if (!provider) {
    return new Response("Bad request (missing provider)", { status: 400 });
  }
  const account = await addAccount(
    c.env,
    supabaseAdmin,
    c.var.user,
    provider,
    code
  );
  return c.json(account);
});

app.post("/event", async (c) => {
  const body = await c.req.json();
  const event = (body as any)?.event;
  if (!event) {
    return new Response("Bad request (missing event)", { status: 400 });
  }
  const dbEvent = await createEvent(c.env, c.var.supabase, event);
  return c.json(dbEvent);
});

app.patch("/event/:id", async (c) => {
  const eventId = parseInt(c.req.param("id"));
  const body = await c.req.json();
  const event = (body as any)?.event;
  if (!event) {
    return new Response("Bad request (missing event)", { status: 400 });
  }
  const dbEvent = await updateEvent(c.env, c.var.supabase, eventId, event);
  const response = (body as any)?.response;
  if (response) {
    await respondEvent(c.env, c.var.supabase, eventId, response);
  }
  return c.json(dbEvent);
});

app.post("/summary", async (c) => {
  try {
    const { body } = await c.req.json();
    if (typeof body !== "string") {
      return c.json({ error: 'Missing "body" field.' }, 400);
    }
    return c.json(await summarize(c.env.AI, body));
  } catch (error) {
    console.error("Error processing summary request:", error);
    return c.json({ error: "Error processing request." }, 500);
  }
});

app.post("/activity", async (c) => {
  const body = await c.req.json();
  const activity = (body as any)?.activity;
  if (!activity) {
    return new Response("Bad request (missing activity)", { status: 400 });
  }
  const dbActivity = await createActivity(c.var.supabase, activity);
  return c.json(dbActivity);
});

app.patch("/activity/:id", async (c) => {
  const activityId = c.req.param("id");
  const body = await c.req.json();
  const activity = (body as any)?.activity;
  if (!activity) {
    return new Response("Bad request (missing activity)", { status: 400 });
  }
  const dbActivity = await updateActivity(c.var.supabase, activityId, activity);
  return c.json(dbActivity);
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

app.post("/agent", async (c) => {
  const body = await c.req.json();
  const priorityId = (body as any)?.priorityId;
  if (!priorityId) {
    return new Response("Bad request (missing priorityId)", { status: 400 });
  }

  const agentId = (body as any)?.agentId;
  if (!agentId) {
    return new Response("Bad request (missing agentId)", { status: 400 });
  }
  const name = (body as any)?.name;
  const config = (body as any)?.config;
  try {
    const dbPriorityAgent = await addAgent(c.var.supabase, priorityId, agentId, name, config);
    const priority = new Priority(c.var.supabase, priorityId, dbPriorityAgent.id);
    await c.env.AGENT_RUNNER.activate(agentId, priority, config);
    return c.json(dbPriorityAgent.id);
  } catch (error) {
    if (error instanceof Error) {
      return new Response(`Error adding agent: ${error.message}`, { status: 400 });
    } throw error;
  }
});

app.patch("/agent/:id", async (c) => {
  const agentId = c.req.param("id");
  const body = await c.req.json();
  const agent = (body as any)?.agent;
  try {
    const dbAgent = await updateAgent(c.var.supabase, agentId, agent);
    return c.json(dbAgent);
  } catch (error) {
    if (error instanceof Error) {
      return new Response(`Error updating agent: ${error.message}`, { status: 400 });
    }
    throw error;
  }
});

app.delete("/agent/:id", async (c) => {
  const agentId = c.req.param("id");
  await deleteAgent(c.var.supabase, agentId);
  return c.json({ success: true });
});

app.post("/_/update", async (c) => {
  const body = await c.req.json();
  const activity = (body as any)?.item;
  const agents = (body as any)?.agents;
  if (!agents || !Array.isArray(agents)) {
    return new Response("Bad request (missing or invalid agents)", { status: 400 });
  }
  for (const agent of agents) {
    Sentry.withScope((scope) => {
      scope.setExtra("agent-public-id", agent.public_id);
      Sentry.captureMessage(agent.public_id, "error");
    });
    try {
      const priority = new Priority(c.var.supabase, activity.priority_id, agent.priority_agent_id);
      await c.env.AGENT_RUNNER.activity(agent.public_id, activity, priority, agent.config);
    } 
    catch (error) {
      if (error instanceof Error) {
        return new Response(`Error processing activity for agent ${agent.public_id}: ${error.message}`, { status: 400 });
      }
      throw error;
    }
  }
  return c.json({ success: true });
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
)
