import { add, differenceInYears, startOfYear, sub, subYears } from "date-fns";
import { Toucan } from "toucan-js";

import type { CalendarConfig, SyncState, WatchState } from "@plotday/cal";
import { sync, watch } from "@plotday/cal";
import type { SupabaseClient } from "@plotday/db";
import {
  createClient,
  getCredentials,
  safeQuery,
  saveCredentials,
} from "@plotday/db";
import type {
  ContactSyncRequest,
  EventSyncRequest,
  SyncRequest,
  SyncType,
} from "@plotday/worker-request";

interface Env {
  readonly ENV?: string;
  readonly RELEASE?: string;
  readonly PACKAGE?: string;

  readonly API_KEY: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
  readonly SENTRY_DSN: string;
  readonly GOOGLE_CLIENT_ID: string;
  readonly GOOGLE_OAUTH_SECRET: string;
  readonly MICROSOFT_CLIENT_ID: string;
  readonly MICROSOFT_OAUTH_SECRET: string;
  readonly CALENDAR_WEBHOOK_URL: string;

  readonly SYNC_QUEUE: Queue<SyncRequest>;
  readonly EVENT_QUEUE: Queue<EventSyncRequest>;
  readonly CONTACT_SYNC_QUEUE: Queue<ContactSyncRequest>;
}

async function runSync(
  env: Env,
  supabase: SupabaseClient,
  calendarId: number,
  syncType: SyncType
) {
  const maxBatchSize = 50;
  const maxBatchBytes = 128_000;
  const numBatchesPerSync = 5;

  const calendarConfig: CalendarConfig = {
    googleClientId: env.GOOGLE_CLIENT_ID,
    googleOauthSecret: env.GOOGLE_OAUTH_SECRET,
    outlookClientId: env.MICROSOFT_CLIENT_ID,
    outlookOauthSecret: env.MICROSOFT_OAUTH_SECRET,
    webhookUrl: env.CALENDAR_WEBHOOK_URL,
  };

  let state: SyncState | undefined;
  try {
    const calendar = safeQuery(
      await supabase
        .from("calendar")
        .update({
          sync_error: null,
          ...(syncType === "full"
            ? {
                full_sync_started_at: new Date().toISOString(),
                full_sync_at: null,
              }
            : {}),
        })
        .eq("id", calendarId)
        .select("*,account(*)")
        .single()
    );

    async function updateWatch() {
      if (syncType === "partial" || !env.CALENDAR_WEBHOOK_URL || !calendar)
        return null;
      console.log(`Updating watch (${calendarId})`);
      let state: WatchState;
      ({ state, credentials } = await watch(
        calendarConfig,
        credentials,
        calendar.provider_id
      ));
      await saveCredentials(supabase, accountId, credentials, true);
      safeQuery(
        await supabase
          .from("calendar")
          .update({
            watch_id: state.watchId,
            provider_id: state.calendarId,
            watch_secret: state.secret,
            watch_expires_at: state.expiry.toISOString(),
          })
          .eq("id", calendarId)
      );
    }

    // Create a new watch
    if (syncType === "full") {
      await updateWatch();
    }

    if (!calendar) throw new Error(`Calendar ${calendarId} not found`);
    const accountId = calendar.account_id;

    if (syncType === "full") {
      await env.CONTACT_SYNC_QUEUE?.send?.({
        accountId,
        full: true,
      });
    }

    let credentials = await getCredentials(supabase, accountId);

    // Update a missing or expired watch
    if (
      !calendar.watch_id ||
      !calendar.watch_expires_at ||
      new Date(calendar.watch_expires_at) < new Date()
    ) {
      await updateWatch();
    }

    if (
      syncType === "incremental" &&
      (!calendar.starts_at ||
        !calendar.ends_at ||
        !calendar.sync_state ||
        differenceInYears(new Date(), new Date(calendar.starts_at)) < 1)
    ) {
      syncType = "full";
      safeQuery(
        await supabase
          .from("calendar")
          .update({
            full_sync_started_at: new Date().toISOString(),
            full_sync_at: null,
          })
          .eq("id", calendar.id)
      );
    }

    let min, max;
    switch (syncType) {
      case "full":
        min = startOfYear(subYears(new Date(), 1));
        max = add(new Date(), { years: 1, months: 6 });
        break;
      case "incremental":
        min = new Date(calendar.starts_at as string);
        max = new Date(calendar.ends_at as string);
        break;
      case "partial":
        min = sub(new Date(), { days: 3 });
        max = add(new Date(), { days: 7 });
        break;
    }
    state = {
      calendarId: calendar.provider_id,
      min,
      max,
      state:
        syncType === "incremental" && calendar.sync_state
          ? calendar.sync_state
          : undefined,
      sequence: (calendar.sequence || 1) + (syncType === "full" ? 1 : 0),
    };
    let batchBytes = 0;
    let batch: { body: EventSyncRequest }[] = [];
    const sendBatch = async () => {
      console.log(
        `Sending batch of ${batch.length} events (${batchBytes} bytes)`
      );
      await env.EVENT_QUEUE.sendBatch(batch);
      batch = [];
      batchBytes = 0;
    };
    do {
      let events;
      ({ events, state, credentials } = await sync(
        calendarConfig,
        credentials,
        state,
        numBatchesPerSync * maxBatchSize
      ));
      console.log(
        `Fetched ${events.length} events for ${calendar.id} (${
          state.more ? "more" : "no more"
        })`
      );
      await saveCredentials(supabase, accountId, credentials, true);

      if (!state.sequence) throw new Error("Sync state sequence unset");

      for (let i = 0; i < events.length; i += 1) {
        const body = {
          provider: credentials.provider,
          calendarId: calendar.id,
          sequence: state.sequence,
          rawEvent: events[i],
        };
        batch.push({ body });
        batchBytes += JSON.stringify(body).length;
        if (batch.length >= maxBatchSize || batchBytes > maxBatchBytes) {
          await sendBatch();
        }
      }
    } while (state.more);
    if (batch.length) {
      await sendBatch();
    }

    if (syncType !== "partial") {
      safeQuery(
        await supabase
          .from("calendar")
          .update({
            starts_at: state.min.toISOString(),
            ends_at: state.max.toISOString(),
            sync_state: state.state,
            sequence: state.sequence,
            synced_at: new Date().toISOString(),
          })
          .eq("id", calendar.id)
      );
    }
    if (syncType === "full") {
      await env.EVENT_QUEUE.send({
        provider: credentials.provider,
        calendarId: calendar.id,
        sequence: state.sequence,
        fullSyncComplete: true,
      });
    }
  } catch (error) {
    if (error instanceof Error) {
      safeQuery(
        await supabase
          .from("calendar")
          .update({
            sync_error: error.message,
          })
          .eq("id", calendarId)
      );
    }
    throw error;
  }
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
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
      return new Response("Bad Request", { status: 400 });
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
    const Sentry = new Toucan({
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
          await runSync(env, supabase, calendarId, syncType);
          console.log(`Sync complete (${calendarId})`);
          message.ack();
        } catch (e) {
          console.error(e);
          Sentry.withScope((scope) => {
            scope.setExtra("calendar-id", calendarId);
            Sentry.captureException(e);
          });
          message.retry();
        }
      } catch (e) {
        console.error(e);
        Sentry.captureException(e);
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
