import type { SupabaseClient, User } from "@supabase/supabase-js";

import { getCalendarConfig, getCalendars, getCredentials } from "@plotday/cal";
import type { CalendarProvider } from "@plotday/cal";
import {
  type Database,
  createActivities,
  safeQuery,
  saveCalendars,
  saveCredentials,
} from "@plotday/db";

import type { Bindings } from "./";

export async function addAccount(
  env: Bindings,
  supabaseAdmin: SupabaseClient,
  user: User,
  provider: CalendarProvider,
  code: string
) {
  const config = getCalendarConfig(env);

  let credentials = await getCredentials(config, provider, code);

  const user_id = user.id;
  const name = user.user_metadata?.full_name;
  const avatar_url = user.user_metadata?.avatar_url;
  const email = credentials.email.toLowerCase();

  const account = safeQuery(
    await supabaseAdmin
      .from("account")
      .upsert(
        {
          user_id,
          email,
          credentials,
        },
        { onConflict: "user_id,email" }
      )
      .select()
      .single()
  );
  if (!account) {
    throw Error("Failed to create account");
  }

  await createActivities(supabaseAdmin, user.id, email);

  // Create or link a contact for the user
  safeQuery(
    await supabaseAdmin.from("contact").upsert(
      {
        user_id,
        email,
        name,
        avatar_url,
      },
      { onConflict: "user_id,email" }
    )
  );

  let calendars;
  ({ calendars, credentials } = await getCalendars(
    getCalendarConfig(env),
    credentials
  ));
  await saveCredentials(supabaseAdmin, user.id, credentials);
  const dbCalendars = await saveCalendars(supabaseAdmin, account.id, calendars);

  if (dbCalendars) {
    for (const calendar of dbCalendars) {
      if (!calendar.enabled) continue;
      // Start a partial sync plus a full sync
      await env.SYNC_QUEUE?.send?.({
        calendarId: calendar.id,
        syncType: "partial",
      });
      await env.SYNC_QUEUE?.send?.({
        calendarId: calendar.id,
        syncType: "full",
      });
    }
  }

  return account;
}
