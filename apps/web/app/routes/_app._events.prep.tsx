import { typedjson } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import { Event } from "@plotday/db";

import { privateLoader } from "app/util";

import type { EventFilter } from "./_app._events";

export const loader = privateLoader(async ({ supabase, response, user }) => {
  return typedjson(
    {
      ...(await promiseHash({
        events: Event.GetRange(supabase, user.id, new Date(), true, {
          type: ["meeting"],
          ready: false,
        }),
      })),
    },
    { headers: response.headers }
  );
});

export const handle: { eventFilter: EventFilter } = {
  eventFilter: {
    review: false,
    match: (event) => !event.ready,
  },
};

export default function Prep() {
  return null;
}
