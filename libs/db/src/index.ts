import type { SupabaseClient as _SupabaseClient } from "@supabase/supabase-js";
import { createClient as supabaseCreateClient } from "@supabase/supabase-js";

import type { Calendar, CalendarCredentials } from "@plotday/cal";
import { toDate } from "@plotday/tz";

import { safeQuery } from "./query";
import type { Database } from "./types";

export type { Database } from "./types";
export type SupabaseClient = _SupabaseClient<Database>;

// Create a non-session client.
// Use supabase/ssr for sessions.
export function createClient(supabaseUrl: string, supabaseKey: string) {
  return supabaseCreateClient<Database>(supabaseUrl, supabaseKey, {
    auth: {
      persistSession: false,
    },
  });
}

export async function getAccount(supabase: SupabaseClient, accountId: number) {
  const account = safeQuery(
    await supabase.from("account").select().eq("id", accountId).single()
  );
  if (!account) throw new Error(`Account ${accountId} not found`);
  return account;
}

export async function getCredentials(
  supabase: SupabaseClient,
  accountId: number
): Promise<CalendarCredentials> {
  const account = await getAccount(supabase, accountId);
  if (!account.email) throw new Error(`Account ${accountId} missing email`);
  if (!account.credentials)
    throw new Error(`Account ${accountId} missing credentials`);
  return account.credentials as CalendarCredentials;
}

export async function saveCredentials(
  supabase: SupabaseClient,
  userId: string,
  credentials: CalendarCredentials,
  onlyIfUpdated: boolean = false
) {
  if (onlyIfUpdated && !credentials.updated) return;
  const { updated, ...rest } = credentials;
  safeQuery(
    await supabase
      .from("account")
      .update({ credentials: rest })
      .eq("user_id", userId)
      .eq("email", credentials.email)
  );
  if (onlyIfUpdated) {
    credentials.updated = false;
  }
}

export function parseDateRange(range: string | unknown) {
  const [start, end] = (range as string).replaceAll(/["[\]()]/g, "").split(",");
  return {
    start,
    end,
  };
}

export function parseDatetimeRange(range: string | unknown, tz?: string) {
  const { start, end } = parseDateRange(range);
  return {
    start: tz ? toDate(start, tz) : new Date(start),
    end: tz ? toDate(end, tz) : new Date(end),
  };
}

export function formatDatetimeRange(start: Date, end: Date) {
  return `[${start.toISOString()},${end.toISOString()})`;
}

export async function saveCalendars(
  supabase: SupabaseClient,
  accountId: number,
  calendars: Calendar[]
) {
  const primaryCalendar = calendars.find((c) => c.primary);
  if (!primaryCalendar) throw new Error("No primary calendar");
  safeQuery(
    await supabase.from("calendar").upsert(
      calendars.map((calendar) => ({
        account_id: accountId,
        provider_id: calendar.id,
        name: calendar.name,
        enabled: calendar.primary,
      })),
      { onConflict: "account_id, provider_id", ignoreDuplicates: true }
    )
  );
  const dbCalendars = safeQuery(
    await supabase.from("calendar").select().eq("account_id", accountId)
  );
  const deletedCalendars = dbCalendars.filter(
    (dbCalendar) =>
      !calendars.some((calendar) => calendar.id === dbCalendar.provider_id)
  );
  if (deletedCalendars.length > 0) {
    safeQuery(
      await supabase
        .from("calendar")
        .delete()
        .in(
          "id",
          deletedCalendars.map((calendar) => calendar.id)
        )
    );
  }
  return dbCalendars.filter(
    (dbCalendar) => !deletedCalendars.includes(dbCalendar)
  );
}

export type {
  Invitee,
  Invitees,
  ConferencingProvider,
  DbEvents,
  DbEvent,
} from "./event";
export { Event, calendarToDb } from "./event";

export { safeQuery } from "./query";
export * from "./path";
