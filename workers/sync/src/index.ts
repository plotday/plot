import { Toucan } from "toucan-js";

import type { CalendarProvider, RawEvent } from "@plotday/cal";
import { createClient, safeQuery } from "@plotday/db";

import type { Env } from "./env";
import { syncCalendar } from "./sync";

export type SyncType = "full" | "incremental" | "partial";
export type SyncRequest = {
  calendarId: number;
  syncType?: SyncType;
};
export type EventSyncRequest = {
  provider: CalendarProvider;
  calendarId: number;
  sequence: number;
  rawEvent?: RawEvent;
  complete?: SyncType;
};

export default {
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
