import type { SupabaseClient as _SupabaseClient } from "@supabase/supabase-js";
import { createClient as supabaseCreateClient } from "@supabase/supabase-js";

import { safeQuery } from "./query";
import type { Database } from "./types";

export type { Database } from "./types";
export { safeQuery } from "./query";
export type SupabaseClient = _SupabaseClient<Database>;

// Create a non-session client.
// Use supabase/auth-helpers-remix for sessions.
export function createClient(supabaseUrl: string, supabaseKey: string) {
  return supabaseCreateClient<Database>(supabaseUrl, supabaseKey, {
    auth: {
      persistSession: false,
    },
  });
}

export async function getCredentials(
  supabase: SupabaseClient,
  accountId: number
) {
  const account = safeQuery(
    await supabase.from("account").select().eq("id", accountId).maybeSingle()
  );
  if (!account) throw new Error(`Account ${accountId} not found`);
  if (
    !account.credentials ||
    typeof account.credentials !== "object" ||
    !("access_token" in account.credentials) ||
    typeof account.credentials.access_token !== "string" ||
    !("refresh_token" in account.credentials) ||
    typeof account.credentials.refresh_token !== "string"
  ) {
    throw new Error(`Account ${accountId} missing credentials`);
  }
  return {
    provider: account.provider,
    access_token: account.credentials.access_token,
    refresh_token: account.credentials.refresh_token,
  };
}

export type {
  Invitee,
  Invitees,
  Label,
  Labels,
  ConferencingProvider,
  Attendance,
  DbEvents,
  DbEvent,
} from "./event";
export { Event } from "./event";
