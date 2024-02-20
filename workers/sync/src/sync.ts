import type { SupabaseClient } from "@supabase/supabase-js";

import {
  add,
  differenceInYears,
  endOfMonth,
  max as maxDate,
  startOfMonth,
  startOfYear,
  subMonths,
  subYears,
} from "date-fns";

import {
  type SyncState,
  type WatchState,
  getCalendarConfig,
  sync,
  watch,
} from "@plotday/cal";
import {
  formatDatetimeRange,
  getCredentials as getDbCredentials,
  parseDatetimeRange,
  safeQuery,
  saveCredentials,
} from "@plotday/db";

import { type EventSyncRequest, type SyncType } from "./";
import type { Env } from "./env";

export async function syncCalendar(
  env: Env,
  supabase: SupabaseClient,
  calendarId: number,
  syncType: SyncType
) {
  const maxBatchSize = 50;
  const maxBatchBytes = 128_000;
  const numBatchesPerSync = 5;

  const calendarConfig = getCalendarConfig(env);

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

    if (!calendar) throw new Error(`Calendar ${calendarId} not found`);
    const accountId = calendar.account_id;

    let credentials = await getDbCredentials(supabase, accountId);

    if (syncType === "full") {
      await env.CONTACT_SYNC_QUEUE?.send?.({
        accountId,
        full: true,
      });
    }

    // Update a missing or expired watch
    if (
      (syncType === "full" ||
        !calendar.watch_id ||
        !calendar.watch_expires_at ||
        new Date(calendar.watch_expires_at) < new Date()) &&
      syncType !== "partial" &&
      !!env.CALENDAR_WEBHOOK_URL
    ) {
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

    if (
      syncType === "incremental" &&
      (!calendar.synced_dates ||
        !calendar.sync_state ||
        differenceInYears(
          new Date(),
          parseDatetimeRange(calendar.synced_dates).end
        ) < 1)
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
        ({ start: min, end: max } = parseDatetimeRange(calendar.synced_dates));
        break;
      case "partial":
        min = startOfMonth(subMonths(new Date(), 1));
        max = maxDate([endOfMonth(new Date()), add(new Date(), { days: 7 })]);
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
          userId: calendar.account.user_id,
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
            synced_dates: formatDatetimeRange(state.min, state.max),
            sync_state: state.state,
            sequence: state.sequence,
            synced_at: new Date().toISOString(),
          })
          .eq("id", calendar.id)
      );
    }
    await env.EVENT_QUEUE.send({
      provider: credentials.provider,
      userId: calendar.account.user_id,
      calendarId: calendar.id,
      sequence: state.sequence,
      complete: syncType,
    });
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
