import { typedjson } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import { Event } from "@plotday/db";

import { privateLoader } from "app/util";

export const loader = privateLoader(async ({ params, response, supabase }) => {
  if (!params.event) throw new Error("Event ID is required");
  let eventId = parseInt(params.event);
  if (isNaN(eventId)) throw new Error("Invalid Event ID");
  return typedjson(
    {
      ...(await promiseHash({
        event: Event.Get(supabase, eventId),
      })),
    },
    { headers: response.headers }
  );
});

export default function AgendaEvent() {
  return null;
}
