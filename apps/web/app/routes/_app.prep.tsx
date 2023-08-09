import type { LoaderArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";
import { useLoaderData } from "@remix-run/react";

import { Events, getEvents } from "../components/event";
import { createServerClient } from "../db";

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

export default function Now() {
  const data = useLoaderData();
  const events = data?.events;
  if (!events) {
    return "No events";
  }
  return <Events events={events} />;
}
