import { typedjson } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import type { Attendance } from "@plotday/db";
import { Event } from "@plotday/db";

import { privateLoader } from "app/util";

import type { EventFilter } from "./_app._events";

export const loader = privateLoader(
  async ({ request, user, response, supabase }) => {
    const url = new URL(request.url);
    const showSkipped = url.searchParams.get("skipped") === "true";

    return typedjson(
      {
        ...(await promiseHash({
          events: Event.GetRange(supabase, user.id, new Date(), true, {
            attendance: [
              "attend",
              "if-possible",
              ...(showSkipped ? ["skip" as Attendance] : []),
              null,
            ],
          }),
        })),
      },
      { headers: response.headers }
    );
  }
);

export const handle: { eventFilter: EventFilter } = {
  eventFilter: {
    showGaps: true,
    config: [
      {
        label: "Show skipped",
        name: "skipped",
      },
    ],
  },
};

export default function Agenda() {
  return null;
}
