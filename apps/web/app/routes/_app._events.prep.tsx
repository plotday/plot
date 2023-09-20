import type { LoaderArgs } from "@remix-run/cloudflare";

import { typedjson } from "remix-typedjson";
import { promiseHash } from "remix-utils";

import { Event } from "@plotday/db";

import { requireAuth } from "app/auth";
import { createServerClient } from "app/db";

import type { EventFilter } from "./_app._events";

export const loader = async ({ context, request }: LoaderArgs) => {
  const { response, supabase } = createServerClient(request, context);
  await requireAuth(supabase);

  return typedjson(
    {
      ...(await promiseHash({
        events: Event.GetRange(supabase, new Date(), true, {
          ready: false,
        }),
      })),
    },
    { headers: response.headers }
  );
};

export const handle: { eventFilter: EventFilter } = {
  eventFilter: {
    review: false,
  },
};

export default function Prep() {
  return null;
}
