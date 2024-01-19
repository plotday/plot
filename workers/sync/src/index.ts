import { Toucan } from "toucan-js";

import { createClient, safeQuery } from "@plotday/db";
import type { EventSyncRequest, SyncRequest } from "@plotday/worker-request";

import type { Env } from "./env";
import { addAccount, syncCalendar } from "./sync";

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (req.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }
    let tokens = req.headers.get("Authorization");
    if (!tokens?.startsWith("Bearer ")) {
      return new Response("Forbidden", { status: 403 });
    }
    tokens = tokens.replace(/\s*Bearer\s+/, "");
    const [access_token, refresh_token] = tokens?.split("/");
    const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY);
    const session = await supabase.auth.setSession({
      access_token,
      refresh_token,
    });
    const user = session.data?.user;

    const supabaseAdmin = createClient(
      env.SUPABASE_URL,
      env.SUPABASE_SERVICE_KEY
    );
    if (!user) {
      return new Response("Forbidden", { status: 403 });
    }

    if (url.pathname === "/account") {
      const body = await req.json();
      const code = (body as any)?.code;
      if (!code) {
        return new Response("Bad request (missing code)", { status: 400 });
      }
      const provider = (body as any)?.provider;
      if (!provider) {
        return new Response("Bad request (missing provider)", { status: 400 });
      }
      const account = await addAccount(
        env,
        supabaseAdmin,
        user,
        provider,
        code
      );
      const response = new Response(JSON.stringify(account));
      return response;
    }

    const apiKey = req.headers.get("Authorization");
    if (
      env.ENV !== "development" &&
      apiKey &&
      env.API_KEY &&
      !apiKey.endsWith(env.API_KEY)
    ) {
      return new Response("Forbidden", { status: 403 });
    }
    const body = await req.json();
    const calendarId = (body as any)?.calendarId;
    if (typeof calendarId !== "number") {
      return new Response("Bad request (missing calendarId)", { status: 400 });
    }
    const syncType = (body as any)?.syncType;
    await env.SYNC_QUEUE.send({
      calendarId,
      syncType,
    });

    return new Response("Sync queued");
  },

  async queue(
    batch: MessageBatch<SyncRequest | EventSyncRequest>,
    env: Env
  ): Promise<void> {
    const sentry = new Toucan({
      dsn: env.SENTRY_DSN,
      environment: env.ENV,
      release: env.RELEASE,
      dist: env.PACKAGE,
    });

    const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

    for (const m of batch.messages) {
      try {
        const message = m as Message<SyncRequest>;
        const calendarId = message.body.calendarId;
        const syncType = message.body.syncType || "incremental";
        console.log(`Starting ${syncType} sync (${calendarId})`);
        try {
          await syncCalendar(env, supabase, calendarId, syncType);
          console.log(`Sync complete (${calendarId})`);
          message.ack();
        } catch (e) {
          console.log(`Sync failed (${calendarId})`);
          console.error(e);
          sentry.withScope((scope) => {
            scope.setExtra("calendar-id", calendarId);
            sentry.captureException(e);
          });
          message.retry();
        }
      } catch (e) {
        console.error(e);
        sentry.captureException(e);
        // It's a failure, but it will never succeed because the parameters
        // are wrong.
        m.ack();
      }
    }
  },

  async scheduled(_event: ScheduledController, env: Env) {
    const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

    // Sync calendars
    const calendars = safeQuery(
      await supabase.from("calendar").select("id").eq("enabled", true)
    );
    if (calendars && env.SYNC_QUEUE) {
      const chunkSize = 100;
      const chunks = Array.from(
        { length: Math.ceil(calendars.length / chunkSize) },
        (_, index) =>
          calendars.slice(index * chunkSize, (index + 1) * chunkSize)
      );
      for (const chunk of chunks) {
        await env.SYNC_QUEUE.sendBatch(
          chunk.map((a) => ({ body: { calendarId: a.id } }))
        );
      }
    }

    // Sync contacts
    const accounts = safeQuery(
      await supabase
        .from("account")
        .select("id")
        .not("credentials", "is", "null")
    );
    if (accounts && env.CONTACT_SYNC_QUEUE) {
      const chunkSize = 100;
      const chunks = Array.from(
        { length: Math.ceil(accounts.length / chunkSize) },
        (_, index) => accounts.slice(index * chunkSize, (index + 1) * chunkSize)
      );
      for (const chunk of chunks) {
        await env.CONTACT_SYNC_QUEUE.sendBatch(
          chunk.map((a) => ({ body: { accountId: a.id, full: false } }))
        );
      }
    }
  },
};
