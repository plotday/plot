import type { User } from "@supabase/supabase-js";

import { withSentry } from "@sentry/cloudflare";
import { Hono } from "hono";
import { cors } from "hono/cors";

import type { SupabaseClient } from "@plotday/db";
import { createClient } from "@plotday/db";
import type { SyncRequest } from "@plotday/sync";

import { create as createEvent, respond as respondEvent, update as updateEvent } from "./event";
import { summarize } from "./summary";
import { addAccount, syncCalendar } from "./sync";
import { create as createActivity, update as updateActivity } from "./activity";

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
