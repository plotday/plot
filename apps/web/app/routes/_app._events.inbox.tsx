import { typedjson } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import { Event } from "@plotday/db";
import type { Attendance } from "@plotday/db";

import { privateLoader } from "app/util";

import type { EventFilter } from "./_app._events";

export const loader = privateLoader(async ({ response, supabase, user }) => {
  return typedjson(
    {
      ...(await promiseHash({
        events: Event.GetRange(supabase, user.id, new Date(), true, {
          attendance: [null as Attendance],
        }),
      })),
    },
    { headers: response.headers }
  );
});

export const handle: { eventFilter: EventFilter } = {
  eventFilter: {
    review: false,
    match: (event) => event.attendance === null,
  },
};

export default function Inbox() {
  return null;
}
