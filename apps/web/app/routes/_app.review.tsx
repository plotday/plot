import type { LoaderArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import { useLoaderData } from "@remix-run/react";

import { Event, EventList, getEvents } from "app/components/event";
import { createServerClient } from "app/db";
import { useTz } from "app/root";

export const loader = async ({ context, request }: LoaderArgs) => {
  const { response, supabase } = createServerClient(request, context);

  const events = await getEvents(supabase, new Date(), false);

  return json(
    {
      events,
    },
    { headers: response.headers }
  );
};

export default function Review() {
  let { events: dbEvents } = useLoaderData();
  const tz = useTz();
  const events = Event.Hydrate(dbEvents, tz);
  return <EventList events={events} tz={tz} />;
}
