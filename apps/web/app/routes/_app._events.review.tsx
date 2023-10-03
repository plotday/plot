import { typedjson } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import { Event } from "@plotday/db";

import { privateLoader } from "app/util";

import type { EventFilter } from "./_app._events";

export const loader = privateLoader(
  async ({ request, user, response, supabase }) => {
    const url = new URL(request.url);
    const showReviewed = url.searchParams.get("reviewed") === "true";

    return typedjson(
      {
        ...(await promiseHash({
          events: Event.GetRange(
            supabase,
            user.id,
            new Date(),
            false,
            showReviewed
              ? {}
              : {
                  reviewed: false,
                }
          ),
        })),
      },
      { headers: response.headers }
    );
  }
);

export const handle: { eventFilter: EventFilter } = {
  eventFilter: {
    review: true,
    config: [
      {
        label: "Show reviewed",
        name: "reviewed",
      },
    ],
  },
};

export default function Review() {
  return null;
}
