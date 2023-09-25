import { add, differenceInYears, startOfYear, sub, subYears } from "date-fns";
import { Toucan } from "toucan-js";

import type { CalendarConfig, SyncState, WatchState } from "@plotday/cal";
import { sync, watch } from "@plotday/cal";
import type { SupabaseClient } from "@plotday/db";
import { createClient, getCredentials } from "@plotday/db";
import type {
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
}

async function runSync(
  env: Env,
  supabase: SupabaseClient,
  accountId: number,
  providerCalendarId: string,
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

  let credentials = await getCredentials(supabase, accountId);

  async function updateWatch() {
    if (syncType === "partial" || !env.CALENDAR_WEBHOOK_URL) return null;
    console.log(`Updating watch (${accountId}:${providerCalendarId})`);
    let state: WatchState;
    ({ state, credentials } = await watch(
      calendarConfig,
      credentials,
      providerCalendarId
    ));
    return state;
  }

  let state: SyncState | undefined;
  let calendar;
  try {
    // Create a new watch
    let watchState = syncType === "full" ? await updateWatch() : null;

    calendar = (
      await supabase
        .from("calendar")
        .upsert(
          {
            account_id: accountId,
            provider_id: providerCalendarId,
            sync_error: null,
            ...(syncType === "full"
              ? {
                  full_sync_started_at: new Date().toISOString(),
                  full_sync_at: null,
                }
              : {}),
            ...(watchState
              ? {
                  watch_id: watchState.watchId,
                  provider_id: watchState.calendarId,
                  watch_secret: watchState.secret,
                  watch_expires_at: watchState.expiry.toISOString(),
                }
              : {}),
          },
          { onConflict: "account_id, provider_id" }
        )
        .select()
        .single()
        .throwOnError()
    ).data;
    if (!calendar) throw new Error("Could not create calendar");

    // Update a missing or expired watch
    if (
      !calendar.watch_id ||
      !calendar.watch_expires_at ||
      new Date(calendar.watch_expires_at) < new Date()
    ) {
      watchState = await updateWatch();
      if (watchState) {
        await supabase
          .from("calendar")
          .update({
            watch_id: watchState.watchId,
            provider_id: watchState.calendarId,
            watch_secret: watchState.secret,
            watch_expires_at: watchState.expiry.toISOString(),
          })
          .eq("id", calendar.id)
          .throwOnError();
      }
    }

    if (
      syncType === "incremental" &&
      (!calendar.starts_at ||
        !calendar.ends_at ||
        !calendar.next_token ||
        differenceInYears(new Date(), new Date(calendar.starts_at)) < 1)
    ) {
      syncType = "full";
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
      nextToken:
        syncType === "incremental" && calendar.next_token
          ? calendar.next_token
          : undefined,
      more: syncType === "incremental" && !!calendar.more,
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
        `Fetched ${events.length} events for ${state.calendarId} (${
          state.more ? "more" : "no more"
        })`
      );

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

    await supabase
      .from("account")
      .update({
        credentials,
      })
      .eq("id", accountId)
      .single()
      .throwOnError();
    if (syncType !== "partial") {
      await supabase
        .from("calendar")
        .update({
          starts_at: state.min.toISOString(),
          ends_at: state.max.toISOString(),
          more: state.more,
          next_token: state.nextToken,
          sequence: state.sequence,
          synced_at: new Date().toISOString(),
        })
        .eq("id", calendar.id)
        .throwOnError();
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
    if (calendar && error instanceof Error) {
      await supabase
        .from("calendar")
        .update({
          sync_error: error.message,
        })
        .eq("id", calendar.id)
        .throwOnError();
    }
    throw error;
  }

  if (state && syncType === "full") {
    // Wait 30 seconds (for new events to sync) then delete events with older sequence numbers
    await new Promise((resolve) => {
      setTimeout(() => {
        resolve(null);
      }, 30_000);
    });
    await supabase
      .from("raw_event")
      .delete()
      .eq("calendar_id", calendar.id)
      .lt("sequence", state.sequence)
      .throwOnError();
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
    const accountId = (body as any)?.accountId;
    if (typeof accountId !== "number") {
      return new Response("Bad Request", { status: 400 });
    }
    const providerCalendarId = (body as any)?.providerCalendarId;
    const syncType = (body as any)?.syncType;
    await env.SYNC_QUEUE.send({
      accountId,
      providerCalendarId,
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
        const accountId = message.body.accountId;
        const providerCalendarId = message.body.providerCalendarId || "primary";
        const syncType = message.body.syncType || "incremental";
        console.log(`Starting ${syncType} sync (${accountId})`);
        try {
          await runSync(env, supabase, accountId, providerCalendarId, syncType);
          console.log(`Sync complete (${accountId})`);
          message.ack();
        } catch (e) {
          console.error(e);
          Sentry.withScope((scope) => {
            scope.setExtra("account-id", accountId);
            scope.setExtra("provider-calendar-id", providerCalendarId);
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
};
