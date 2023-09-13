import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import add from "date-fns/add";
import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { promiseHash } from "remix-utils";

import { Event } from "@plotday/db";

import { getUser } from "app/auth";
import { EventList } from "app/components/event";
import { createServerClient } from "app/db";
import { useTz } from "app/hooks";
import { getExpenditures, getTargets } from "app/target";

export const loader = async ({ context, request }: LoaderArgs) => {
  const { response, supabase } = createServerClient(request, context);
  let user = await getUser(supabase);
  if (!user?.id) throw redirect("/login");
  const tz = user.timezone || "America/New_York";

  const start = new Date();
  const end = add(new Date(), { months: 2 });

  return typedjson(
    {
      ...(await promiseHash({
        events: Event.GetRange(supabase, new Date(), false),
        targets: getTargets(supabase, user.id),
        expenditures: getExpenditures(supabase, user.id, tz, start, end),
      })),
    },
    { headers: response.headers }
  );
};

export default function Review() {
  const {
    events: dbEvents,
    targets,
    expenditures,
  } = useTypedLoaderData<typeof loader>();
  const tz = useTz();
  const events = Event.Hydrate(dbEvents, tz);
  return (
    <EventList
      review
      events={events}
      targets={targets}
      expenditures={expenditures}
    />
  );
}
