import type { EventResponse } from "@plotday/cal";
import { respond as calendarRespond, getCalendarConfig } from "@plotday/cal";
import { type SupabaseClient, getCredentials, safeQuery } from "@plotday/db";

import { type Bindings } from "./";

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
