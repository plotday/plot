import type { LoaderArgs } from "@remix-run/cloudflare";

import { typedjson, useTypedLoaderData } from "remix-typedjson";

import { Event } from "@plotday/db";

import { EventList } from "app/components/event";
import { createServerClient } from "app/db";
import { useTz } from "app/root";

export const loader = async ({ context, request }: LoaderArgs) => {
  const { response, supabase } = createServerClient(request, context);

  const events = await Event.GetRange(supabase, new Date());

  return typedjson(
    {
      events,
    },
    { headers: response.headers }
  );
};

export default function Prep() {
  const { events: dbEvents } = useTypedLoaderData<typeof loader>();
  const tz = useTz();
  const events = Event.Hydrate(dbEvents, tz);
  return <EventList events={events} />;
}
