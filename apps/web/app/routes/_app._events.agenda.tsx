import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import { typedjson } from "remix-typedjson";
import { promiseHash } from "remix-utils";

import type { Attendance } from "@plotday/db";
import { Event } from "@plotday/db";

import { getUser } from "app/auth";
import { createServerClient } from "app/db";

import type { EventFilter } from "./_app._events";

export const loader = async ({ context, request }: LoaderArgs) => {
  const { response, supabase } = createServerClient(request, context);
  let user = await getUser(supabase);
  if (!user?.id) throw redirect("/login");

  const url = new URL(request.url);
  const showSkipped = url.searchParams.get("skipped") === "true";

  return typedjson(
    {
      ...(await promiseHash({
        events: Event.GetRange(supabase, new Date(), true, {
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
};

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

export default function Prep() {
  return null;
}
