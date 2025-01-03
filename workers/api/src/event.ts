import type { EventResponse } from "@plotday/cal";
import { respond as calendarRespond, getCalendarConfig } from "@plotday/cal";
import {
  type Database,
  type SupabaseClient,
  getCredentials,
  safeQuery,
} from "@plotday/db";

import { type Bindings } from "./";

export async function create(
  _env: Bindings,
  supabase: SupabaseClient,
  event: Database["public"]["Tables"]["event"]["Insert"]
) {
  const user = (await supabase.auth.getSession())?.data.session?.user;
  if (!user) throw new Response("Unauthorized", { status: 401 });
  if (!event.organizer_email) {
    event.organizer_email = user.email;
  }
  return safeQuery(
    await supabase.from("event").insert(event).select().single()
  );
  // TODO: Update calendar
}

export async function update(
  _env: Bindings,
  supabase: SupabaseClient,
  eventId: number,
  event: Database["public"]["Tables"]["event"]["Update"]
) {
  return safeQuery(
    await supabase
      .from("event")
      .update(event)
      .eq("id", eventId)
      .select()
      .single()
  );
  // TODO: Update calendar
}

export async function respond(
  env: Bindings,
  supabase: SupabaseClient,
  eventId: number,
  response: EventResponse
) {
  const event = safeQuery(
    await supabase
      .from("event")
      .select(
        "provider_id,at,organizer_email,calendar(provider_id,account(id,email))"
      )
      .eq("id", eventId)
      .maybeSingle()
  );
  if (!event?.calendar?.account?.email) {
    throw new Response("Not found", { status: 404 });
  }

  const isOrganizer = event.calendar.account.email === event.organizer_email;

  let credentials = await getCredentials(supabase, event.calendar.account.id);

  safeQuery(
    await supabase
      .from("invitee")
      .update({
        response: response,
      })
      .eq("event_id", eventId)
      .eq("email", event.calendar.account.email)
  );

  await calendarRespond(
    getCalendarConfig(env),
    credentials,
    event.calendar.provider_id,
    event.provider_id,
    response,
    isOrganizer
  );
}
