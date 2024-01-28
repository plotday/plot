import type { User } from "@supabase/supabase-js";

import { Hono } from "hono";

import type { SupabaseClient } from "@plotday/db";
import { createClient } from "@plotday/db";
import type { SyncRequest } from "@plotday/sync";

import { addAccount } from "./sync";

export type Bindings = {
  readonly SUPABASE_URL: string;
  readonly SUPABASE_ANON_KEY: string;
  readonly SUPABASE_SERVICE_KEY: string;

  readonly GOOGLE_CLIENT_ID: string;
  readonly GOOGLE_OAUTH_SECRET: string;
  readonly MICROSOFT_CLIENT_ID: string;
  readonly MICROSOFT_OAUTH_SECRET: string;

  readonly CALENDAR_WEBHOOK_URL: string;

  readonly SYNC_QUEUE: Queue<SyncRequest>;
};

declare module "hono" {
  interface ContextVariableMap {
    supabase: SupabaseClient;
    user: User;
  }
}

const app = new Hono<{ Bindings: Bindings }>();

// Auth middleware
app.use("*", async (c, next) => {
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

export default app;
