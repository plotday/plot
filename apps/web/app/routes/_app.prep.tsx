import type { LoaderArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import { useLoaderData } from "@remix-run/react";

import { Events, getEvents } from "app/components/event";
import { createServerClient } from "app/db";
import { useTz } from "app/root";

export const loader = async ({ context, request }: LoaderArgs) => {
  const { response, supabase } = createServerClient(request, context);

  const events = await getEvents(supabase, new Date());

  return json(
    {
      events,
    },
    { headers: response.headers }
  );
};

export default function Prep() {
  const data = useLoaderData();
  const tz = useTz();
  const events = data?.events;
  if (!events) {
    return "No events";
  }
  return <Events events={events} tz={tz} />;
}
