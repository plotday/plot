import type { SupabaseClient as _SupabaseClient } from "@supabase/supabase-js";
import { createClient as supabaseCreateClient } from "@supabase/supabase-js";

import type { Calendar, CalendarCredentials } from "@plotday/cal";
import { toDate } from "@plotday/tz";

import { createCategories } from "./path";
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

export async function buildCredentials(
  account: Awaited<ReturnType<typeof getAccount>>
): Promise<CalendarCredentials> {
  if (!account.email) throw new Error(`Account ${account.id} missing email`);
  if (
    !account.credentials ||
    typeof account.credentials !== "object" ||
    !("access_token" in account.credentials) ||
    typeof account.credentials.access_token !== "string" ||
    !("refresh_token" in account.credentials) ||
    typeof account.credentials.refresh_token !== "string"
  ) {
    throw new Error(`Account ${account.id} missing credentials`);
  }
  return {
    provider: account.provider,
    email: account.email,
    access_token: account.credentials.access_token,
    refresh_token: account.credentials.refresh_token,
    scopes: (account.credentials.scopes ?? []) as string[],
  };
}
export async function getCredentials(
  supabase: SupabaseClient,
  accountId: number
): Promise<CalendarCredentials> {
  const account = await getAccount(supabase, accountId);
  if (!account.email) throw new Error(`Account ${accountId} missing email`);
  return buildCredentials(account);
}

export async function saveCredentials(
  supabase: SupabaseClient,
  accountId: number,
  credentials: CalendarCredentials,
  onlyIfUpdated: boolean = false
) {
  if (onlyIfUpdated && !credentials.updated) return;
  safeQuery(
    await supabase.from("account").update({ credentials }).eq("id", accountId)
  );
  if (onlyIfUpdated) {
    credentials.updated = false;
  }
}

export function parseDateRange(range: string) {
  return range.replaceAll(/["[\]()]/g, "").split(",");
}

export function parseDatetimeRange(range: string, tz: string) {
  return parseDateRange(range).map((d) => toDate(d, tz));
}

export async function saveCalendars(
  supabase: SupabaseClient,
  userId: number,
  accountId: number,
  calendars: Calendar[]
) {
  const primaryCalendar = calendars.find((c) => c.primary);
  if (!primaryCalendar) throw new Error("No primary calendar");
  const category = await createCategories(
    supabase,
    userId,
    primaryCalendar.account
  );
  const result = safeQuery(
    await supabase
      .from("calendar")
      .upsert(
        calendars.map((calendar) => ({
          account_id: accountId,
          provider_id: calendar.id,
          name: calendar.name,
          enabled: calendar.primary,
          category,
        })),
        { onConflict: "account_id, provider_id", ignoreDuplicates: true }
      )
      .select()
  );

  const categories = safeQuery(
    await supabase
      .from("category")
      .select()
      .eq("user_id", userId)
      .in("path", [category, `${category}.meetings`])
  );

  safeQuery(
    await supabase.from("event_rule").upsert(
      result.flatMap((calendar) =>
        categories.map((c) => ({
          user_id: userId,
          calendar_id: calendar.id,
          ...((c.path as string).endsWith(".meetings")
            ? { type: "meeting" as Database["public"]["Enums"]["event_type"] }
            : {}),
          category_id: c.id,
        }))
      )
    )
  );
  return result;
}

export type {
  Invitee,
  Invitees,
  ConferencingProvider,
  DbEvents,
  DbEvent,
} from "./event";
export { Event } from "./event";

export { safeQuery } from "./query";

export * from "./path";
