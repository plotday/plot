import type { LoaderFunctionArgs } from "@remix-run/cloudflare";

import { typedjson } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";

import { Event } from "@plotday/db";

import { requireAuth } from "app/auth";
import { createServerClient } from "app/db";

import type { EventFilter } from "./_app._events";

export const loader = async ({ context, request }: LoaderFunctionArgs) => {
  const { response, supabase } = createServerClient(request, context);
  await requireAuth(supabase);

  const url = new URL(request.url);
  const showReviewed = url.searchParams.get("reviewed") === "true";

  return typedjson(
    {
      ...(await promiseHash({
        events: Event.GetRange(
          supabase,
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
};

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
