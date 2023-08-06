import { jsonFetch as fetch } from "@worker-tools/json-fetch";
import { add, startOfYear, subYears } from "date-fns";
import { Toucan } from "toucan-js";

import type { CalendarConfig, SyncState, WatchState } from "@plotday/cal";
import { sync, watch } from "@plotday/cal";
import type { SupabaseClient } from "@plotday/db";
import { createClient, getCredentials, safeQuery } from "@plotday/db";
import type { EventSyncRequest, SyncRequest } from "@plotday/worker-request";

interface Env {
  readonly ENV?: string;
  readonly RELEASE?: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
  readonly SENTRY_DSN: string;
  readonly GOOGLE_CLIENT_ID: string;
  readonly GOOGLE_OAUTH_SECRET: string;
  readonly MICROSOFT_CLIENT_ID: string;
  readonly MICROSOFT_OAUTH_SECRET: string;
  readonly CALENDAR_WEBHOOK_URL: string;

  readonly QUEUE: Queue<SyncRequest>;
  readonly EVENT_QUEUE: Queue<EventSyncRequest>;
}

async function runSync(
  env: Env,
  supabase: SupabaseClient,
  accountId: number,
  providerCalendarId: string,
  full: boolean
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
    if (!env.CALENDAR_WEBHOOK_URL) return null;
    console.log(`Updating watch (${accountId}:${providerCalendarId})`);
    let state: WatchState;
    ({ state, credentials } = await watch(
      calendarConfig,
      credentials,
      providerCalendarId
    ));
    return state;
  }

  // Create a new watch
  let watchState = full ? await updateWatch() : null;

  const calendar = safeQuery(
    await supabase
      .from("calendar")
      .upsert(
        {
          account_id: accountId,
          provider_id: providerCalendarId,
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
  );
  if (!calendar) throw new Error("Could not create calendar");

  // Update a missing or expired watch
  if (
    !calendar.watch_id ||
    !calendar.watch_expires_at ||
    new Date(calendar.watch_expires_at) < new Date()
  ) {
    watchState = await updateWatch();
    if (watchState) {
      safeQuery(
        await supabase
          .from("calendar")
          .update({
            watch_id: watchState.watchId,
            provider_id: watchState.calendarId,
            watch_secret: watchState.secret,
            watch_expires_at: watchState.expiry.toISOString(),
          })
          .eq("id", calendar.id)
      );
    }
  }

  let state: SyncState = {
    calendarId: calendar.provider_id,
    min:
      !full && calendar.starts_at
        ? new Date(calendar.starts_at)
        : startOfYear(subYears(new Date(), 1)),
    max:
      !full && calendar.ends_at
        ? new Date(calendar.ends_at)
        : add(new Date(), { years: 1, months: 6 }),
    nextToken: !full && calendar.next_token ? calendar.next_token : undefined,
    more: !full && !!calendar.more,
    sequence: (calendar.sequence || 1) + (full ? 1 : 0),
  };
  let batchBytes = 0;
  let batch = [];
  do {
    let events;
    ({ events, state, credentials } = await sync(
      calendarConfig,
      credentials,
      state,
      numBatchesPerSync * maxBatchSize
    ));

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
        console.log(`Sending batch of ${batch.length} events`);
        await env.EVENT_QUEUE.sendBatch(batch);
        batch = [];
        batchBytes = 0;
      }
    }
  } while (state.more);
  if (batch.length) {
    console.log(`Sending batch of ${batch.length} events`);
    await env.EVENT_QUEUE.sendBatch(batch);
  }

  safeQuery(
    await supabase
      .from("account")
      .update({
        credentials,
      })
      .eq("id", accountId)
      .single()
  );
  safeQuery(
    await supabase
      .from("calendar")
      .update({
        starts_at: state.min.toISOString(),
        ends_at: state.max.toISOString(),
        more: state.more,
        next_token: state.nextToken,
        sequence: state.sequence,
      })
      .eq("id", calendar.id)
  );

  // Wait 30 seconds (for new events to sync) then delete events with older sequence numbers
  await new Promise((resolve) => {
    setTimeout(() => {
      resolve(null);
    }, 30_000);
  });
  safeQuery(
    await supabase
      .from("raw_event")
      .delete()
      .eq("calendar_id", calendar.id)
      .lt("sequence", state.sequence)
  );
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }
    if (env.ENV !== "development") {
      return new Response("Forbidden", { status: 403 });
    }
    const body = await req.json();
    const accountId = (body as any)?.accountId;
    if (typeof accountId !== "number") {
      return new Response("Bad Request", { status: 400 });
    }
    const providerCalendarId = (body as any)?.providerCalendarId;
    const full = (body as any)?.full;
    await env.QUEUE.send({
      accountId,
      providerCalendarId,
      full,
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
      dist: "sync",
    });

    const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

    switch (batch.queue) {
      default:
        for (const m of batch.messages) {
          try {
            const message = m as Message<SyncRequest>;
            const accountId = message.body.accountId;
            const providerCalendarId =
              message.body.providerCalendarId || "primary";
            const full = !!message.body.full;
            console.log(`Starting sync (${accountId})`);
            try {
              await runSync(env, supabase, accountId, providerCalendarId, full);
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
        break;

      // This only happens in development, where wrangler limits require the
      // consume to be in the same worker as the producer.
      case "plot-event-development-queue":
        await fetch("http://127.0.0.1:8786/", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify(batch.messages),
        });
        break;
    }
  },
};
