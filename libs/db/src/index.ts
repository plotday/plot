import type { SupabaseClient as _SupabaseClient } from "@supabase/supabase-js";
import { createClient as supabaseCreateClient } from "@supabase/supabase-js";

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

export { safeQuery } from "./query";
export * from "./path";
